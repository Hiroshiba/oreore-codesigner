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

jq -e '
  (.draft | type == "boolean") and
  (.prerelease | type == "boolean") and
  ((.immutable // false) | type == "boolean")
' "$release_path" >/dev/null
jq -c '{draft: (.draft | tostring), prerelease: (.prerelease | tostring), immutable: ((.immutable // false) | tostring)}' "$release_path"
