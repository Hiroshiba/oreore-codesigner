#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 6 ]]; then
  printf '%s\n' '使い方: build-source.sh source.tar source-sha commit-timestamp unsigned-app.tar package-input-directory github-output-path' >&2
  exit 2
fi

source_archive=$1
source_sha=$2
commit_timestamp=$3
unsigned_archive=$4
package_input_directory=$5
github_output_path=$6

if [[ ! -f "$source_archive" || -L "$source_archive" ]]; then
  printf '%s\n' 'source archiveが通常fileではありません' >&2
  exit 1
fi
if [[ ! "$source_sha" =~ ^[0-9a-fA-F]{40}$ ]]; then
  printf '%s\n' 'source SHAが40桁ではありません' >&2
  exit 1
fi
if [[ ! "$commit_timestamp" =~ ^[0-9]+$ ]]; then
  printf '%s\n' 'commit timestampが整数ではありません' >&2
  exit 1
fi
if [[ -z "$unsigned_archive" || -z "$package_input_directory" || -z "$github_output_path" ]]; then
  printf '%s\n' '出力pathを空にできません' >&2
  exit 1
fi
if [[ -e "$unsigned_archive" || -L "$unsigned_archive" ]]; then
  printf '%s\n' 'unsigned app archiveは開始時に存在してはいけません' >&2
  exit 1
fi
if [[ -e "$package_input_directory" || -L "$package_input_directory" ]]; then
  printf '%s\n' 'package-input directoryは開始時に存在してはいけません' >&2
  exit 1
fi

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
central_root=$(cd -- "$script_directory/../.." && pwd -P)
safe_extractor="$script_directory/safe-extract.py"
if [[ ! -f "$safe_extractor" || -L "$safe_extractor" ]]; then
  printf '%s\n' 'safe-extract.pyが通常fileではありません' >&2
  exit 1
fi
if ! python_path=$(command -v python3); then
  printf '%s\n' 'python3が見つかりません' >&2
  exit 1
fi
if ! archive_sha=$(git get-tar-commit-id <"$source_archive"); then
  printf '%s\n' 'source archiveのcommit SHAを確認できません' >&2
  exit 1
fi
archive_sha=${archive_sha,,}
if [[ "$archive_sha" != "${source_sha,,}" ]]; then
  printf '%s\n' 'source archiveのcommit SHAが一致しません' >&2
  exit 1
fi

work_directory=$(mktemp -d "${RUNNER_TEMP:-/tmp}/central-build-source.XXXXXX")
cleanup() {
  local status=$?
  local cleanup_status=0
  trap - EXIT
  if ! rm -rf -- "$work_directory"; then
    printf '%s\n' 'source build用一時directoryの削除に失敗しました' >&2
    cleanup_status=1
  fi
  if (( status != 0 )); then
    if (( cleanup_status != 0 )); then
      exit 1
    fi
    exit "$status"
  fi
  exit "$cleanup_status"
}
trap cleanup EXIT

source_parent="$work_directory/source-parent"
if ! "$python_path" "$safe_extractor" --archive "$source_archive" --output "$source_parent" --platform macos; then
  printf '%s\n' 'source archiveの安全な展開に失敗しました' >&2
  exit 1
fi
root_entries=()
while IFS= read -r -d '' entry; do
  root_entries+=("$entry")
