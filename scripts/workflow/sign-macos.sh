#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 4 ]]; then
  printf '%s\n' '使い方: sign-macos.sh source-directory repository tag release-output-directory' >&2
  exit 2
fi

source_directory=$1
repository=$2
tag=$3
release_output_directory=$4

if [[ ! -d "$source_directory" || -L "$source_directory" ]]; then
  printf '%s\n' 'source directoryが通常directoryではありません' >&2
  exit 1
fi
if [[ ! "$repository" =~ ^[A-Za-z0-9]([A-Za-z0-9_.-]*[A-Za-z0-9])?/[A-Za-z0-9]([A-Za-z0-9_.-]*[A-Za-z0-9])?$ ]]; then
  printf '%s\n' 'repositoryはowner/name形式でなければなりません' >&2
  exit 1
fi
if ! git check-ref-format "refs/tags/$tag" >/dev/null; then
  printf '%s\n' 'tagはGit refとして不正です' >&2
  exit 1
fi
if [[ -z "${CSC_LINK:-}" || -z "${CSC_KEY_PASSWORD:-}" ]]; then
  printf '%s\n' 'macOS署名用のCSC_LINKとCSC_KEY_PASSWORDが必要です' >&2
  exit 1
fi
if [[ -e "$release_output_directory" || -L "$release_output_directory" ]]; then
  shopt -s nullglob dotglob
  release_entries=("$release_output_directory"/*)
  shopt -u nullglob dotglob
  if [[ ! -d "$release_output_directory" || -L "$release_output_directory" ]] ||
    (( ${#release_entries[@]} != 0 )); then
    printf '%s\n' 'release outputは空のdirectoryでなければなりません' >&2
    exit 1
  fi
else
  mkdir -p -- "$release_output_directory"
fi

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
central_root=$(cd -- "$script_directory/../.." && pwd -P)
package_json="$source_directory/package.json"
if [[ ! -f "$package_json" || -L "$package_json" ]]; then
  printf '%s\n' 'source package.jsonが通常fileではありません' >&2
  exit 1
fi
package_manager=$(jq -er '.packageManager | select(type == "string" and length > 0)' "$package_json")

umask 077
work_directory=$(mktemp -d "${RUNNER_TEMP:-/tmp}/central-package-macos.XXXXXX")
cleanup() {
  local status=$?
  local cleanup_status=0
  trap - EXIT
  unset CSC_LINK CSC_KEY_PASSWORD CSC_NAME
  if ! rm -rf -- "$work_directory"; then
    printf '%s\n' 'macOS package用一時directoryの削除に失敗しました' >&2
    cleanup_status=1
  fi
  if (( status != 0 && cleanup_status != 0 )); then
    printf '%s\n' 'macOS packageの失敗とcleanupの失敗が発生しました' >&2
    exit 1
  fi
  if (( status != 0 )); then
    exit "$status"
  fi
  exit "$cleanup_status"
}
trap cleanup EXIT

macos_configured=$(jq -er '.macos.configured' "$central_root/config/signing.json")
if [[ "$macos_configured" == true ]]; then
  export CSC_NAME
  CSC_NAME=$(jq -er '.macos.displayName' "$central_root/config/signing.json")
else
  unset CSC_NAME
fi

corepack enable
corepack prepare "$package_manager" --activate
(
  cd -- "$source_directory"
  pnpm install --frozen-lockfile
  pnpm run build
)

encoded_tag=$(jq -nr --arg value "$tag" '$value | @uri')
publish_url="https://github.com/$repository/releases/download/$encoded_tag"
builder_output="$work_directory/dist"
mkdir -p -- "$builder_output"
(
  cd -- "$source_directory"
  pnpm exec electron-builder \
    --mac zip \
    --x64 \
    --publish never \
    "--config.directories.output=$builder_output" \
    --config.forceCodeSigning=true \
    --config.publish.provider=generic \
    "--config.publish.url=$publish_url"
)

shopt -s nullglob
zip_files=("$builder_output"/*.zip)
blockmap_files=("$builder_output"/*.blockmap)
shopt -u nullglob
metadata_entries=()
if [[ -f "$builder_output/latest-mac.yml" ]]; then
  metadata_entries=("$builder_output/latest-mac.yml")
fi
zip_entries=()
blockmap_entries=()
for zip_path in "${zip_files[@]}"; do
  if [[ -f "$zip_path.blockmap" ]]; then
    zip_entries+=("$zip_path")
  fi
done
for blockmap_path in "${blockmap_files[@]}"; do
  if [[ -f "${blockmap_path%.blockmap}" ]]; then
    blockmap_entries+=("$blockmap_path")
  fi
done
if (( ${#zip_entries[@]} != 1 || ${#blockmap_entries[@]} != 1 || ${#metadata_entries[@]} != 1 )); then
  printf '%s\n' 'macOS packageのZIP、blockmap、update metadataが揃っていません' >&2
  exit 1
fi

payload_directory="$release_output_directory/payload"
metadata_directory="$release_output_directory/metadata"
mkdir -p -- "$payload_directory" "$metadata_directory"
cp -- "${zip_entries[0]}" "$payload_directory/$(basename -- "${zip_entries[0]}")"
cp -- "${blockmap_entries[0]}" "$payload_directory/$(basename -- "${blockmap_entries[0]}")"
cp -- "${metadata_entries[0]}" "$metadata_directory/$(basename -- "${metadata_entries[0]}")"
