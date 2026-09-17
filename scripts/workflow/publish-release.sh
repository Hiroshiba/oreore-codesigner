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
if (( operation_timeout_seconds + rollback_reserve_seconds >= 3600 )); then
  printf '%s\n' 'App tokenの有効時間内にrollback時間を確保できません' >&2
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

work_directory=$(mktemp -d "${RUNNER_TEMP:-/tmp}/central-publish-release.XXXXXX")
auth_header_path="$work_directory/authorization-header.txt"
umask 077
printf 'Authorization: Bearer %s\n' "$token" >"$auth_header_path"
remote_assets_path="$work_directory/remote-assets.json"
release_path="$work_directory/release.json"
plan_path="$work_directory/publish-plan.json"
extracted_assets="$work_directory/assets"
journal_path="${RUNNER_TEMP:-/tmp}/central-publish-journal-${GITHUB_RUN_ID:-local}.jsonl"
cleanup() {
  local status=$?
  local cleanup_status=0
  if ! rm -rf -- "$work_directory"; then
    printf '%s\n' 'publish用一時directoryの削除に失敗しました' >&2
    cleanup_status=1
  fi
  if (( status != 0 )); then
    exit "$status"
  fi
  exit "$cleanup_status"
}
trap cleanup EXIT

urlencode() {
  jq -nr --arg value "$1" '$value | @uri'
}

ensure_time_budget() {
  local phase=$1
  local now
  now=$(date +%s)
  if [[ "$in_rollback" == true ]]; then
    if (( now + curl_max_seconds >= rollback_deadline )); then
      printf 'rollback時間を確保できません: %s\n' "$phase" >&2
      return 1
    fi
  elif (( now + rollback_reserve_seconds + curl_max_seconds >= operation_deadline )); then
    printf 'publish時間を確保できません: %s\n' "$phase" >&2
    return 1
  fi
}