done < <(find "$source_parent" -mindepth 1 -maxdepth 1 -print0)
if (( ${#root_entries[@]} != 1 )); then
  printf '%s\n' 'source archiveのrootは一件でなければなりません' >&2
  exit 1
fi
source_root=${root_entries[0]}
if [[ "$(basename -- "$source_root")" != source || ! -d "$source_root" || -L "$source_root" ]]; then
  printf '%s\n' 'source archiveのrootはsource directory一件でなければなりません' >&2
  exit 1
fi

package_json="$source_root/package.json"
lockfile="$source_root/pnpm-lock.yaml"
for required_path in "$package_json" "$lockfile"; do
  if [[ ! -f "$required_path" || -L "$required_path" ]]; then
    printf 'source rootの必須fileがありません: %s\n' "$(basename -- "$required_path")" >&2
    exit 1
  fi
done
builder_paths=()
for builder_name in electron-builder.yml electron-builder.yaml; do
  builder_path="$source_root/$builder_name"
  if [[ -e "$builder_path" || -L "$builder_path" ]]; then
    if [[ ! -f "$builder_path" || -L "$builder_path" ]]; then
      printf 'electron-builder設定が通常fileではありません: %s\n' "$builder_name" >&2
      exit 1
    fi
    builder_paths+=("$builder_path")
  fi
done
if (( ${#builder_paths[@]} != 1 )); then
  printf '%s\n' 'source rootのelectron-builder設定は一件でなければなりません' >&2
  exit 1
fi
builder_config=${builder_paths[0]}

if ! package_manager=$(jq -er '.packageManager' "$package_json"); then
  printf '%s\n' 'source rootのpackageManagerを取得できません' >&2
  exit 1
fi
if [[ ! "$package_manager" =~ ^pnpm@(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(\+[A-Za-z0-9._-]+)?$ ]]; then
  printf '%s\n' 'source rootのpackageManagerがCorepackのexact specではありません' >&2
  exit 1
fi

export SOURCE_DATE_EPOCH="$commit_timestamp"
corepack enable
corepack prepare "$package_manager" --activate
(
  cd -- "$source_root"
  pnpm install --frozen-lockfile
  pnpm run build
)

builder_output="$work_directory/builder-output"
mkdir -p -- "$builder_output"
(
  cd -- "$source_root"
  pnpm exec electron-builder --dir --mac --x64 --publish never --config "$builder_config" "--config.directories.output=$builder_output"
)

app_entries=()
while IFS= read -r -d '' entry; do
  app_entries+=("$entry")
done < <(find "$builder_output" -type d -name '*.app' -print0 -prune)
if (( ${#app_entries[@]} != 1 )); then
  printf '%s\n' 'source builderの.appは一件でなければなりません' >&2
  exit 1
fi
app_path=${app_entries[0]}
if [[ -L "$app_path" ]]; then
  printf '%s\n' 'source builderの.appがsymlinkです' >&2
  exit 1
fi
prepackaged_directory=$(dirname -- "$app_path")
prepackaged_entries=()
while IFS= read -r -d '' entry; do
  prepackaged_entries+=("$entry")
done < <(find "$prepackaged_directory" -mindepth 1 -maxdepth 1 -print0)
if (( ${#prepackaged_entries[@]} != 1 )) || [[ "${prepackaged_entries[0]}" != "$app_path" ]]; then
  printf '%s\n' 'macOS prepackaged directoryは.app一件でなければなりません' >&2
  exit 1
fi
if [[ -L "$prepackaged_directory" || ! -d "$prepackaged_directory" ]]; then
  printf '%s\n' 'macOS prepackaged directoryが通常directoryではありません' >&2
  exit 1
fi

mkdir -p -- "$(dirname -- "$package_input_directory")"
(
  cd -- "$central_root"
  pnpm cli create-package-input \
    --source-directory "$source_root" \
    --prepackaged-directory "$prepackaged_directory" \
    --platform macos \
    --output-directory "$package_input_directory"
)
package_input_path="$package_input_directory/package-input.json"
if [[ ! -f "$package_input_path" || -L "$package_input_path" ]]; then
  printf '%s\n' 'package-input.jsonが生成されませんでした' >&2
  exit 1
fi
if ! version=$(jq -er '.version' "$package_input_path"); then
  printf '%s\n' 'package-input.jsonのversionを取得できません' >&2
  exit 1
fi
if [[ -L "$github_output_path" ]]; then
  printf '%s\n' 'GitHub output pathにsymlinkを指定できません' >&2
  exit 1
fi
mkdir -p -- "$(dirname -- "$github_output_path")"
printf 'version=%s\n' "$version" >>"$github_output_path"

mkdir -p -- "$(dirname -- "$unsigned_archive")"
if ! tar -cf "$unsigned_archive" -C "$prepackaged_directory" "$(basename -- "$app_path")"; then
  printf '%s\n' 'unsigned app archiveの生成に失敗しました' >&2
  exit 1
fi
if [[ ! -f "$unsigned_archive" || -L "$unsigned_archive" || ! -s "$unsigned_archive" ]]; then
  printf '%s\n' 'unsigned app archiveが通常fileではありません' >&2
  exit 1
fi
