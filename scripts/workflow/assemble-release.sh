#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 9 ]]; then
  printf '%s\n' '使い方: assemble-release.sh central-root mac-contract windows-contract mac-source-manifest windows-source-manifest mac-assets.tar windows-assets.tar output-directory run-url' >&2
  exit 2
fi

central_root=$1
mac_contract=$2
windows_contract=$3
mac_source_manifest=$4
windows_source_manifest=$5
mac_assets_archive=$6
windows_assets_archive=$7
output_directory=$8
run_url=$9

for input_path in "$mac_contract" "$windows_contract" "$mac_source_manifest" "$windows_source_manifest" "$mac_assets_archive" "$windows_assets_archive"; do
  if [[ ! -f "$input_path" || -L "$input_path" ]]; then
    printf '入力pathが通常fileではありません: %s\n' "$input_path" >&2
    exit 1
  fi
done
if [[ ! "$run_url" =~ ^https:// ]]; then
  printf '%s\n' 'run URLがHTTPSではありません' >&2
  exit 1
fi
if [[ -e "$output_directory" || -L "$output_directory" ]]; then
  if [[ ! -d "$output_directory" || -n "$(find "$output_directory" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    printf '%s\n' 'release outputは空のdirectoryでなければなりません' >&2
    exit 1
  fi
else
  mkdir -p -- "$output_directory"
fi

if [[ "$(jq -S -c . "$mac_contract")" != "$(jq -S -c . "$windows_contract")" ]]; then
  printf '%s\n' 'macOSとWindowsのrelease contractが一致しません' >&2
  exit 1
fi
if [[ "$(jq -S -c . "$mac_source_manifest")" != "$(jq -S -c . "$windows_source_manifest")" ]]; then
  printf '%s\n' 'macOSとWindowsのsource manifestが一致しません' >&2
  exit 1
fi

contract_path="$output_directory/release-contract.json"
source_manifest_path="$output_directory/source-manifest.json"
cp -- "$mac_contract" "$contract_path"
cp -- "$mac_source_manifest" "$source_manifest_path"
source_sha=$(jq -er '.sourceSha' "$source_manifest_path")
version=$(jq -er '.version' "$contract_path")
repository=$(jq -er '.repository' "$contract_path")
tag=$(jq -er '.tag' "$contract_path")
app_id=$(jq -er '.appId' "$contract_path")
config_digest=$(jq -er '.configDigest' "$contract_path")
if ! jq -e --arg app_id "$app_id" --arg repository "$repository" --arg tag "$tag" \
  --arg config_digest "$config_digest" \
  '.schemaVersion == 1 and .appId == $app_id and .repository == $repository and .tag == $tag and
   (.sourceSha | type == "string" and test("^[0-9a-fA-F]{40}$")) and
   (.commitTimestamp | type == "number" and floor == .) and .configDigest == $config_digest' \
  "$source_manifest_path" >/dev/null; then
  printf '%s\n' 'source manifestがrelease contractと一致しません' >&2
  exit 1
fi

work_directory=$(mktemp -d "${RUNNER_TEMP:-/tmp}/central-assemble-release.XXXXXX")
cleanup() {
  local status=$?
  local cleanup_status=0
  if ! rm -rf -- "$work_directory"; then
    printf '%s\n' 'release assemble用一時directoryの削除に失敗しました' >&2
    cleanup_status=1
  fi
  if (( status != 0 )); then
    exit "$status"
  fi
  exit "$cleanup_status"
}
trap cleanup EXIT

mac_directory="$work_directory/macos"
windows_directory="$work_directory/windows"
"$central_root/scripts/workflow/extract-archive.sh" "$mac_assets_archive" "$mac_directory"
"$central_root/scripts/workflow/extract-archive.sh" "$windows_assets_archive" "$windows_directory"
assets_directory="$work_directory/assets"
mkdir -p -- "$assets_directory"
for extracted_directory in "$mac_directory" "$windows_directory"; do
  while IFS= read -r -d '' file_path; do
    file_name=$(basename -- "$file_path")
    if [[ -L "$file_path" || ! -f "$file_path" ]]; then
      printf 'release assetが通常fileではありません: %s\n' "$file_path" >&2
      exit 1
    fi
    if [[ -e "$assets_directory/$file_name" || -L "$assets_directory/$file_name" ]]; then
      printf 'release asset filenameが重複しています: %s\n' "$file_name" >&2
      exit 1
    fi
    cp -- "$file_path" "$assets_directory/$file_name"
  done < <(find "$extracted_directory" -mindepth 1 -maxdepth 1 -print0)
done

manifest_path="$output_directory/release-manifest.json"
(cd "$central_root" && pnpm exec tsx src/cli.ts create-release-manifest \
  --contract "$contract_path" --assets-directory "$assets_directory" --output "$manifest_path")

jq -n \
  --arg repository "$repository" \
  --arg tag "$tag" \
  --arg source_sha "$source_sha" \
  --arg version "$version" \
  --arg config_digest "$config_digest" \
  --arg run_url "$run_url" \
  '{schemaVersion: 1, repository: $repository, tag: $tag, sourceSha: $source_sha, version: $version, configDigest: $config_digest, runUrl: $run_url}' \
  >"$output_directory/build-manifest.json"

tar -cf "$output_directory/release-assets.tar" -C "$assets_directory" .
if [[ ! -s "$output_directory/release-assets.tar" ]]; then
  printf '%s\n' 'release assets archiveが空です' >&2
  exit 1
fi
