#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 1 ]]; then
  printf '%s\n' '使い方: read-release-state.sh release.json' >&2
  exit 2
fi

release_path=$1
if [[ ! -f "$release_path" || -L "$release_path" ]]; then
  printf '%s\n' 'Release JSONが通常fileではありません' >&2
  exit 1
fi

if ! jq -e '
  (.draft | type == "boolean") and
  (.prerelease | type == "boolean") and
  (has("immutable") and (.immutable | type == "boolean"))
' "$release_path" >/dev/null; then
  printf '%s\n' 'Release JSONの状態が不正です' >&2
  exit 1
fi
jq -c '{draft: (.draft | tostring), prerelease: (.prerelease | tostring), immutable: (.immutable | tostring)}' "$release_path"
