#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 6 ]]; then
  printf '%s\n' '使い方: publish-release.sh central-root release-contract.json release-manifest.json source-manifest.json build-manifest.json release-assets.tar' >&2
  exit 2
fi

central_root=$1
contract_path=$2
manifest_path=$3
source_manifest_path=$4
build_manifest_path=$5
assets_archive=$6
api_url=${GITHUB_API_URL:-https://api.github.com}
upload_api_url=${GITHUB_UPLOAD_URL:-https://uploads.github.com}
token=${CENTRAL_APP_TOKEN:?CENTRAL_APP_TOKENが必要です}
if [[ -z "$token" || "$token" == *$'\n'* || "$token" == *$'\r'* ]]; then
  printf '%s\n' 'GitHub App tokenが空またはtransport上不正です' >&2
  exit 1
fi
for input_path in "$central_root" "$contract_path" "$manifest_path" "$source_manifest_path" "$build_manifest_path" "$assets_archive"; do
  if [[ ! -e "$input_path" || -L "$input_path" ]]; then
    printf 'publish inputが不正です: %s\n' "$input_path" >&2
    exit 1
  fi
done
if [[ ! -d "$central_root" ]]; then
  printf '%s\n' '中央repoのpathがdirectoryではありません' >&2
  exit 1
fi

curl_max_seconds=${CENTRAL_CURL_MAX_SECONDS:?CENTRAL_CURL_MAX_SECONDSが必要です}
operation_timeout_seconds=${CENTRAL_OPERATION_TIMEOUT_SECONDS:?CENTRAL_OPERATION_TIMEOUT_SECONDSが必要です}
rollback_reserve_seconds=${CENTRAL_ROLLBACK_RESERVE_SECONDS:?CENTRAL_ROLLBACK_RESERVE_SECONDSが必要です}
if [[ ! "$curl_max_seconds" =~ ^[1-9][0-9]*$ || ! "$operation_timeout_seconds" =~ ^[1-9][0-9]*$ || ! "$rollback_reserve_seconds" =~ ^[1-9][0-9]*$ ]]; then
  printf '%s\n' 'publish timeout設定が不正です' >&2
  exit 1
fi
if (( operation_timeout_seconds > 2400 || rollback_reserve_seconds < 600 || operation_timeout_seconds + rollback_reserve_seconds > 3000 )); then
  printf '%s\n' 'App token発行後のpublish時間またはrollback予約が契約外です' >&2
  exit 1
fi
python_path=$(command -v python3 || true)
if [[ -z "$python_path" ]]; then
  printf '%s\n' 'redirect先検証用のpython3が見つかりません' >&2
  exit 1
fi
python_version=$("$python_path" --version 2>&1)
if [[ ! "$python_version" =~ ^Python\ 3\.(9|[1-9][0-9])\.[0-9]+$ ]]; then
  printf 'Python 3.9以上が必要です: %s\n' "$python_version" >&2
  exit 1
fi
operation_started_at=$(date +%s)
operation_deadline=$((operation_started_at + operation_timeout_seconds))
rollback_deadline=$((operation_deadline + rollback_reserve_seconds))
normal_mutation_deadline=$operation_deadline
in_rollback=false

repository=$(jq -er '.repository' "$contract_path")
tag=$(jq -er '.tag' "$contract_path")
app_id=$(jq -er '.appId' "$contract_path")
config_digest=$(jq -er '.configDigest' "$contract_path")
source_sha=$(jq -er '.sourceSha' "$source_manifest_path")
version=$(jq -er '.version' "$contract_path")
run_url=$(jq -er '.runUrl' "$build_manifest_path")
if [[ ! "$source_sha" =~ ^[0-9a-fA-F]{40}$ || ! "$run_url" =~ ^https:// ]]; then
  printf '%s\n' 'publish manifestの値が不正です' >&2
  exit 1
fi
jq -e --arg repository "$repository" --arg tag "$tag" --arg app_id "$app_id" --arg config_digest "$config_digest" --arg source_sha "$source_sha" \
  '.appId == $app_id and .repository == $repository and .tag == $tag and .configDigest == $config_digest and .sourceSha == $source_sha' \
  "$source_manifest_path" >/dev/null
jq -e --arg repository "$repository" --arg tag "$tag" --arg source_sha "$source_sha" --arg version "$version" --arg config_digest "$config_digest" --arg run_url "$run_url" \
  '.repository == $repository and .tag == $tag and .sourceSha == $source_sha and .version == $version and .configDigest == $config_digest and .runUrl == $run_url' \
  "$build_manifest_path" >/dev/null

umask 077
recovery_directory=${CENTRAL_RECOVERY_DIRECTORY:-"${RUNNER_TEMP:-/tmp}/central-publish-recovery-${GITHUB_RUN_ID:-local}-${app_id}"}
recovery_artifact_name=${CENTRAL_RECOVERY_ARTIFACT_NAME:-"central-${GITHUB_RUN_ID:-local}-${app_id}-publish-recovery"}
if [[ -L "$recovery_directory" ]]; then
  printf '%s\n' 'publish recovery directoryがsymlinkです' >&2
  exit 1
fi
mkdir -p -- "$recovery_directory"
chmod 700 "$recovery_directory"
recovery_backup_directory="$recovery_directory/backups"
mkdir -p -- "$recovery_backup_directory"
chmod 700 "$recovery_backup_directory"
cat >"$recovery_directory/recovery-info.txt" <<EOF
repository=$repository
tag=$tag
recovery artifact=$recovery_artifact_name
失敗時はこのdirectoryを取得し、Release idとasset idをjournalで照合して手動復旧してください。
EOF

work_directory=$(mktemp -d "${RUNNER_TEMP:-/tmp}/central-publish-release.XXXXXX")
auth_header_path="$work_directory/authorization-header.txt"
printf 'Authorization: Bearer %s\n' "$token" >"$auth_header_path"
remote_assets_path="$work_directory/remote-assets.json"
release_path="$work_directory/release.json"
plan_path="$work_directory/publish-plan.json"
extracted_assets="$work_directory/assets"
journal_path="$recovery_directory/operation-journal.jsonl"
cleanup() {
  local status=$?
  local cleanup_status=0
  if ! rm -rf -- "$work_directory"; then
    printf '%s\n' 'publish用一時directoryの削除に失敗しました' >&2
    cleanup_status=1
  fi
  if (( status != 0 )); then
    printf 'durable recovery artifact: %s\nmanual recovery directory: %s\n' "$recovery_artifact_name" "$recovery_directory" >&2
    exit "$status"
  fi
  if ! rm -rf -- "$recovery_directory"; then
    printf '%s\n' '成功後のpublish recovery directory削除に失敗しました' >&2
    cleanup_status=1
  fi
  exit "$cleanup_status"
}
trap cleanup EXIT

urlencode() {
  jq -nr --arg value "$1" '$value | @uri'
}

request_timeout_seconds() {
  local phase=$1
  local now
  local deadline
  local remaining
  now=$(date +%s)
  deadline=$operation_deadline
  if [[ "$in_rollback" == true ]]; then
    deadline=$rollback_deadline
  fi
  remaining=$((deadline - now))
  if (( remaining <= 0 )); then
    if [[ "$in_rollback" == true ]]; then
      printf 'rollback時間を確保できません: %s\n' "$phase" >&2
    else
      printf 'publish時間を確保できません: %s\n' "$phase" >&2
    fi
    return 1
  fi
  if (( remaining > curl_max_seconds )); then
    remaining=$curl_max_seconds
  fi
  printf '%s\n' "$remaining"
}

ensure_time_budget() {
  local phase=$1
  request_timeout_seconds "$phase" >/dev/null
}

append_journal_line() {
  local line=$1
  if [[ "$line" == *$'\n'* || "$line" == *$'\r'* ]]; then
    printf '%s\n' 'journalに改行を含められません' >&2
    return 1
  fi
  "$python_path" - "$journal_path" "$line" <<'PY'
import os
import sys

journal_path = sys.argv[1]
line = sys.argv[2].encode("utf-8") + b"\n"
descriptor = os.open(journal_path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
try:
    written = 0
    while written < len(line):
        written += os.write(descriptor, line[written:])
    os.fsync(descriptor)
finally:
    os.close(descriptor)
PY
}

sleep_for_retry() {
  local seconds=$1
  local deadline=$operation_deadline
  if [[ "$in_rollback" == true ]]; then
    deadline=$rollback_deadline
  fi
  if (( $(date +%s) + seconds >= deadline )); then
    printf '%s\n' 'retry待機後の時間予算が不足しています' >&2
    return 1
  fi
  sleep "$seconds"
}

repository_owner=${repository%%/*}
repository_name=${repository#*/}
if [[ "$repository_owner" == "$repository" || -z "$repository_owner" || -z "$repository_name" ]]; then
  printf '%s\n' 'repositoryをAPI pathへ変換できません' >&2
  exit 1
fi
encoded_repository="$(urlencode "$repository_owner")/$(urlencode "$repository_name")"

resolved_tag_path="$work_directory/resolved-tag.json"
CENTRAL_SOURCE_REPOSITORY="$repository" \
CENTRAL_SOURCE_TAG="$tag" \
  CENTRAL_APP_TOKEN="$token" \
  CENTRAL_TAG_OUTPUT="$resolved_tag_path" \
  CENTRAL_CURL_MAX_SECONDS="$curl_max_seconds" \
  CENTRAL_DEADLINE_EPOCH="$normal_mutation_deadline" \
  "$central_root/scripts/workflow/resolve-tag.sh"
resolved_source_sha=$(jq -er '.sourceSha' "$resolved_tag_path")
if [[ "${resolved_source_sha,,}" != "${source_sha,,}" ]]; then
  printf 'tagのsource SHAがmanifestと一致しません: %s\n' "$resolved_source_sha" >&2
  exit 1
fi

request_once() {
  local method=$1
  local url=$2
  local output_path=$3
  local body_path=$4
  local content_type=$5
  local response_code
  local curl_status=0
  local request_timeout
  if ! request_timeout=$(request_timeout_seconds "GitHub API $method"); then
    HTTP_STATUS=000
    return 1
  fi
  if [[ -n "$body_path" ]]; then
    response_code=$(curl --silent --show-error --request "$method" \
      --connect-timeout "$request_timeout" --max-time "$request_timeout" \
      --header 'Accept: application/vnd.github+json' \
      --header 'X-GitHub-Api-Version: 2022-11-28' \
      --header "@$auth_header_path" \
      --header "$content_type" --data-binary "@$body_path" \
      --output "$output_path" --write-out '%{http_code}' "$url") || curl_status=$?
  else
    response_code=$(curl --silent --show-error --request "$method" \
      --connect-timeout "$request_timeout" --max-time "$request_timeout" \
      --header 'Accept: application/vnd.github+json' \
      --header 'X-GitHub-Api-Version: 2022-11-28' \
      --header "@$auth_header_path" \
      --output "$output_path" --write-out '%{http_code}' "$url") || curl_status=$?
  fi
  if (( curl_status != 0 )); then
    HTTP_STATUS=000
  elif [[ "$response_code" =~ ^[0-9]{3}$ ]]; then
    HTTP_STATUS=$response_code
  else
    HTTP_STATUS=000
  fi
}

is_retryable_status() {
  [[ "$1" == 000 || "$1" == 429 || "$1" =~ ^5[0-9][0-9]$ ]]
}

request_read() {
  local method=$1
  local url=$2
  local output_path=$3
  local attempt
  for attempt in 1 2 3; do
    request_once "$method" "$url" "$output_path" '' ''
    if [[ "$HTTP_STATUS" =~ ^2[0-9][0-9]$ ]]; then
      return 0
    fi
    if [[ "$HTTP_STATUS" == 401 ]]; then
      printf 'GitHub API tokenが期限切れまたは権限不正です: %s\n' "$url" >&2
      return 1
    fi
    if ! is_retryable_status "$HTTP_STATUS" || (( attempt == 3 )); then
      return 1
    fi
    if ! sleep_for_retry "$attempt"; then
      return 1
    fi
  done
  return 1
}

validate_asset_location() {
  local location=$1
  "$python_path" - "$location" <<'PY'
import sys
from urllib.parse import urlsplit

location = sys.argv[1]
parsed = urlsplit(location)
allowed_hosts = {
    "objects.githubusercontent.com",
    "release-assets.githubusercontent.com",
    "github-releases.githubusercontent.com",
}
try:
    hostname = parsed.hostname
    port = parsed.port
except ValueError as error:
    raise SystemExit("Release assetのredirect先URLが不正です") from error
if (
    parsed.scheme != "https"
    or hostname not in allowed_hosts
    or parsed.username is not None
    or parsed.password is not None
    or port not in (None, 443)
    or not parsed.path
    or any(character in location for character in "\x00\r\n")
):
    raise SystemExit("Release assetのredirect先hostが許可されていません")
PY
}

request_download_once() {
  local url=$1
  local output_path=$2
  local header_path="$work_directory/download-headers.txt"
  local api_body_path="$work_directory/download-api-body"
  local response_code
  local curl_status=0
  local location
  local request_timeout
  if ! request_timeout=$(request_timeout_seconds 'Release asset API download'); then
    HTTP_STATUS=000
    return 1
  fi
  rm -f -- "$header_path" "$api_body_path" "$output_path"
  response_code=$(curl --silent --show-error --request GET \
    --connect-timeout "$request_timeout" --max-time "$request_timeout" \
    --header 'Accept: application/octet-stream' \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    --header "@$auth_header_path" \
    --dump-header "$header_path" --output "$api_body_path" --write-out '%{http_code}' "$url") || curl_status=$?
  if (( curl_status != 0 )); then
    HTTP_STATUS=000
    return
  fi
  if [[ ! "$response_code" =~ ^[0-9]{3}$ ]]; then
    HTTP_STATUS=000
    return
  fi
  HTTP_STATUS=$response_code
  if [[ "$HTTP_STATUS" == 200 ]]; then
    if ! mv -- "$api_body_path" "$output_path"; then
      HTTP_STATUS=000
      printf '%s\n' 'Release asset APIのdirect body保存に失敗しました' >&2
      return 1
    fi
    return 0
  fi
  if [[ ! "$HTTP_STATUS" =~ ^3[0-9][0-9]$ ]]; then
    printf 'Release asset APIが200またはredirect以外を返しました: HTTP %s\n' "$HTTP_STATUS" >&2
    return
  fi
  location=$(awk 'tolower($1) == "location:" { sub(/^[^:]*:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit }' "$header_path")
  if [[ -z "$location" ]]; then
    HTTP_STATUS=400
    printf '%s\n' 'Release asset API応答にLocationがありません' >&2
    return 1
  fi
  if ! validate_asset_location "$location"; then
    HTTP_STATUS=400
    return 1
  fi
  if ! request_timeout=$(request_timeout_seconds 'Release asset CDN download'); then
    HTTP_STATUS=000
    return 1
  fi
  curl_status=0
  response_code=$(curl --silent --show-error --request GET \
    --connect-timeout "$request_timeout" --max-time "$request_timeout" \
    --proto '=https' --output "$output_path" --write-out '%{http_code}' "$location") || curl_status=$?
  if (( curl_status != 0 )); then
    HTTP_STATUS=000
  elif [[ "$response_code" =~ ^[0-9]{3}$ ]]; then
    HTTP_STATUS=$response_code
  else
    HTTP_STATUS=000
  fi
}

download_remote_asset() {
  local asset_id=$1
  local asset_name=$2
  local expected_digest=$3
  local expected_size=$4
  local output_path=$5
  local attempt
  for attempt in 1 2 3; do
    rm -f -- "$output_path"
    request_download_once "$api_url/repos/$encoded_repository/releases/assets/$asset_id" "$output_path"
    if [[ "$HTTP_STATUS" == 200 ]]; then
      local actual_size
      local actual_digest
      if [[ ! -f "$output_path" || -L "$output_path" ]]; then
        printf 'remote assetのbodyが通常fileではありません: %s\n' "$asset_name" >&2
        return 1
      fi
      actual_size=$(wc -c <"$output_path" | tr -d '[:space:]')
      actual_digest="sha256:$(sha256sum "$output_path" | awk '{print tolower($1)}')"
      if [[ "$actual_size" == "$expected_size" && "$actual_digest" == "${expected_digest,,}" ]]; then
        return 0
      fi
      printf 'remote assetのbytes digestが一致しません: %s\n' "$asset_name" >&2
      return 1
    fi
    if [[ "$HTTP_STATUS" == 401 ]]; then
      printf 'Release asset API tokenが期限切れまたは権限不正です: %s\n' "$asset_name" >&2
      return 1
    fi
    if ! is_retryable_status "$HTTP_STATUS" || (( attempt == 3 )); then
      printf 'remote assetのdownloadに失敗しました: %s HTTP %s\n' "$asset_name" "$HTTP_STATUS" >&2
      return 1
    fi
    if ! sleep_for_retry "$attempt"; then
      return 1
    fi
  done
  return 1
}

fetch_remote_assets() {
  local accumulator="$work_directory/remote-accumulator.json"
  local page_path="$work_directory/remote-page.json"
  local page=1
  local page_count
  printf '[]\n' >"$accumulator"
  while :; do
    if ! request_read GET "$api_url/repos/$encoded_repository/releases/$release_id/assets?per_page=100&page=$page" "$page_path"; then
      printf 'Release asset一覧の取得に失敗しました: HTTP %s\n' "$HTTP_STATUS" >&2
      return 1
    fi
    if ! jq -e 'type == "array"' "$page_path" >/dev/null; then
      printf '%s\n' 'Release asset一覧のJSONが配列ではありません' >&2
      return 1
    fi
    if ! page_count=$(jq -er 'length' "$page_path"); then
      printf '%s\n' 'Release asset一覧の件数を取得できません' >&2
      return 1
    fi
    if ! jq -s '.[0] + .[1]' "$accumulator" "$page_path" >"$work_directory/remote-next.json"; then
      printf '%s\n' 'Release asset一覧を結合できません' >&2
      return 1
    fi
    if ! mv -- "$work_directory/remote-next.json" "$accumulator"; then
      return 1
    fi
    if (( page_count < 100 )); then
      break
    fi
    page=$((page + 1))
    if (( page > 100 )); then
      printf '%s\n' 'Release assetのpaginationが上限を超えました' >&2
      return 1
    fi
  done
  if ! cp -- "$accumulator" "$remote_assets_path"; then
    return 1
  fi
}

release_conflict_error=''
reconfirm_release_id_only() {
  local current_path="$work_directory/reconfirm-release.json"
  local current_id
  local current_tag
  local current_state
  local current_draft
  local current_prerelease
  local current_immutable
  if ! request_read GET "$api_url/repos/$encoded_repository/releases/tags/$encoded_tag" "$current_path"; then
    release_conflict_error="Release再確認に失敗しました: HTTP $HTTP_STATUS"
    return 1
  fi
  if ! current_id=$(jq -er '.id | numbers | select(. > 0)' "$current_path") || ! current_tag=$(jq -er '.tag_name' "$current_path") || ! current_state=$(bash "$central_root/scripts/workflow/read-release-state.sh" "$current_path"); then
    release_conflict_error='Release再確認の応答が不正です'
    return 1
  fi
  current_draft=$(jq -r '.draft' <<<"$current_state")
  current_prerelease=$(jq -r '.prerelease' <<<"$current_state")
  current_immutable=$(jq -r '.immutable' <<<"$current_state")
  if [[ "$current_id" != "$initial_release_id" || "$current_tag" != "$initial_release_tag" || "$current_draft" != "$initial_draft" || "$current_prerelease" != "$initial_prerelease" || "$current_immutable" != "$initial_immutable" || "$current_immutable" != false ]]; then
    release_conflict_error="Release状態が初期値から変化しました: expected_id=$initial_release_id actual_id=$current_id expected_tag=$initial_release_tag actual_tag=$current_tag expected_draft=$initial_draft actual_draft=$current_draft expected_prerelease=$initial_prerelease actual_prerelease=$current_prerelease expected_immutable=$initial_immutable actual_immutable=$current_immutable"
    return 1
  fi
  return 0
}

reconfirm_mutation_context() {
  local current_tag_path="$work_directory/reconfirm-tag.json"
  local current_source_sha
  local deadline_epoch=$normal_mutation_deadline
  if [[ "$in_rollback" == true ]]; then
    deadline_epoch=$rollback_deadline
  fi
  if ! ensure_time_budget 'mutation前のRelease再確認'; then
    release_conflict_error='mutation前の時間予算が不足しています'
    return 1
  fi
  if ! reconfirm_release_id_only; then
    return 1
  fi
  if ! CENTRAL_SOURCE_REPOSITORY="$repository" \
    CENTRAL_SOURCE_TAG="$tag" \
    CENTRAL_APP_TOKEN="$token" \
    CENTRAL_TAG_OUTPUT="$current_tag_path" \
    CENTRAL_CURL_MAX_SECONDS="$curl_max_seconds" \
    CENTRAL_DEADLINE_EPOCH="$deadline_epoch" \
    "$central_root/scripts/workflow/resolve-tag.sh"; then
    release_conflict_error='mutation前のtag再解決に失敗しました'
    return 1
  fi
  if ! current_source_sha=$(jq -er '.sourceSha' "$current_tag_path"); then
    release_conflict_error='mutation前のtag再解決結果が不正です'
    return 1
  fi
  if [[ "${current_source_sha,,}" != "${source_sha,,}" ]]; then
    release_conflict_error="tagのsource SHAが変化しました: expected=$source_sha actual=$current_source_sha"
    return 1
  fi
}

remote_asset_id() {
  local name=$1
  jq -r --arg name "$name" '[.[] | select(.name == $name)][0].id // empty' "$remote_assets_path"
}

remote_asset_record() {
  local name=$1
  jq -c --arg name "$name" '[.[] | select(.name == $name)] | if length == 1 then .[0] elif length == 0 then null else error("asset名が重複しています") end' "$remote_assets_path"
}

remote_has_digest() {
  local name=$1
  local digest=$2
  local size=$3
  jq -e --arg name "$name" --arg digest "$digest" --argjson size "$size" \
    'any(.[]; .name == $name and (.digest | ascii_downcase) == $digest and .size == $size)' \
    "$remote_assets_path" >/dev/null
}

remote_has_name() {
  local name=$1
  jq -e --arg name "$name" 'any(.[]; .name == $name)' "$remote_assets_path" >/dev/null
}

journal_mutation_intent() {
  local operation=$1
  local action=$2
  local role=$3
  local name=$4
  local asset_id_json=$5
  local digest=$6
  local size=$7
  local intent=$8
  journal_line=$(jq -c -n \
    --arg event intent --arg operation "$operation" --arg action "$action" --arg role "$role" \
    --arg name "$name" --arg digest "$digest" --arg intent "$intent" \
    --argjson release_id "$initial_release_id" --argjson asset_id "$asset_id_json" --argjson size "$size" \
    '{event: $event, operation: $operation, action: $action, role: $role, expectedReleaseId: $release_id, assetId: $asset_id, name: $name, digest: $digest, size: $size, intent: $intent}')
  append_journal_line "$journal_line"
}

journal_mutation_result() {
  local operation=$1
  local action=$2
  local role=$3
  local name=$4
  local asset_id_json=$5
  local status=$6
  local result=$7
  journal_line=$(jq -c -n \
    --arg event result --arg operation "$operation" --arg action "$action" --arg role "$role" \
    --arg name "$name" --arg result "$result" --argjson release_id "$initial_release_id" \
    --argjson asset_id "$asset_id_json" --argjson status "$status" \
    '{event: $event, operation: $operation, action: $action, role: $role, expectedReleaseId: $release_id, assetId: $asset_id, name: $name, httpStatus: $status, result: $result}')
  append_journal_line "$journal_line"
}

delete_asset() {
  local asset_id=$1
  local asset_name=$2
  local attempt
  local response_path="$work_directory/delete-response.json"
  local current_record
  local current_id
  local current_digest
  local expected_digest
  local current_size
  local asset_id_json
  local mutation_status
  if [[ "$in_rollback" == true ]]; then
    if ! ensure_time_budget "rollback asset削除: $asset_name" || ! reconfirm_mutation_context; then
      return 1
    fi
  else
    if ! reconfirm_mutation_context; then
      return 1
    fi
  fi
  if ! fetch_remote_assets; then
    printf 'asset削除前のremote asset再取得に失敗しました: %s\n' "$asset_name" >&2
    return 1
  fi
  current_record=$(remote_asset_record "$asset_name")
  if [[ "$current_record" == null ]] || ! current_id=$(jq -er '.id | numbers' <<<"$current_record") || ! current_digest=$(jq -er '.digest | strings | ascii_downcase' <<<"$current_record") || ! current_size=$(jq -er '.size | numbers' <<<"$current_record") || [[ "$current_id" != "$asset_id" ]]; then
    printf 'asset削除対象が再確認時点で変化しました: %s\n' "$asset_name" >&2
    return 1
  fi
  expected_digest=$current_digest
  asset_id_json=$asset_id
  for attempt in 1 2 3; do
    if ! reconfirm_mutation_context; then
      return 1
    fi
    if ! fetch_remote_assets; then
      printf 'asset削除retry前のremote asset再取得に失敗しました: %s\n' "$asset_name" >&2
      return 1
    fi
    current_record=$(remote_asset_record "$asset_name")
    if [[ "$current_record" == null ]] || ! current_id=$(jq -er '.id | numbers' <<<"$current_record") || ! current_digest=$(jq -er '.digest | strings | ascii_downcase' <<<"$current_record") || ! current_size=$(jq -er '.size | numbers' <<<"$current_record") || [[ "$current_id" != "$asset_id" || "$current_digest" != "$expected_digest" ]]; then
      manual_conflicts["$asset_name"]="asset削除retry前にasset idまたはdigestが変化しました"
      return 1
    fi
    if ! journal_mutation_intent delete '' '' "$asset_name" "$asset_id_json" "$current_digest" "$current_size" "asset id=$asset_id attempt=$attemptを削除"; then
      return 1
    fi
    request_once DELETE "$api_url/repos/$encoded_repository/releases/assets/$asset_id" "$response_path" '' ''
    mutation_status=$HTTP_STATUS
    if [[ "$HTTP_STATUS" == 204 ]]; then
      if [[ "${initial_ids[$asset_name]:-}" == "$asset_id" ]]; then
        deleted_initial_ids["$asset_name"]=true
      fi
      if ! journal_mutation_result delete '' '' "$asset_name" "$asset_id_json" 204 deleted; then
        return 1
      fi
      return 0
    fi
    if [[ "$HTTP_STATUS" == 401 ]]; then
      printf 'asset削除API tokenが期限切れまたは権限不正です: %s\n' "$asset_name" >&2
      return 1
    fi
    if is_retryable_status "$HTTP_STATUS"; then
      if fetch_remote_assets; then
        current_record=$(remote_asset_record "$asset_name")
        if [[ "$current_record" == null ]]; then
          if [[ "${initial_ids[$asset_name]:-}" == "$asset_id" ]]; then
            deleted_initial_ids["$asset_name"]=true
          fi
          if ! journal_mutation_result delete '' '' "$asset_name" "$asset_id_json" "$mutation_status" deleted-after-recheck; then
            return 1
          fi
          return 0
        fi
        if current_id=$(jq -er '.id | numbers' <<<"$current_record") && [[ "$current_id" != "$asset_id" ]]; then
          manual_conflicts["$asset_name"]="削除の曖昧応答後にasset idが変化しました: expected=$asset_id actual=$current_id"
          return 1
        fi
        if [[ "$current_record" != null ]] && current_digest=$(jq -er '.digest | strings | ascii_downcase' <<<"$current_record") && [[ "$current_digest" != "$expected_digest" ]]; then
          manual_conflicts["$asset_name"]="削除の曖昧応答後にasset digestが変化しました: expected=$expected_digest actual=$current_digest"
          return 1
        fi
      elif [[ "$HTTP_STATUS" == 401 ]]; then
        printf 'asset削除再確認API tokenが期限切れまたは権限不正です: %s\n' "$asset_name" >&2
        return 1
      fi
      if (( attempt < 3 )); then
        if ! sleep_for_retry "$attempt"; then
          return 1
        fi
        continue
      fi
    fi
    printf 'asset削除に失敗しました: %s HTTP %s\n' "$asset_name" "$HTTP_STATUS" >&2
    return 1
  done
  return 1
}
upload_asset() {
  local asset_name=$1
  local digest=$2
  local size=$3
  local asset_path=$4
  local action=$5
  local role=$6
  local encoded_name
  local attempt
  local response_path="$work_directory/upload-response.json"
  local current_record
  local current_id
  local mutation_status
  if [[ "$in_rollback" == true ]]; then
    if ! ensure_time_budget "rollback asset upload: $asset_name" || ! reconfirm_mutation_context; then
      return 1
    fi
  else
    if ! reconfirm_mutation_context; then
      return 1
    fi
  fi
  if ! fetch_remote_assets; then
    printf 'asset upload前のremote asset再取得に失敗しました: %s\n' "$asset_name" >&2
    return 1
  fi
  if remote_has_name "$asset_name"; then
    printf 'asset upload対象名が既に存在します: %s\n' "$asset_name" >&2
    return 1
  fi
  encoded_name=$(urlencode "$asset_name")
  for attempt in 1 2 3; do
    if ! reconfirm_mutation_context; then
      return 1
    fi
    if ! fetch_remote_assets; then
      printf 'asset upload retry前のremote asset再取得に失敗しました: %s\n' "$asset_name" >&2
      return 1
    fi
    if remote_has_name "$asset_name"; then
      manual_conflicts["$asset_name"]="asset upload retry前に同名assetが存在します"
      return 1
    fi
    if ! journal_mutation_intent upload "$action" "$role" "$asset_name" null "$digest" "$size" "asset name=$asset_name attempt=$attemptをupload"; then
      return 1
    fi
    request_once POST "$upload_api_url/repos/$encoded_repository/releases/$release_id/assets?name=$encoded_name" \
      "$response_path" "$asset_path" 'Content-Type: application/octet-stream'
    mutation_status=$HTTP_STATUS
    if [[ "$HTTP_STATUS" == 201 ]]; then
      if ! mark_upload_success "$action" "$role" "$asset_name" "$digest" "$size" "$response_path"; then
        return 1
      fi
      return 0
    fi
    if [[ "$HTTP_STATUS" == 401 ]]; then
      printf 'asset upload API tokenが期限切れまたは権限不正です: %s\n' "$asset_name" >&2
      return 1
    fi
    if is_retryable_status "$HTTP_STATUS"; then
      if fetch_remote_assets && remote_has_digest "$asset_name" "$digest" "$size"; then
        current_record=$(remote_asset_record "$asset_name")
        current_id=$(jq -er '.id | numbers' <<<"$current_record")
        manual_conflicts["$asset_name"]="uploadの曖昧応答後にasset idを確定できません: observed=$current_id"
        journal_mutation_result upload "$action" "$role" "$asset_name" "$current_id" "$mutation_status" manual-conflict
        return 1
      elif [[ "$HTTP_STATUS" == 401 ]]; then
        printf 'asset upload再確認API tokenが期限切れまたは権限不正です: %s\n' "$asset_name" >&2
        return 1
      fi
      if (( attempt < 3 )); then
        if ! sleep_for_retry "$attempt"; then
          return 1
        fi
        continue
      fi
    fi
    printf 'asset uploadに失敗しました: %s HTTP %s\n' "$asset_name" "$HTTP_STATUS" >&2
    return 1
  done
  return 1
}

encoded_tag=$(urlencode "$tag")
if ! request_read GET "$api_url/repos/$encoded_repository/releases/tags/$encoded_tag" "$release_path"; then
  printf '対象Releaseの取得に失敗しました: HTTP %s\n' "$HTTP_STATUS" >&2
  exit 1
fi
release_id=$(jq -er '.id | numbers | select(. > 0)' "$release_path")
release_tag=$(jq -er '.tag_name' "$release_path")
release_state=$(bash "$central_root/scripts/workflow/read-release-state.sh" "$release_path")
draft=$(jq -r '.draft' <<<"$release_state")
prerelease=$(jq -r '.prerelease' <<<"$release_state")
immutable=$(jq -r '.immutable' <<<"$release_state")
channel=$(jq -er '.application.release.channel' "$contract_path")
if [[ "$release_tag" != "$tag" || "$draft" != false ]]; then
  printf '%s\n' '対象Releaseのtagまたはdraft状態が不正です' >&2
  exit 1
fi
if [[ "$immutable" != false ]]; then
  printf '%s\n' 'immutable Releaseは公開対象にできません' >&2
  exit 1
fi
initial_release_id=$release_id
initial_release_tag=$release_tag
initial_draft=$draft
initial_prerelease=$prerelease
initial_immutable=$immutable
jq -n \
  --argjson id "$initial_release_id" \
  --arg tag "$initial_release_tag" \
  --argjson draft "$initial_draft" \
  --argjson prerelease "$initial_prerelease" \
  --argjson immutable "$initial_immutable" \
  '{id: $id, tag: $tag, draft: $draft, prerelease: $prerelease, immutable: $immutable}' \
  >"$recovery_directory/initial-release-state.json"
case "$channel" in
  latest)
    if [[ "$prerelease" != false ]]; then
      printf '%s\n' 'latest channelはprerelease Releaseを使えません' >&2
      exit 1
    fi
    ;;
  beta|dev)
    if [[ "$prerelease" != true ]]; then
      printf '%s\n' 'betaとdev channelはprerelease Releaseが必要です' >&2
      exit 1
    fi
    ;;
  *)
    printf '%s\n' 'channelが不正です' >&2
    exit 1
    ;;
esac

"$central_root/scripts/workflow/extract-archive.sh" "$assets_archive" "$extracted_assets" linux
assets_directory=$extracted_assets
if [[ -n "$(find "$assets_directory" -mindepth 1 -maxdepth 1 \( ! -type f -o -type l \) -print -quit)" ]]; then
  printf '%s\n' 'publish assetにregular file以外が含まれています' >&2
  exit 1
fi

if ! fetch_remote_assets; then
  exit 1
fi
(cd "$central_root" && env -u CENTRAL_APP_TOKEN pnpm exec tsx src/cli.ts plan-publish \
  --contract "$contract_path" --manifest "$manifest_path" \
  --remote-assets "$remote_assets_path" --assets-directory "$assets_directory" --output "$plan_path")

if [[ "$immutable" == true ]] && jq -e '.operations | any(.[]; .action != "skip")' "$plan_path" >/dev/null; then
  printf '%s\n' 'immutable Releaseへ変更が必要な公開計画は適用できません' >&2
  exit 1
fi
jq -e --arg repository "$repository" --arg tag "$tag" \
  '.schemaVersion == 1 and .repository == $repository and .tag == $tag and .publishOrder == ["payload", "metadata"]' \
  "$plan_path" >/dev/null
cp -- "$plan_path" "$recovery_directory/publish-plan.json"
cp -- "$remote_assets_path" "$recovery_directory/initial-remote-assets.json"

backup_directory="$recovery_backup_directory"
mkdir -p -- "$backup_directory"
declare -a backup_names=()
declare -a backup_digests=()
declare -a backup_sizes=()
declare -a backup_new_digests=()
declare -a backup_new_sizes=()
declare -a backup_paths=()
declare -a backup_ids=()
declare -a created_ids=()
declare -a created_names=()
declare -a created_digests=()
declare -a created_sizes=()
declare -A initial_ids=()
declare -A deleted_initial_ids=()
declare -A manual_conflicts=()

write_journal_initial() {
  local operation_json
  local action
  local name
  local role
  local digest
  local size
  local remote_record
  umask 077
  : >"$journal_path"
  chmod 600 "$journal_path"
  while IFS= read -r operation_json; do
    [[ -z "$operation_json" ]] && continue
    action=$(jq -er '.action' <<<"$operation_json")
    name=$(jq -er '.name' <<<"$operation_json")
    role=$(jq -er '.role' <<<"$operation_json")
    digest=$(jq -er '.digest | ascii_downcase' <<<"$operation_json")
    size=$(jq -er '.size | numbers' <<<"$operation_json")
    remote_record=$(remote_asset_record "$name")
    if [[ "$remote_record" != null ]]; then
      initial_ids["$name"]=$(jq -er '.id | numbers' <<<"$remote_record")
    fi
    if ! journal_line=$(jq -c -n \
      --arg event initial \
      --arg action "$action" \
      --arg role "$role" \
      --arg name "$name" \
      --arg digest "$digest" \
      --argjson size "$size" \
      --argjson remote "$remote_record" \
      '{event: $event, action: $action, role: $role, name: $name, digest: $digest, size: $size, remote: $remote}'); then
      return 1
    fi
    if ! append_journal_line "$journal_line"; then
      return 1
    fi
  done < <(jq -c '.operations[]' "$plan_path")
}

mark_upload_success() {
  local action=$1
  local role=$2
  local name=$3
  local digest=$4
  local size=$5
  local response_path=$6
  local asset_id
  if [[ -z "$response_path" ]] || ! asset_id=$(jq -er '.id | numbers | select(. > 0)' "$response_path"); then
    manual_conflicts["$name"]='upload応答でasset idを確定できません'
    journal_line=$(jq -c -n \
      --arg event result --arg operation upload --arg action "$action" --arg role "$role" \
      --arg name "$name" --arg digest "$digest" --argjson size "$size" --argjson release_id "$initial_release_id" \
      '{event: $event, operation: $operation, action: $action, role: $role, expectedReleaseId: $release_id, name: $name, digest: $digest, size: $size, assetId: null, httpStatus: 201, assetIdVerified: false}')
    append_journal_line "$journal_line"
    return 1
  fi
  if [[ "$in_rollback" == false ]]; then
    created_ids+=("$asset_id")
    created_names+=("$name")
    created_digests+=("$digest")
    created_sizes+=("$size")
  fi
  if ! journal_line=$(jq -c -n \
    --arg event result --arg operation upload --arg action "$action" --arg role "$role" \
    --arg name "$name" --arg digest "$digest" --argjson size "$size" --argjson release_id "$initial_release_id" \
    --argjson asset_id "$asset_id" \
    '{event: $event, operation: $operation, action: $action, role: $role, expectedReleaseId: $release_id, name: $name, digest: $digest, size: $size, assetId: $asset_id, httpStatus: 201, assetIdVerified: true}'); then
    return 1
  fi
  append_journal_line "$journal_line"
}

prepare_backups() {
  local operation_json
  local action
  local name
  local record
  local asset_id
  local digest
  local size
  local new_digest
  local new_size
  local backup_path
  local index=0
  while IFS= read -r operation_json; do
    [[ -z "$operation_json" ]] && continue
    if ! action=$(jq -er '.action' <<<"$operation_json"); then
      printf '%s\n' 'publish planのactionを解析できません' >&2
      return 1
    fi
    if [[ "$action" != replace && "$action" != update-metadata ]]; then
      continue
    fi
    if ! name=$(jq -er '.name' <<<"$operation_json") || ! new_digest=$(jq -er '.digest | ascii_downcase' <<<"$operation_json") || ! new_size=$(jq -er '.size | numbers' <<<"$operation_json"); then
      printf '%s\n' 'publish planの置換対象を解析できません' >&2
      return 1
    fi
    record=$(jq -c --arg name "$name" '[.[] | select(.name == $name)] | if length == 1 then .[0] else empty end' "$remote_assets_path")
    if [[ -z "$record" ]]; then
      printf 'backup対象のremote assetが一意ではありません: %s\n' "$name" >&2
      return 1
    fi
    if ! asset_id=$(jq -er '.id | numbers' <<<"$record") || ! digest=$(jq -er '.digest | strings | ascii_downcase' <<<"$record") || ! size=$(jq -er '.size | numbers' <<<"$record"); then
      printf 'backup対象のremote asset metadataが不正です: %s\n' "$name" >&2
      return 1
    fi
    backup_path="$backup_directory/$index.asset"
    if ! download_remote_asset "$asset_id" "$name" "$digest" "$size" "$backup_path"; then
      return 1
    fi
    backup_names[index]="$name"
    backup_ids[index]="$asset_id"
    backup_digests[index]="$digest"
    backup_sizes[index]="$size"
    backup_new_digests[index]="$new_digest"
    backup_new_sizes[index]="$new_size"
    backup_paths[index]="$backup_path"
    jq -n \
      --arg name "$name" --argjson asset_id "$asset_id" --arg digest "$digest" --argjson size "$size" \
      --arg new_digest "$new_digest" --argjson new_size "$new_size" \
      '{name: $name, assetId: $asset_id, digest: $digest, size: $size, replacementDigest: $new_digest, replacementSize: $new_size}' \
      >"$recovery_backup_directory/$index.json"
    index=$((index + 1))
  done < <(jq -c '.operations[]' "$plan_path")
}

if ! write_journal_initial; then
  printf '%s\n' 'publish開始時のjournalを作成できません' >&2
  exit 1
fi

if ! prepare_backups; then
  printf '%s\n' '置換対象assetのbackupを作成できません' >&2
  exit 1
fi

declare -A metadata_removed=()
remove_old_metadata() {
  local operation_json
  local action
  local name
  local role
  local asset_id
  local record
  while IFS= read -r operation_json; do
    [[ -z "$operation_json" ]] && continue
    action=$(jq -er '.action' <<<"$operation_json")
    role=$(jq -er '.role' <<<"$operation_json")
    if [[ "$action" != replace && "$action" != update-metadata ]]; then
      continue
    fi
    if [[ "$role" != macos-metadata && "$role" != windows-metadata ]]; then
      continue
    fi
    name=$(jq -er '.name' <<<"$operation_json")
    record=$(remote_asset_record "$name")
    if [[ "$record" == null ]] || ! asset_id=$(jq -er '.id | numbers' <<<"$record"); then
      printf 'metadata置換対象のremote assetがありません: %s\n' "$name" >&2
      return 1
    fi
    if ! delete_asset "$asset_id" "$name"; then
      return 1
    fi
    metadata_removed["$name"]=1
    if ! fetch_remote_assets; then
      return 1
    fi
  done < <(jq -c '.operations[] | select((.action == "replace" or .action == "update-metadata") and (.role == "macos-metadata" or .role == "windows-metadata"))' "$plan_path")
}

operation_error=''
publish_operation() {
  local operation_json=$1
  local action
  local name
  local digest
  local size
  local role
  local asset_path
  local asset_id
  if ! action=$(jq -er '.action' <<<"$operation_json") || ! name=$(jq -er '.name' <<<"$operation_json") || ! digest=$(jq -er '.digest | ascii_downcase' <<<"$operation_json") || ! size=$(jq -er '.size | numbers' <<<"$operation_json") || ! role=$(jq -er '.role' <<<"$operation_json"); then
    operation_error='publish planのoperationを解析できません'
    return 1
  fi
  if [[ "$name" == *$'\n'* || "$name" == *$'\r'* || "$name" == *$'\0'* ]]; then
    operation_error="asset filenameにtransport上の制御文字があります: $name"
    return 1
  fi
  asset_path="$assets_directory/$name"
  if [[ "$action" != skip && ( ! -f "$asset_path" || -L "$asset_path" ) ]]; then
    operation_error="publish assetがありません: $name"
    return 1
  fi
  case "$action" in
    skip)
      ;;
    upload)
      if ! upload_asset "$name" "$digest" "$size" "$asset_path" "$action" "$role"; then
        operation_error="asset uploadに失敗しました: $name"
        return 1
      fi
      ;;
    replace|update-metadata)
      if [[ -n "${metadata_removed[$name]+present}" ]]; then
        asset_id=''
      else
        asset_id=$(remote_asset_id "$name")
        if [[ -z "$asset_id" ]]; then
          operation_error="置換対象のremote assetがありません: $name"
          return 1
        fi
        if ! delete_asset "$asset_id" "$name"; then
          operation_error="asset削除に失敗しました: $name"
          return 1
        fi
      fi
      if ! upload_asset "$name" "$digest" "$size" "$asset_path" "$action" "$role"; then
        operation_error="asset uploadに失敗しました: $name"
        return 1
      fi
      ;;
    *)
      operation_error="publish planのactionが不正です: $action"
      return 1
      ;;
  esac
  printf '公開処理: %s %s\n' "$role" "$name"
  if ! fetch_remote_assets; then
    operation_error="公開後のremote asset取得に失敗しました: $name"
    return 1
  fi
  if [[ "$action" != skip ]]; then
    if ! remote_has_digest "$name" "$digest" "$size"; then
      operation_error="upload後のremote asset digest検証に失敗しました: $name"
      return 1
    fi
  fi
}

