#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 2 ]]; then
  printf '%s\n' '使い方: extract-archive.sh archive.tar output-directory' >&2
  exit 2
fi

archive_path=$1
output_directory=$2
if [[ ! -f "$archive_path" || -L "$archive_path" ]]; then
  printf '%s\n' 'archiveが通常ファイルではありません' >&2
  exit 1
fi
if [[ -e "$output_directory" || -L "$output_directory" ]]; then
  printf '%s\n' 'archiveの展開先は存在してはいけません' >&2
  exit 1
fi
mkdir -p -- "$output_directory"

listing=$(mktemp "${RUNNER_TEMP:-/tmp}/central-archive-list.XXXXXX")
cleanup() {
  local status=$?
  local cleanup_status=0
  if ! rm -f -- "$listing"; then
    printf '%s\n' 'archive一覧の削除に失敗しました' >&2
    cleanup_status=1
  fi
  if (( status != 0 )); then
    exit "$status"
  fi
  exit "$cleanup_status"
}
trap cleanup EXIT

tar -tf "$archive_path" >"$listing"
while IFS= read -r entry; do
  if [[ "$entry" == /* || "$entry" == *$'\n'* || "$entry" == *$'\r'* ]]; then
    printf 'archive pathが不正です: %s\n' "$entry" >&2
    exit 1
  fi
  entry=${entry%/}
  if [[ -z "$entry" || "$entry" == .. || "$entry" == ../* || "$entry" == */../* || "$entry" == */.. ]]; then
    printf 'archive pathが不正です: %s\n' "$entry" >&2
    exit 1
  fi
done <"$listing"

tar -xf "$archive_path" -C "$output_directory"
