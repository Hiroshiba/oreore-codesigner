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

macos_configured=$(jq -r '.macos.configured | select(type == "boolean") | tostring' "$central_root/config/signing.json")
if [[ -z "$macos_configured" ]]; then
  printf '%s\n' 'macOS signing設定のconfiguredがbooleanではありません' >&2
  exit 1
fi
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
    --config.mac.forceCodeSigning=true \
    --config.generateUpdatesFilesForAllChannels=false \
    --config.mac.generateUpdatesFilesForAllChannels=false \
    --config.publish.provider=generic \
    "--config.publish.url=$publish_url" \
    --config.mac.publish.provider=generic \
    "--config.mac.publish.url=$publish_url" \
    --config.zip.publish.provider=generic \
    "--config.zip.publish.url=$publish_url"
)

is_update_metadata() {
  local metadata_path=$1
  [[ -f "$metadata_path" && ! -L "$metadata_path" ]] || return 1
  grep -Eq '^version:[[:space:]]+[^[:space:]]+$' "$metadata_path" || return 1
  grep -Eq '^files:[[:space:]]*$' "$metadata_path" || return 1
  grep -Eq '^path:[[:space:]]+[^[:space:]]+$' "$metadata_path" || return 1
  grep -Eq '^sha512:[[:space:]]+[A-Za-z0-9+/=]+$' "$metadata_path"
}

read_metadata_value() {
  local key=$1
  local metadata_path=$2
  local value
  value=$(sed -n "s/^$key:[[:space:]]*//p" "$metadata_path" | head -n 1)
  if [[ -z "$value" ]]; then
    printf 'metadataの%sがありません: %s\n' "$key" "$metadata_path" >&2
    return 1
  fi
  if [[ "$value" == \"*\" && "$value" == *\" ]]; then
    value=${value:1:${#value}-2}
  elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
    value=${value:1:${#value}-2}
  fi
  printf '%s' "$value"
}

find_artifact_by_name() {
  local artifact_name=$1
  local -a matches=()
  local candidate
  while IFS= read -r -d '' candidate; do
    if [[ -f "$candidate" && ! -L "$candidate" && "$(basename -- "$candidate")" == "$artifact_name" ]]; then
      matches+=("$candidate")
    fi
  done < <(find "$builder_output" -type f -print0)
  if (( ${#matches[@]} != 1 )); then
    printf 'metadataが参照するassetの一意な実fileがありません: %s\n' "$artifact_name" >&2
    return 1
  fi
  printf '%s' "${matches[0]}"
}

shopt -s nullglob
metadata_entries=()
for metadata_path in "$builder_output"/*-mac.yml; do
  if is_update_metadata "$metadata_path"; then
    metadata_entries+=("$metadata_path")
  fi
done
shopt -u nullglob
if (( ${#metadata_entries[@]} != 1 )); then
  printf '%s\n' 'macOS packageのZIP、blockmap、update metadataが揃っていません' >&2
  exit 1
fi
metadata_path=${metadata_entries[0]}
zip_name=$(read_metadata_value path "$metadata_path")
if [[ "$zip_name" == */* || "$zip_name" == *\\* || "$zip_name" == '.' || "$zip_name" == '..' ]]; then
  printf '%s\n' 'macOS metadataのpathはbasenameでなければなりません' >&2
  exit 1
fi
zip_path=$(find_artifact_by_name "$zip_name")
blockmap_path=$(find_artifact_by_name "$zip_name.blockmap")

payload_directory="$release_output_directory/payload"
metadata_directory="$release_output_directory/metadata"
mkdir -p -- "$payload_directory" "$metadata_directory"
cp -- "$zip_path" "$payload_directory/$zip_name"
cp -- "$blockmap_path" "$payload_directory/$zip_name.blockmap"
cp -- "$metadata_path" "$metadata_directory/$(basename -- "$metadata_path")"