publish_plan() {
  local operation_json
  while IFS= read -r operation_json; do
    [[ -z "$operation_json" ]] && continue
    if ! publish_operation "$operation_json"; then
      return 1
    fi
  done < <(jq -c '.operations[] | select(.role != "macos-metadata" and .role != "windows-metadata")' "$plan_path")

  if ! remove_old_metadata; then
    operation_error='旧metadataの削除に失敗しました'
    return 1
  fi

  while IFS= read -r operation_json; do
    [[ -z "$operation_json" ]] && continue
    if ! publish_operation "$operation_json"; then
      return 1
    fi
  done < <(jq -c '.operations[] | select(.role == "macos-metadata" or .role == "windows-metadata")' "$plan_path")
}

rollback_error=''
append_rollback_error() {
  local message=$1
  if [[ -z "$rollback_error" ]]; then
    rollback_error=$message
  else
    rollback_error+="; $message"
  fi
}

is_confirmed_created_id() {
  local candidate=$1
  local index
  for ((index = 0; index < ${#created_ids[@]}; index++)); do
    if [[ "${created_ids[index]}" == "$candidate" ]] && jq -s -e --argjson id "$candidate" --argjson release_id "$initial_release_id" \
      'any(.[]; .event == "result" and .operation == "upload" and .expectedReleaseId == $release_id and .httpStatus == 201 and .assetId == $id and .assetIdVerified == true)' \
      "$journal_path" >/dev/null; then
      return 0
    fi
  done
  return 1
}

journal_confirms_deleted_id() {
  local candidate=$1
  jq -s -e --argjson id "$candidate" --argjson release_id "$initial_release_id" \
    'any(.[]; .event == "result" and .operation == "delete" and .expectedReleaseId == $release_id and (.result == "deleted" or .result == "deleted-after-recheck") and .assetId == $id)' \
    "$journal_path" >/dev/null
}

rollback_created_assets() {
  local index
  local created_id
  local name
  local expected_digest
  local expected_size
  local current_record
  local current_digest
  local current_size
  local current_name
  local id_count
  if ! fetch_remote_assets; then
    append_rollback_error '新規asset削除前のremote asset取得に失敗しました'
    return 1
  fi
  for ((index = 0; index < ${#created_ids[@]}; index++)); do
    created_id=${created_ids[index]}
    name=${created_names[index]}
    expected_digest=${created_digests[index]}
    expected_size=${created_sizes[index]}
    id_count=$(jq --argjson id "$created_id" '[.[] | select(.id == $id)] | length' "$remote_assets_path")
    if [[ "$id_count" == 0 ]]; then
      if jq -e --arg name "$name" 'any(.[]; .name == $name)' "$remote_assets_path" >/dev/null; then
        manual_conflicts["$name"]="このrunの新規asset id=$created_idが消失し同名assetが存在します"
        append_rollback_error "新規asset idの外部競合: $created_id"
      fi
      continue
    fi
    if [[ "$id_count" != 1 ]]; then
      append_rollback_error "新規asset idが重複しています: $created_id"
      continue
    fi
    current_record=$(jq -c --argjson id "$created_id" '[.[] | select(.id == $id)][0]' "$remote_assets_path")
    current_name=$(jq -er '.name' <<<"$current_record")
    current_digest=$(jq -er '.digest | strings | ascii_downcase' <<<"$current_record")
    current_size=$(jq -er '.size | numbers' <<<"$current_record")
    if [[ "$current_name" != "$name" || "$current_digest" != "$expected_digest" || "$current_size" != "$expected_size" ]]; then
      manual_conflicts["$name"]="新規asset idのnameまたはdigestが変化しました: id=$created_id"
      append_rollback_error "新規assetの競合を検出しました: $name id=$created_id"
      continue
    fi
    if ! delete_asset "$created_id" "$name"; then
      append_rollback_error "新規assetの削除に失敗しました: $name id=$created_id"
      continue
    fi
    if ! fetch_remote_assets; then
      append_rollback_error "新規asset削除後のremote asset取得に失敗しました: $name"
      continue
    fi
    if jq -e --argjson id "$created_id" 'any(.[]; .id == $id)' "$remote_assets_path" >/dev/null; then
      append_rollback_error "新規asset idが削除後も残っています: $created_id"
    elif jq -e --arg name "$name" 'any(.[]; .name == $name)' "$remote_assets_path" >/dev/null; then
      manual_conflicts["$name"]="新規asset削除後に別asset idが同名で存在します"
      append_rollback_error "新規asset削除後の同名競合: $name"
    fi
  done
}

rollback_backups() {
  local index
  local name
  local old_digest
  local old_size
  local new_digest
  local new_size
  local backup_path
  local initial_id
  local current_record
  local current_count
  local current_digest
  local current_size
  local current_id
  rollback_error=''
  in_rollback=true
  if [[ -n "$release_conflict_error" ]]; then
    append_rollback_error "$release_conflict_error。別Releaseへrollbackしません"
    in_rollback=false
    return 1
  fi
  if ! reconfirm_mutation_context; then
    append_rollback_error "rollback開始時の競合確認に失敗しました: ${release_conflict_error:-不明な競合}"
    in_rollback=false
    return 1
  fi
  if ! rollback_created_assets; then
    append_rollback_error '新規assetのrollbackに失敗しました'
  fi
  if [[ -n "$release_conflict_error" ]]; then
    append_rollback_error "$release_conflict_error。別Releaseへrollbackしません"
    in_rollback=false
    return 1
  fi
  if ! fetch_remote_assets; then
    append_rollback_error 'rollback前のremote asset取得に失敗しました'
    in_rollback=false
    return 1
  fi
  for ((index = 0; index < ${#backup_names[@]}; index++)); do
    name=${backup_names[index]}
    old_digest=${backup_digests[index]}
    old_size=${backup_sizes[index]}
    new_digest=${backup_new_digests[index]}
    new_size=${backup_new_sizes[index]}
    backup_path=${backup_paths[index]}
    initial_id=${backup_ids[index]}
    current_count=$(jq --arg name "$name" '[.[] | select(.name == $name)] | length' "$remote_assets_path")
    if [[ "$current_count" -gt 1 ]]; then
      append_rollback_error "rollback対象assetが重複しています: $name"
      continue
    fi
    if [[ "$current_count" == 0 ]]; then
      if [[ -z "${deleted_initial_ids[$name]+present}" ]] || ! journal_confirms_deleted_id "$initial_id"; then
        manual_conflicts["$name"]="初期asset id=$initial_idの消失をjournalで確認できません"
        append_rollback_error "rollback対象assetが予期せず消失しています: $name id=$initial_id"
        continue
      fi
    fi
    if [[ "$current_count" == 1 ]]; then
      current_record=$(jq -c --arg name "$name" '[.[] | select(.name == $name)][0]' "$remote_assets_path")
      current_id=$(jq -er '.id | numbers' <<<"$current_record")
      current_digest=$(jq -er '.digest | ascii_downcase' <<<"$current_record")
      current_size=$(jq -er '.size | numbers' <<<"$current_record")
      if [[ "$current_id" == "$initial_id" ]]; then
        if [[ "$current_digest" == "$old_digest" && "$current_size" == "$old_size" ]]; then
          continue
        fi
        manual_conflicts["$name"]="初期asset id=$initial_idのdigestが変化しました"
        append_rollback_error "初期assetの競合を検出しました: $name id=$initial_id"
        continue
      fi
      if ! is_confirmed_created_id "$current_id" || [[ "$current_digest" != "$new_digest" || "$current_size" != "$new_size" ]]; then
        manual_conflicts["$name"]="置換後assetがこのrunの確定upload idではありません: $current_id"
        append_rollback_error "競合のためassetを安全に復元できません: $name id=$current_id"
        continue
      fi
      if ! delete_asset "$current_id" "$name"; then
        append_rollback_error "復元前の新asset削除に失敗しました: $name"
        continue
      fi
      if ! fetch_remote_assets; then
        append_rollback_error "新asset削除後のremote asset取得に失敗しました: $name"
        continue
      fi
    fi
    if ! upload_asset "$name" "$old_digest" "$old_size" "$backup_path" rollback rollback; then
      append_rollback_error "旧assetの復元uploadに失敗しました: $name"
      continue
    fi
    if ! fetch_remote_assets || ! remote_has_digest "$name" "$old_digest" "$old_size"; then
      append_rollback_error "旧assetの復元digest検証に失敗しました: $name"
    fi
  done
  in_rollback=false
  [[ -z "$rollback_error" ]]
}

report_failure_with_rollback() {
  local original_error=$1
  local rollback_succeeded=false
  if rollback_backups; then
    rollback_succeeded=true
    printf '%s\n' "$original_error" >&2
  else
    printf '%s。rollbackにも失敗しました: %s\n' "$original_error" "$rollback_error" >&2
  fi
  {
    printf 'original error: %s\n' "$original_error"
    printf 'rollback succeeded: %s\n' "$rollback_succeeded"
    printf 'release id: %s\n' "$release_id"
    printf 'repository: %s\n' "$repository"
    printf 'tag: %s\n' "$tag"
    printf 'journal: %s\n' "$journal_path"
    printf 'manual recovery: journalのexpectedReleaseId、assetId、digestをAPIで再確認して手動復旧してください。別Releaseへrollbackしないでください。\n'
    if [[ -n "$release_conflict_error" ]]; then
      printf 'release conflict: %s\n' "$release_conflict_error"
    fi
    for name in "${!manual_conflicts[@]}"; do
      printf 'manual conflict %s: %s\n' "$name" "${manual_conflicts[$name]}"
    done
  } >"$recovery_directory/rollback-result.txt"
  printf 'durable recovery artifact=%s directory=%s journal=%s。Release idとasset idを再確認して手動復旧してください。\n' \
    "$recovery_artifact_name" "$recovery_directory" "$journal_path" >&2
  for name in "${!manual_conflicts[@]}"; do
    printf 'manual conflict: %s: %s\n' "$name" "${manual_conflicts[$name]}" >&2
  done
  if [[ -n "$release_conflict_error" ]]; then
    printf '別Releaseへrollbackせず手動復旧してください: repository=%s tag=%s expectedReleaseId=%s %s\n' \
      "$repository" "$tag" "$initial_release_id" "$release_conflict_error" >&2
  fi
}

if ! publish_plan; then
  original_error=${operation_error:-'publish操作に失敗しました'}
  report_failure_with_rollback "$original_error"
  exit 1
fi

verify_published_assets() {
  local asset_name
  local asset_size
  local asset_digest
  if ! reconfirm_mutation_context; then
    return 1
  fi
  if ! fetch_remote_assets; then
    return 1
  fi
  while IFS=$'\t' read -r asset_name asset_size asset_digest; do
    if [[ -z "$asset_name" || -z "$asset_digest" ]]; then
      printf '%s\n' 'manifest assetの再検証入力が空です' >&2
      return 1
    fi
    if ! jq -e --arg name "$asset_name" --arg digest "$asset_digest" --argjson size "$asset_size" \
      'any(.[]; .name == $name and .size == $size and (.digest | ascii_downcase) == $digest)' "$remote_assets_path" >/dev/null; then
      printf '公開後のasset digest検証に失敗しました: %s\n' "$asset_name" >&2
      return 1
    fi
  done < <(jq -r '.assets[] | [.name, (.size | tostring), (.digest | ascii_downcase)] | @tsv' "$manifest_path")
}

if ! verify_published_assets; then
  original_error='公開後のasset digest検証に失敗しました'
  report_failure_with_rollback "$original_error"
  exit 1
fi

journal_line=$(jq -c -n \
  --arg event result --arg operation publish --arg result success --argjson release_id "$initial_release_id" \
  '{event: $event, operation: $operation, result: $result, expectedReleaseId: $release_id}')
append_journal_line "$journal_line"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    printf '%s\n' '## Release公開結果'
    printf '%s\n' ''
    printf '%s\n' "- repository: $repository"
    printf '%s\n' "- tag: $tag"
    printf '%s\n' "- source SHA: $source_sha"
    printf '%s\n' "- version: $version"
    printf '%s\n' "- config digest: $config_digest"
    printf '%s\n' "- run URL: $run_url"
    printf '%s\n' ''
    jq -r '.assets[] | "- \(.name): \(.digest) (\(.size) bytes)"' "$manifest_path"
  } >>"$GITHUB_STEP_SUMMARY"
fi
