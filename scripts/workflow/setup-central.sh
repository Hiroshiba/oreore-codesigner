#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 0 ]]; then
  printf '%s\n' '使い方: setup-central.sh' >&2
  exit 2
fi

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
central_root=$(cd -- "$script_directory/../.." && pwd -P)
package_json="$central_root/package.json"
if [[ ! -f "$package_json" || -L "$package_json" ]]; then
  printf '%s\n' '中央package.jsonが通常fileではありません' >&2
  exit 1
fi
if ! package_manager=$(jq -er '.packageManager' "$package_json"); then
  printf '%s\n' '中央package.jsonのpackageManagerを取得できません' >&2
  exit 1
fi
if [[ ! "$package_manager" =~ ^pnpm@(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(\+[A-Za-z0-9._-]+)?$ ]]; then
  printf '%s\n' '中央package.jsonのpackageManagerがCorepackのexact specではありません' >&2
  exit 1
fi

cd -- "$central_root"
corepack enable
corepack prepare "$package_manager" --activate
pnpm install --frozen-lockfile
