#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 6 ]]; then
  printf '%s\n' '使い方: publish-release.sh repository tag source-sha expected-version mac-release-directory windows-release-directory' >&2
  exit 2
fi

repository=$1
tag=$2
source_sha=$3
expected_version=$4
mac_release_directory=$5
windows_release_directory=$6

if [[ ! "$repository" =~ ^[A-Za-z0-9]([A-Za-z0-9_.-]*[A-Za-z0-9])?/[A-Za-z0-9]([A-Za-z0-9_.-]*[A-Za-z0-9])?$ ]]; then
  printf '%s\n' 'repositoryはowner/name形式で指定してください' >&2
  exit 1
fi

if [[ -z "$tag" || "$tag" == '@' || "$tag" == /* || "$tag" == */ || "$tag" == *'//'* || "$tag" == *'..'* || "$tag" == *'@{'* || "$tag" == *'~'* || "$tag" == *'^'* || "$tag" == *':'* || "$tag" == *'?'* || "$tag" == *'*'* || "$tag" == *'['* || "$tag" =~ \\ || "$tag" == *'.' || "$tag" =~ [[:cntrl:]] ]]; then
  printf '%s\n' 'tagはGit refとして不正です' >&2
  exit 1
fi
IFS='/' read -r -a tag_segments <<<"$tag"
for tag_segment in "${tag_segments[@]}"; do
  if [[ -z "$tag_segment" || "$tag_segment" == '.' || "$tag_segment" == '..' || "$tag_segment" == '@' || "$tag_segment" == .* || "$tag_segment" == *.lock ]]; then
    printf '%s\n' 'tagはGit refとして不正です' >&2
    exit 1
  fi
done

if [[ ! "$source_sha" =~ ^[0-9A-Fa-f]{40}$ ]]; then
  printf '%s\n' 'source SHAは40桁の16進数で指定してください' >&2
  exit 1
fi

