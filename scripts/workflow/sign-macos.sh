#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 7 ]]; then
  printf '%s\n' '使い方: sign-macos.sh source-directory repository tag release-output-directory expected-version channel builder-config' >&2
  exit 2
fi

source_directory=$1
repository=$2
tag=$3
release_output_directory=$4
expected_version=$5
channel=$6
builder_config=$7

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
if [[ -z "$expected_version" || ! "$channel" =~ ^[0-9A-Za-z-]+$ ]]; then
  printf '%s\n' 'expected versionまたはchannelが不正です' >&2
  exit 1
fi
if [[ "$builder_config" != electron-builder.yml && "$builder_config" != electron-builder.yaml ]]; then
  printf '%s\n' 'builder configはelectron-builder.ymlまたはelectron-builder.yamlでなければなりません' >&2
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
package_manager=$(jq -er '.packageManager | select(type == "string")' "$package_json")
if [[ ! "$package_manager" =~ ^pnpm@(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(\+[A-Za-z0-9._-]+)?$ ]]; then
  printf '%s\n' 'source packageManagerが不正です' >&2
  exit 1
fi

umask 077
work_directory=$(mktemp -d "${RUNNER_TEMP:-/tmp}/central-package-macos.XXXXXX")
cleanup() {
  local status=$?
  local cleanup_status=0
  trap - EXIT
  unset CSC_LINK CSC_KEY_PASSWORD
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
    --config "$source_directory/$builder_config" \
    --mac zip \
    --x64 \
    --publish never \
    "--config.directories.output=$builder_output" \
    --config.forceCodeSigning=true \
    --config.mac.forceCodeSigning=true \
    --config.detectUpdateChannel=false \
    --config.mac.detectUpdateChannel=false \
    --config.generateUpdatesFilesForAllChannels=false \
    --config.mac.generateUpdatesFilesForAllChannels=false \
    --config.publish.provider=generic \
    "--config.publish.url=$publish_url" \
    "--config.publish.channel=$channel" \
    "--config.extraMetadata.version=$expected_version"
)

packaged_output=$(
  cd -- "$central_root"
  pnpm exec tsx src/cli.ts validate-packaged-output \
    --output-directory "$builder_output" \
    --platform macos \
    --channel "$channel" \
    --expected-version "$expected_version"
)
metadata_name=$(jq -er '.metadata | select(type == "string")' <<<"$packaged_output")
artifact_relative_path=$(jq -er '.artifact | select(type == "string")' <<<"$packaged_output")
blockmap_relative_path=$(jq -er '.blockmap | select(type == "string")' <<<"$packaged_output")
metadata_path="$builder_output/$metadata_name"
artifact_path="$builder_output/$artifact_relative_path"
blockmap_path="$builder_output/$blockmap_relative_path"
payload_directory="$release_output_directory/payload"
metadata_directory="$release_output_directory/metadata"
mkdir -p -- "$payload_directory" "$metadata_directory"
cp -- "$artifact_path" "$payload_directory/$(basename -- "$artifact_relative_path")"
cp -- "$blockmap_path" "$payload_directory/$(basename -- "$blockmap_relative_path")"
cp -- "$metadata_path" "$metadata_directory/$(basename -- "$metadata_name")"
