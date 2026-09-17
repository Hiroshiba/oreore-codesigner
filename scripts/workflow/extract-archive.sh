#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 3 ]]; then
  printf '%s\n' '使い方: extract-archive.sh archive.tar output-directory linux|macos|windows' >&2
  exit 2
fi

archive_path=$1
output_directory=$2
platform=$3
case "$platform" in
  linux|macos|windows) ;;
  *)
    printf 'platformが不正です: %s\n' "$platform" >&2
    exit 1
    ;;
esac
if [[ ! -f "$archive_path" || -L "$archive_path" ]]; then
  printf '%s\n' 'archiveが通常fileではありません' >&2
  exit 1
fi
if [[ -e "$output_directory" || -L "$output_directory" ]]; then
  printf '%s\n' 'archiveの展開先は存在してはいけません' >&2
  exit 1
fi

python_path=$(command -v python3 || true)
if [[ -z "$python_path" ]]; then
  printf '%s\n' 'python3が見つかりません' >&2
  exit 1
fi
python_version=$("$python_path" --version 2>&1)
if [[ ! "$python_version" =~ ^Python\ 3\.(9|[1-9][0-9])\.[0-9]+$ ]]; then
  printf 'Python 3.9以上が必要です: %s\n' "$python_version" >&2
  exit 1
fi

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
exec "$python_path" "$script_directory/safe-extract.py" \
  --archive "$archive_path" --output "$output_directory" --platform "$platform"