if [[ ! "$expected_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[A-Za-z-][0-9A-Za-z-]*))*))?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$ ]]; then
  printf '%s\n' 'expected-versionはSemVer形式で指定してください' >&2
  exit 1
fi

if [[ -z "${GH_TOKEN:-}" ]]; then
  printf '%s\n' 'GH_TOKENが必要です' >&2
  exit 1
fi

validate_release_directory() {
  local release_directory=$1
  local section
  local current_path=$release_directory
  local parent_path
  while [[ "$current_path" != '/' && "$current_path" != '.' && -n "$current_path" ]]; do
    if [[ -L "$current_path" ]]; then
      printf 'release directoryのpathにsymlinkを指定できません: %s\n' "$release_directory" >&2
      return 1
    fi
    parent_path=${current_path%/*}
    if [[ "$parent_path" == "$current_path" ]]; then
      parent_path=.
    fi
    current_path=$parent_path
  done
  if [[ ! -d "$release_directory" || -L "$release_directory" ]]; then
    printf 'release directoryが通常directoryではありません: %s\n' "$release_directory" >&2
    return 1
  fi
  for section in payload metadata; do
    if [[ ! -d "$release_directory/$section" || -L "$release_directory/$section" ]]; then
      printf 'release directoryの%sが通常directoryではありません: %s\n' "$section" "$release_directory" >&2
      return 1
    fi
  done
}

validate_release_directory "$mac_release_directory"
validate_release_directory "$windows_release_directory"

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
central_directory=$(cd -- "$script_directory/../.." && pwd -P)

umask 077
work_directory=$(mktemp -d "${TMPDIR:-/tmp}/publish-release.XXXXXX")
cleanup() {
  local status=$?
  if ! rm -rf -- "$work_directory"; then
    printf '%s\n' '一時directoryの削除に失敗しました' >&2
    if (( status == 0 )); then
      status=1
    fi
  fi
  exit "$status"
}
trap cleanup EXIT

combined_directory="$work_directory/assets"
mkdir -- "$combined_directory"
declare -a payload_names=()
declare -a metadata_names=()
declare -A asset_name_keys=()

collect_assets() {
  local release_directory=$1
  local section=$2
  local label=$3
  local listing_path="$work_directory/$label-$section.list"
  local asset_path
  local asset_name
  local asset_key
  local destination_path

  if ! find "$release_directory/$section" -mindepth 1 -maxdepth 1 -print0 >"$listing_path"; then
    printf 'asset一覧を取得できません: %s/%s\n' "$label" "$section" >&2
    return 1
  fi
  while IFS= read -r -d '' asset_path; do
    asset_name=${asset_path##*/}
    if [[ ! -f "$asset_path" || -L "$asset_path" || -z "$asset_name" || "$asset_name" == '.' || "$asset_name" == '..' || "$asset_name" == */* || "$asset_name" =~ \\ || "$asset_name" =~ [[:cntrl:]] ]]; then
      printf 'assetはbasenameのregular fileでなければなりません: %s\n' "$asset_path" >&2
      return 1
    fi
    asset_key=${asset_name,,}
    if [[ -n "${asset_name_keys[$asset_key]+present}" ]]; then
      printf 'asset basenameが大文字小文字を無視して重複しています: %s\n' "$asset_name" >&2
      return 1
    fi
    asset_name_keys["$asset_key"]=$asset_name
    destination_path="$combined_directory/$asset_name"
    if [[ -e "$destination_path" || -L "$destination_path" ]]; then
      printf 'combined assetが既に存在します: %s\n' "$asset_name" >&2
      return 1
    fi
    if ! cp -- "$asset_path" "$destination_path"; then
      printf 'assetの集約に失敗しました: %s\n' "$asset_path" >&2
      return 1
    fi
    if [[ "$section" == payload ]]; then
      payload_names+=("$asset_name")
    else
      metadata_names+=("$asset_name")
    fi
  done <"$listing_path"
}

collect_assets "$mac_release_directory" payload mac
collect_assets "$mac_release_directory" metadata mac
collect_assets "$windows_release_directory" payload windows
collect_assets "$windows_release_directory" metadata windows

if ! (cd "$central_directory" && pnpm cli validate-release-assets --assets-directory "$combined_directory" --expected-version "$expected_version"); then
  printf '%s\n' 'release assetの検証に失敗しました' >&2
  exit 1
fi

encoded_tag=$(jq -nr --arg value "$tag" '$value | @uri')
resolved_sha=''
if ! resolved_sha=$(gh api "repos/$repository/commits/$encoded_tag" --jq '.sha'); then
  printf '%s\n' 'tagのcommit SHAを取得できませんでした' >&2
  exit 1
fi
if [[ ! "$resolved_sha" =~ ^[0-9A-Fa-f]{40}$ ]]; then
  printf '%s\n' 'tagのcommit SHAが40桁ではありません' >&2
  exit 1
fi
if [[ "${resolved_sha,,}" != "${source_sha,,}" ]]; then
  printf '%s\n' 'tagのcommit SHAがsource SHAと一致しません' >&2
  exit 1
fi

release_state_path="$work_directory/release-state.json"
if ! gh api "repos/$repository/releases/tags/$encoded_tag" --jq '{tag_name, immutable}' >"$release_state_path"; then
  printf '%s\n' '対象Releaseを取得できませんでした' >&2
  exit 1
fi
if ! jq -e --arg tag "$tag" '.tag_name == $tag and .immutable == false' "$release_state_path" >/dev/null; then
  printf '%s\n' '対象Releaseのtagまたはimmutable状態が不正です' >&2
  exit 1
fi

upload_assets() {
  local section=$1
  local list_path="$work_directory/$section-upload.list"
  local asset_name
  : >"$list_path"
  if [[ "$section" == payload ]]; then
    for asset_name in "${payload_names[@]}"; do
      printf '%s\n' "$asset_name" >>"$list_path"
    done
  else
    for asset_name in "${metadata_names[@]}"; do
      printf '%s\n' "$asset_name" >>"$list_path"
    done
  fi
  if ! LC_ALL=C sort -o "$list_path" "$list_path"; then
    printf 'asset filenameの並べ替えに失敗しました: %s\n' "$section" >&2
    return 1
  fi
  while IFS= read -r asset_name; do
    [[ -n "$asset_name" ]] || continue
    if ! gh release upload "$tag" "$combined_directory/$asset_name" --repo "$repository" --clobber; then
      printf 'assetの公開に失敗しました: %s\n' "$asset_name" >&2
      return 1
    fi
  done <"$list_path"
}

upload_assets payload
upload_assets metadata
