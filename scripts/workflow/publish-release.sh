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
token_file=${CENTRAL_APP_TOKEN_FILE:?CENTRAL_APP_TOKEN_FILEが必要です}

if [[ ! -f "$token_file" || -L "$token_file" ]]; then
  printf '%s\n' 'GitHub App token fileが不正です' >&2
  exit 1
fi
token=$(<"$token_file")
if [[ -z "$token" ]]; then
  printf '%s\n' 'GitHub App tokenが空です' >&2
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
remote_assets_path="$work_directory/remote-assets.json"
release_path="$work_directory/release.json"
plan_path="$work_directory/publish-plan.json"
extracted_assets="$work_directory/assets"
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

resolved_tag_path="$work_directory/resolved-tag.json"
CENTRAL_SOURCE_REPOSITORY="$repository" \
  CENTRAL_SOURCE_TAG="$tag" \
  CENTRAL_TAG_OUTPUT="$resolved_tag_path" \
  "$central_root/scripts/workflow/resolve-tag.sh"
resolved_source_sha=$(jq -er '.sourceSha' "$resolved_tag_path")
if [[ "${resolved_source_sha,,}" != "${source_sha,,}" ]]; then
  printf 'tagのsource SHAがmanifestと一致しません: %s\n' "$resolved_source_sha" >&2
  exit 1
fi

urlencode() {
  jq -nr --arg value "$1" '$value | @uri'
}