sleep_for_retry() {
  local seconds=$1
  if ! ensure_time_budget 'retry待機'; then
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
  CENTRAL_DEADLINE_EPOCH="$operation_deadline" \
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
  if ! ensure_time_budget "GitHub API $method"; then
    HTTP_STATUS=000
    return 1
  fi
  if [[ -n "$body_path" ]]; then
    response_code=$(curl --silent --show-error --request "$method" \
      --connect-timeout "$curl_max_seconds" --max-time "$curl_max_seconds" \
      --header 'Accept: application/vnd.github+json' \
      --header 'X-GitHub-Api-Version: 2022-11-28' \
      --header "@$auth_header_path" \
      --header "$content_type" --data-binary "@$body_path" \
      --output "$output_path" --write-out '%{http_code}' "$url") || curl_status=$?
  else
    response_code=$(curl --silent --show-error --request "$method" \
      --connect-timeout "$curl_max_seconds" --max-time "$curl_max_seconds" \
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
  local response_code
  local curl_status=0
  local location
  if ! ensure_time_budget 'Release asset download'; then
    HTTP_STATUS=000
    return 1
  fi
  rm -f -- "$header_path"
  response_code=$(curl --silent --show-error --request GET \
    --connect-timeout "$curl_max_seconds" --max-time "$curl_max_seconds" \
    --header 'Accept: application/octet-stream' \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    --header "@$auth_header_path" \
    --dump-header "$header_path" --output /dev/null --write-out '%{http_code}' "$url") || curl_status=$?
  if (( curl_status != 0 )); then
    HTTP_STATUS=000
    return
  fi
  if [[ ! "$response_code" =~ ^[0-9]{3}$ ]]; then
    HTTP_STATUS=000
    return
  fi
  HTTP_STATUS=$response_code
  if [[ ! "$HTTP_STATUS" =~ ^3[0-9][0-9]$ ]]; then
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
  rm -f -- "$output_path"
  response_code=$(curl --silent --show-error --request GET \
    --connect-timeout "$curl_max_seconds" --max-time "$curl_max_seconds" \
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
    if [[ "$HTTP_STATUS" =~ ^2[0-9][0-9]$ ]]; then
      local actual_size
      local actual_digest
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
  if ! request_read GET "$api_url/repos/$encoded_repository/releases/tags/$encoded_tag" "$current_path"; then
    release_conflict_error="Release再確認に失敗しました: HTTP $HTTP_STATUS"
    return 1
  fi
  if ! current_id=$(jq -er '.id | numbers | select(. > 0)' "$current_path") || ! current_tag=$(jq -er '.tag_name' "$current_path"); then
    release_conflict_error='Release再確認の応答が不正です'
    return 1
  fi
  if [[ "$current_id" != "$release_id" || "$current_tag" != "$tag" ]]; then
    release_conflict_error="Release競合を検出しました: expected_id=$release_id actual_id=$current_id expected_tag=$tag actual_tag=$current_tag"
    return 1
  fi
  return 0
}

reconfirm_mutation_context() {
  local current_tag_path="$work_directory/reconfirm-tag.json"
  local current_source_sha
  local deadline_epoch=$operation_deadline
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

delete_asset() {
  local asset_id=$1
  local asset_name=$2
  local attempt
  local response_path="$work_directory/delete-response.json"
  local current_record
  local current_id
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
  if [[ "$current_record" == null ]] || ! current_id=$(jq -er '.id | numbers' <<<"$current_record") || [[ "$current_id" != "$asset_id" ]]; then
    printf 'asset削除対象が再確認時点で変化しました: %s\n' "$asset_name" >&2
    return 1
  fi
  for attempt in 1 2 3; do
    request_once DELETE "$api_url/repos/$encoded_repository/releases/assets/$asset_id" "$response_path" '' ''
    if [[ "$HTTP_STATUS" == 204 ]]; then
      deleted_names["$asset_name"]=true
      if ! jq -c -n --arg event deleted --arg name "$asset_name" --argjson asset_id "$asset_id" \
        '{event: $event, name: $name, assetId: $asset_id}' >>"$journal_path"; then
        printf 'asset削除journalの記録に失敗しました: %s\n' "$asset_name" >&2
        return 1
      fi
      return 0
    fi
    if [[ "$HTTP_STATUS" == 401 ]]; then
      printf 'asset削除API tokenが期限切れまたは権限不正です: %s\n' "$asset_name" >&2
      return 1
    fi
    if is_retryable_status "$HTTP_STATUS"; then
      if fetch_remote_assets && ! remote_has_name "$asset_name"; then
        deleted_names["$asset_name"]=true
        if ! jq -c -n --arg event deleted --arg name "$asset_name" --argjson asset_id "$asset_id" \
          '{event: $event, name: $name, assetId: $asset_id, uncertain: true}' >>"$journal_path"; then
          printf 'asset削除journalの記録に失敗しました: %s\n' "$asset_name" >&2
          return 1
        fi
        return 0
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
    request_once POST "$upload_api_url/repos/$encoded_repository/releases/$release_id/assets?name=$encoded_name" \
      "$response_path" "$asset_path" 'Content-Type: application/octet-stream'
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
        if ! mark_upload_success "$action" "$role" "$asset_name" "$digest" "$size" ''; then
          return 1
        fi
        return 0
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

backup_directory="$work_directory/backups"
mkdir -p -- "$backup_directory"
declare -a backup_names=()
declare -a backup_digests=()
declare -a backup_sizes=()
declare -a backup_new_digests=()
declare -a backup_new_sizes=()
declare -a backup_paths=()
declare -a created_names=()
declare -a created_digests=()
declare -a created_sizes=()
declare -A initial_exists=()
declare -A deleted_names=()

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
  while IFS= read -r operation_json; do
    [[ -z "$operation_json" ]] && continue
    action=$(jq -er '.action' <<<"$operation_json")
    name=$(jq -er '.name' <<<"$operation_json")
    role=$(jq -er '.role' <<<"$operation_json")
    digest=$(jq -er '.digest | ascii_downcase' <<<"$operation_json")
    size=$(jq -er '.size | numbers' <<<"$operation_json")
    remote_record=$(remote_asset_record "$name")
    if [[ "$remote_record" != null ]]; then
      initial_exists["$name"]=true
    fi
    if ! jq -c -n \
      --arg event initial \
      --arg action "$action" \
      --arg role "$role" \
      --arg name "$name" \
      --arg digest "$digest" \
      --argjson size "$size" \
      --argjson remote "$remote_record" \
      '{event: $event, action: $action, role: $role, name: $name, digest: $digest, size: $size, remote: $remote}' \
      >>"$journal_path"; then
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
  if [[ "$in_rollback" == false && -z "${initial_exists[$name]+present}" ]]; then
    created_names+=("$name")
    created_digests+=("$digest")
    created_sizes+=("$size")
  fi
  if [[ -n "$response_path" ]] && asset_id=$(jq -er '.id | numbers' "$response_path"); then
    if ! jq -c -n \
      --arg event uploaded \
      --arg action "$action" \
      --arg role "$role" \
      --arg name "$name" \
      --arg digest "$digest" \
      --argjson size "$size" \
      --argjson asset_id "$asset_id" \
      '{event: $event, action: $action, role: $role, name: $name, digest: $digest, size: $size, assetId: $asset_id}' \
      >>"$journal_path"; then
      return 1
    fi
  else
    if ! jq -c -n \
      --arg event uploaded \
      --arg action "$action" \
      --arg role "$role" \
      --arg name "$name" \
      --arg digest "$digest" \
      --argjson size "$size" \
      '{event: $event, action: $action, role: $role, name: $name, digest: $digest, size: $size, assetIdVerified: false}' \
      >>"$journal_path"; then
      return 1
    fi
  fi
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
    backup_digests[index]="$digest"
    backup_sizes[index]="$size"
    backup_new_digests[index]="$new_digest"
    backup_new_sizes[index]="$new_size"
    backup_paths[index]="$backup_path"
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

rollback_created_assets() {
  local index
  local name
  local expected_digest
  local expected_size
  local current_record
  local current_count
  local current_digest
  local current_size
  local current_id
  if ! fetch_remote_assets; then
    append_rollback_error '新規asset削除前のremote asset取得に失敗しました'
    return 1
  fi
  for ((index = 0; index < ${#created_names[@]}; index++)); do
    name=${created_names[index]}
    expected_digest=${created_digests[index]}
    expected_size=${created_sizes[index]}
    current_count=$(jq --arg name "$name" '[.[] | select(.name == $name)] | length' "$remote_assets_path")
    if [[ "$current_count" == 0 ]]; then
      continue
    fi
    if [[ "$current_count" != 1 ]]; then
      append_rollback_error "新規assetが重複しています: $name"
      continue
    fi
    current_record=$(remote_asset_record "$name")
    current_digest=$(jq -er '.digest | strings | ascii_downcase' <<<"$current_record")
    current_size=$(jq -er '.size | numbers' <<<"$current_record")
    if [[ "$current_digest" != "$expected_digest" || "$current_size" != "$expected_size" ]]; then
      append_rollback_error "新規assetの競合を検出しました: $name"
      continue
    fi
    current_id=$(jq -er '.id | numbers' <<<"$current_record")
    if ! delete_asset "$current_id" "$name"; then
      append_rollback_error "新規assetの削除に失敗しました: $name"
      continue
    fi
    if ! fetch_remote_assets || remote_has_name "$name"; then
      append_rollback_error "新規asset削除後の検証に失敗しました: $name"
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
    current_count=$(jq --arg name "$name" '[.[] | select(.name == $name)] | length' "$remote_assets_path")
    if [[ "$current_count" -gt 1 ]]; then
      append_rollback_error "rollback対象assetが重複しています: $name"
      continue
    fi
    if [[ "$current_count" == 0 && -z "${deleted_names[$name]+present}" ]]; then
      append_rollback_error "rollback対象assetが予期せず消失しています: $name"
      continue
    fi
    if [[ "$current_count" == 1 ]]; then
      current_record=$(jq -c --arg name "$name" '[.[] | select(.name == $name)][0]' "$remote_assets_path")
      current_digest=$(jq -er '.digest | ascii_downcase' <<<"$current_record")
      current_size=$(jq -er '.size | numbers' <<<"$current_record")
      if [[ "$current_digest" == "$old_digest" && "$current_size" == "$old_size" ]]; then
        continue
      fi
      if [[ "$current_digest" != "$new_digest" || "$current_size" != "$new_size" ]]; then
        append_rollback_error "競合のためassetを安全に復元できません: $name"
        continue
      fi
      current_id=$(jq -er '.id | numbers' <<<"$current_record")
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
  if rollback_backups; then
    printf '%s\n' "$original_error" >&2
  else
    printf '%s。rollbackにも失敗しました: %s\n' "$original_error" "$rollback_error" >&2
  fi
  if [[ -n "$release_conflict_error" ]]; then
    printf '別Releaseへrollbackせず、手動復旧してください: repository=%s tag=%s expectedReleaseId=%s %s journal=%s\n' \
      "$repository" "$tag" "$release_id" "$release_conflict_error" "$journal_path" >&2
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
