#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 1 ]]; then
  printf '%s\n' '使い方: setup-central.sh pnpm-version' >&2
  exit 2
fi

pnpm_version=$1
if [[ ! "$pnpm_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  printf '%s\n' '中央pnpm versionが不正です' >&2
  exit 1
fi

if [[ ! "$(node --version)" =~ ^v22\.[0-9]+\.[0-9]+$ ]]; then
  printf '%s\n' '中央Nodeは22.xでなければなりません' >&2
  exit 1
fi

corepack enable
corepack prepare "pnpm@${pnpm_version}" --activate
actual_version=$(pnpm --version)
if [[ "$actual_version" != "$pnpm_version" ]]; then
  printf '中央pnpm versionが一致しません: %s\n' "$actual_version" >&2
  exit 1
fi
pnpm install --frozen-lockfile