request_once() {
  local method=$1
  local url=$2
  local output_path=$3
  local body_path=$4
  local content_type=$5
  local response_code
  local curl_status=0
  if [[ -n "$body_path" ]]; then
    response_code=$(curl --silent --show-error --location --request "$method" \
      --header 'Accept: application/vnd.github+json' \
      --header 'X-GitHub-Api-Version: 2022-11-28' \
      --header "Authorization: Bearer $token" \
      --header "$content_type" --data-binary "@$body_path" \
      --output "$output_path" --write-out '%{http_code}' "$url") || curl_status=$?
  else
    response_code=$(curl --silent --show-error --location --request "$method" \
      --header 'Accept: application/vnd.github+json' \
      --header 'X-GitHub-Api-Version: 2022-11-28' \
      --header "Authorization: Bearer $token" \
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
    if ! is_retryable_status "$HTTP_STATUS" || (( attempt == 3 )); then
      return 1
    fi
    sleep "$attempt"
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
    if ! request_read GET "$api_url/repos/$repository/releases/$release_id/assets?per_page=100&page=$page" "$page_path"; then
      printf 'Release asset一覧の取得に失敗しました: HTTP %s\n' "$HTTP_STATUS" >&2
      return 1
    fi
    jq -e 'type == "array"' "$page_path" >/dev/null
    page_count=$(jq -er 'length' "$page_path")
    jq -s '.[0] + .[1]' "$accumulator" "$page_path" >"$work_directory/remote-next.json"
    mv -- "$work_directory/remote-next.json" "$accumulator"
    if (( page_count < 100 )); then
      break
    fi
    page=$((page + 1))
    if (( page > 100 )); then
      printf '%s\n' 'Release assetのpaginationが上限を超えました' >&2
      return 1
    fi
  done
  cp -- "$accumulator" "$remote_assets_path"
}

remote_asset_id() {
  local name=$1
  jq -r --arg name "$name" '[.[] | select(.name == $name)][0].id // empty' "$remote_assets_path"
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
  for attempt in 1 2 3; do
    request_once DELETE "$api_url/repos/$repository/releases/assets/$asset_id" "$response_path" '' ''
    if [[ "$HTTP_STATUS" == 204 ]]; then
      return 0
    fi
    if is_retryable_status "$HTTP_STATUS"; then
      if fetch_remote_assets && ! remote_has_name "$asset_name"; then
        return 0
      fi
      if (( attempt < 3 )); then
        sleep "$attempt"
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
  local encoded_name
  local attempt
  local response_path="$work_directory/upload-response.json"
  encoded_name=$(urlencode "$asset_name")
  for attempt in 1 2 3; do
    request_once POST "$upload_api_url/repos/$repository/releases/$release_id/assets?name=$encoded_name" \
      "$response_path" "$asset_path" 'Content-Type: application/octet-stream'
    if [[ "$HTTP_STATUS" == 201 ]]; then
      return 0
    fi
    if is_retryable_status "$HTTP_STATUS"; then
      if fetch_remote_assets && remote_has_digest "$asset_name" "$digest" "$size"; then
        return 0
      fi
      if (( attempt < 3 )); then
        sleep "$attempt"
        continue
      fi
    fi
    printf 'asset uploadに失敗しました: %s HTTP %s\n' "$asset_name" "$HTTP_STATUS" >&2
    return 1
  done
  return 1
}

encoded_tag=$(urlencode "$tag")
if ! request_read GET "$api_url/repos/$repository/releases/tags/$encoded_tag" "$release_path"; then
  printf '対象Releaseの取得に失敗しました: HTTP %s\n' "$HTTP_STATUS" >&2
  exit 1
fi
release_id=$(jq -er '.id | numbers' "$release_path")
release_tag=$(jq -er '.tag_name' "$release_path")
draft=$(jq -er '.draft | booleans' "$release_path")
prerelease=$(jq -er '.prerelease | booleans' "$release_path")
immutable=$(jq -er '.immutable // false | booleans' "$release_path")
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

"$central_root/scripts/workflow/extract-archive.sh" "$assets_archive" "$extracted_assets"
assets_directory=$extracted_assets
if [[ -n "$(find "$assets_directory" -mindepth 1 -maxdepth 1 \( ! -type f -o -type l \) -print -quit)" ]]; then
  printf '%s\n' 'publish assetにregular file以外が含まれています' >&2
  exit 1
fi

if ! fetch_remote_assets; then
  exit 1
fi
(cd "$central_root" && pnpm exec tsx src/cli.ts plan-publish \
  --contract "$contract_path" --manifest "$manifest_path" \
  --remote-assets "$remote_assets_path" --assets-directory "$assets_directory" --output "$plan_path")

if [[ "$immutable" == true ]] && jq -e '.operations | any(.[]; .action != "skip")' "$plan_path" >/dev/null; then
  printf '%s\n' 'immutable Releaseへ変更が必要な公開計画は適用できません' >&2
  exit 1
fi
jq -e --arg repository "$repository" --arg tag "$tag" \
  '.schemaVersion == 1 and .repository == $repository and .tag == $tag and .publishOrder == ["payload", "metadata"]' \
  "$plan_path" >/dev/null

publish_operation() {
  local operation_json=$1
  local action
  local name
  local digest
  local size
  local role
  local asset_path
  local asset_id
  action=$(jq -er '.action' <<<"$operation_json")
  name=$(jq -er '.name' <<<"$operation_json")
  digest=$(jq -er '.digest' <<<"$operation_json" | tr '[:upper:]' '[:lower:]')
  size=$(jq -er '.size' <<<"$operation_json")
  role=$(jq -er '.role' <<<"$operation_json")
  if [[ "$name" == */* || "$name" == *..* || "$name" == *$'\\n'* || "$name" == *$'\\r'* ]]; then
    printf 'asset filenameが不正です: %s\n' "$name" >&2
    return 1
  fi
  asset_path="$assets_directory/$name"
  if [[ "$action" != skip && ( ! -f "$asset_path" || -L "$asset_path" ) ]]; then
    printf 'publish assetがありません: %s\n' "$name" >&2
    return 1
  fi
  case "$action" in
    skip)
      ;;
    upload)
      upload_asset "$name" "$digest" "$size" "$asset_path"
      ;;
    replace|update-metadata)
      asset_id=$(remote_asset_id "$name")
      if [[ -z "$asset_id" ]]; then
        printf '置換対象のremote assetがありません: %s\n' "$name" >&2
        return 1
      fi
      delete_asset "$asset_id" "$name"
      upload_asset "$name" "$digest" "$size" "$asset_path"
      ;;
    *)
      printf 'publish planのactionが不正です: %s\n' "$action" >&2
      return 1
      ;;
  esac
  printf '公開処理: %s %s\n' "$role" "$name"
  fetch_remote_assets
}

for phase in payload metadata; do
  while IFS= read -r operation_json; do
    publish_operation "$operation_json"
  done < <(jq -c --arg phase "$phase" \
    '.operations[] | select((($phase == "metadata") and (.role == "macos-metadata" or .role == "windows-metadata")) or (($phase == "payload") and (.role != "macos-metadata" and .role != "windows-metadata")))' \
    "$plan_path")
done

fetch_remote_assets
while IFS=$'\t' read -r asset_name asset_size asset_digest; do
  if [[ -z "$asset_name" || -z "$asset_digest" ]]; then
    printf '%s\n' 'manifest assetの再検証入力が空です' >&2
    exit 1
  fi
  if ! jq -e --arg name "$asset_name" --arg digest "$asset_digest" --argjson size "$asset_size" \
    'any(.[]; .name == $name and .size == $size and (.digest | ascii_downcase) == $digest)' "$remote_assets_path" >/dev/null; then
    printf '公開後のasset digest検証に失敗しました: %s\n' "$asset_name" >&2
    exit 1
  fi
done < <(jq -r '.assets[] | [.name, (.size | tostring), (.digest | ascii_downcase)] | @tsv' "$manifest_path")

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
