#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 8 ]]; then
  printf '%s\n' '使い方: build-source.sh platform source-root working-directory build-script pnpm-version source-sha source-tag archive-path' >&2
  exit 2
fi

platform=$1
source_root=$2
working_directory=$3
build_script=$4
pnpm_version=$5
source_sha=$6
source_tag=$7
archive_path=$8
prepackaged_directory=${CENTRAL_PREPACKAGED_DIR:?CENTRAL_PREPACKAGED_DIRが必要です}
architecture=${CENTRAL_BUILD_ARCH:?CENTRAL_BUILD_ARCHが必要です}
source_date_epoch=${SOURCE_DATE_EPOCH:?SOURCE_DATE_EPOCHが必要です}

if [[ "$platform" != macos && "$platform" != windows ]]; then
  printf 'platformが不正です: %s\n' "$platform" >&2
  exit 1
fi
if [[ ! "$architecture" =~ ^(x64|arm64)$ ]]; then
  printf 'architectureが不正です: %s\n' "$architecture" >&2
  exit 1
fi
if [[ ! "$working_directory" =~ ^\.?([A-Za-z0-9._-]+/)*[A-Za-z0-9._-]+$|^\.$ ]]; then
  printf 'working directoryが不正です: %s\n' "$working_directory" >&2
  exit 1
fi
if [[ ! "$build_script" =~ ^[A-Za-z0-9:_-]+$ ]]; then
  printf 'build script名が不正です: %s\n' "$build_script" >&2
  exit 1
fi
if [[ ! "$pnpm_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  printf 'pnpm versionが不正です: %s\n' "$pnpm_version" >&2
  exit 1
fi
if [[ ! "$source_sha" =~ ^[0-9a-fA-F]{40}$ ]]; then
  printf '%s\n' 'source SHAが40桁ではありません' >&2
  exit 1
fi
if [[ ! "$source_date_epoch" =~ ^[0-9]+$ ]]; then
  printf '%s\n' 'SOURCE_DATE_EPOCHが整数ではありません' >&2
  exit 1
fi
if [[ ! -d "$source_root" || -L "$source_root" ]]; then
  printf '%s\n' 'source rootが不正です' >&2
  exit 1
fi

if [[ -e "$prepackaged_directory" || -L "$prepackaged_directory" ]]; then
  if [[ ! -d "$prepackaged_directory" || -n "$(find "$prepackaged_directory" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    printf '%s\n' 'prepackaged outputは事前に空のディレクトリでなければなりません' >&2
    exit 1
  fi
else
  mkdir -p -- "$prepackaged_directory"
fi

corepack enable
corepack prepare "pnpm@${pnpm_version}" --activate
actual_pnpm_version=$(pnpm --version)
if [[ "$actual_pnpm_version" != "$pnpm_version" ]]; then
  printf 'source pnpm versionが一致しません: %s\n' "$actual_pnpm_version" >&2
  exit 1
fi
(cd "$source_root" && pnpm install --frozen-lockfile)

working_path=$source_root
if [[ "$working_directory" != . ]]; then
  working_path="$source_root/$working_directory"
fi
if [[ ! -d "$working_path" || -L "$working_path" ]]; then
  printf 'working directoryが不正です: %s\n' "$working_path" >&2
  exit 1
fi

export CENTRAL_BUILD_PLATFORM="$platform"
export CENTRAL_BUILD_ARCH="$architecture"
export CENTRAL_PREPACKAGED_DIR="$prepackaged_directory"
export CENTRAL_SOURCE_SHA="$source_sha"
export CENTRAL_SOURCE_TAG="$source_tag"
export SOURCE_DATE_EPOCH="$source_date_epoch"
(cd "$working_path" && pnpm run "$build_script")

entries=()
while IFS= read -r -d '' entry; do
  entries+=("$entry")
done < <(find "$prepackaged_directory" -mindepth 1 -maxdepth 1 -print0)
if (( ${#entries[@]} != 1 )); then
  printf '%s\n' 'prepackaged outputは直下一件でなければなりません' >&2
  exit 1
fi
entry=${entries[0]}
if [[ ! -d "$entry" || -L "$entry" ]]; then
  printf '%s\n' 'prepackaged outputの直下はsymlinkでないディレクトリでなければなりません' >&2
  exit 1
fi
if [[ "$platform" == macos && "$entry" != *.app ]]; then
  printf 'macOS prepackaged outputは.appでなければなりません: %s\n' "$entry" >&2
  exit 1
fi

mkdir -p -- "$(dirname -- "$archive_path")"
tar -cf "$archive_path" -C "$prepackaged_directory" "$(basename -- "$entry")"
if [[ ! -s "$archive_path" ]]; then
  printf '%s\n' 'prepackaged archiveが空です' >&2
  exit 1
fi
