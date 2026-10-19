#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 3 ]]; then
  printf '%s\n' '使い方: validate-macos-dmg.sh dmg-path zip-extraction-directory mount-directory' >&2
  exit 2
fi

dmg_path=$1
zip_extraction_directory=$2
mount_directory=$3

if [[ ! -f "$dmg_path" || -L "$dmg_path" ]]; then
  printf '%s\n' 'macOS DMGが通常fileではありません' >&2
  exit 1
fi
if [[ ! -d "$zip_extraction_directory" || -L "$zip_extraction_directory" ]]; then
  printf '%s\n' 'macOS ZIPの展開先が通常directoryではありません' >&2
  exit 1
fi
if [[ -e "$mount_directory" || -L "$mount_directory" ]]; then
  printf '%s\n' 'macOS DMGのマウント先は存在しないdirectoryを指定してください' >&2
  exit 1
fi

shopt -s nullglob
zip_apps=("$zip_extraction_directory"/*.app)
shopt -u nullglob
if (( ${#zip_apps[@]} != 1 )); then
  printf '%s\n' 'macOS ZIPの直下にappが一つ必要です' >&2
  exit 1
fi
zip_app=${zip_apps[0]}
if [[ ! -d "$zip_app" || -L "$zip_app" ]]; then
  printf '%s\n' 'macOS ZIP内のappが通常directoryではありません' >&2
  exit 1
fi

mkdir -- "$mount_directory"
mounted=false
cleanup() {
  local status=$?
  local cleanup_status=0
  local attempt
  local detached=false
  trap - EXIT
  if [[ "$mounted" == true ]]; then
    for attempt in 1 2 3; do
      if hdiutil detach "$mount_directory"; then
        detached=true
        break
      fi
      if (( attempt < 3 )); then
        sleep 1
      fi
    done
    if [[ "$detached" != true ]]; then
      printf '%s\n' 'macOS DMGの解除に失敗しました' >&2
      cleanup_status=1
    fi
  fi
  if [[ "$mounted" != true || "$detached" == true ]]; then
    if ! rmdir -- "$mount_directory"; then
      printf '%s\n' 'macOS DMGのマウント先を削除できません' >&2
      cleanup_status=1
    fi
  fi
  if (( status != 0 && cleanup_status != 0 )); then
    printf '%s\n' 'macOS DMGの検査とcleanupの両方に失敗しました' >&2
    exit 1
  fi
  if (( status != 0 )); then
    exit "$status"
  fi
  exit "$cleanup_status"
}
trap cleanup EXIT

hdiutil attach -readonly -nobrowse -mountpoint "$mount_directory" "$dmg_path"
mounted=true

shopt -s nullglob
dmg_apps=("$mount_directory"/*.app)
shopt -u nullglob
if (( ${#dmg_apps[@]} != 1 )); then
  printf '%s\n' 'macOS DMGの直下にappが一つ必要です' >&2
  exit 1
fi
dmg_app=${dmg_apps[0]}
if [[ ! -d "$dmg_app" || -L "$dmg_app" ]]; then
  printf '%s\n' 'macOS DMG内のappが通常directoryではありません' >&2
  exit 1
fi
if [[ ! -L "$mount_directory/Applications" ]] || [[ "$(readlink "$mount_directory/Applications")" != /Applications ]]; then
  printf '%s\n' 'macOS DMGの直下に/Applicationsへのリンクが必要です' >&2
  exit 1
fi

codesign --verify --strict "$zip_app"
codesign --verify --strict "$dmg_app"

get_cdhash() {
  local app_path=$1
  local signature_info
  local cdhash
  if ! signature_info=$(codesign -d --verbose=4 "$app_path" 2>&1); then
    printf '%s\n' "$signature_info" >&2
    return 1
  fi
  cdhash=$(sed -nE 's/^CDHash=([[:xdigit:]]+)$/\1/p' <<<"$signature_info")
  if [[ ! "$cdhash" =~ ^[[:xdigit:]]+$ ]]; then
    printf '%s\n' 'macOS appのCDHashを取得できません' >&2
    return 1
  fi
  printf '%s\n' "$cdhash"
}

zip_cdhash=$(get_cdhash "$zip_app")
dmg_cdhash=$(get_cdhash "$dmg_app")
if [[ "$zip_cdhash" != "$dmg_cdhash" ]]; then
  printf '%s\n' 'macOS ZIPとDMGのappのCDHashが一致しません' >&2
  exit 1
fi
