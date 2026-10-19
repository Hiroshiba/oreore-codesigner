#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 2 ]]; then
  printf '%s\n' '使い方: validate-macos-library-validation.sh zip-path extraction-directory' >&2
  exit 2
fi

zip_path=$1
extraction_directory=$2

if [[ ! -f "$zip_path" || -L "$zip_path" ]]; then
  printf '%s\n' 'macOS ZIPが通常fileではありません' >&2
  exit 1
fi
if [[ -e "$extraction_directory" || -L "$extraction_directory" ]]; then
  printf '%s\n' 'macOS ZIPの展開先は存在しないdirectoryを指定してください' >&2
  exit 1
fi

mkdir -p -- "$extraction_directory"
ditto -x -k "$zip_path" "$extraction_directory"
shopt -s nullglob
apps=("$extraction_directory"/*.app)
shopt -u nullglob
if (( ${#apps[@]} != 1 )); then
  printf '%s\n' 'macOS ZIPの直下にappが一つ必要です' >&2
  exit 1
fi
app_path=${apps[0]}
if [[ ! -d "$app_path" || -L "$app_path" ]]; then
  printf '%s\n' 'macOS ZIP内のappが通常directoryではありません' >&2
  exit 1
fi

info_plist="$app_path/Contents/Info.plist"
executable_name=$(plutil -extract CFBundleExecutable raw -o - "$info_plist")
if [[ -z "$executable_name" || "$executable_name" == . || "$executable_name" == .. || "$executable_name" == */* ]]; then
  printf '%s\n' 'macOS appの主実行ファイル名が不正です' >&2
  exit 1
fi
executable_path="$app_path/Contents/MacOS/$executable_name"
if [[ ! -f "$executable_path" || -L "$executable_path" ]]; then
  printf '%s\n' 'macOS appの主実行ファイルが通常fileではありません' >&2
  exit 1
fi

signature_info="$extraction_directory/signature-info.txt"
entitlements_plist="$extraction_directory/entitlements.plist"
if ! codesign -d --verbose=4 --xml --entitlements "$entitlements_plist" "$executable_path" 2> "$signature_info"; then
  cat "$signature_info" >&2
  printf '%s\n' 'macOS appの署名情報を取得できません' >&2
  exit 1
fi
flags_hex=$(sed -nE 's/^CodeDirectory .* flags=0x([[:xdigit:]]+).*/\1/p' "$signature_info")
team_id=$(sed -n 's/^TeamIdentifier=//p' "$signature_info")
if [[ ! "$flags_hex" =~ ^[[:xdigit:]]+$ || -z "$team_id" ]]; then
  printf '%s\n' 'macOS appの署名情報からflagsまたはTeam IDを取得できません' >&2
  exit 1
fi

library_validation_disabled=false
if [[ -e "$entitlements_plist" ]]; then
  library_validation_disabled=$(
    plutil -convert json -o - "$entitlements_plist" |
      jq -r 'if type == "object" then .["com.apple.security.cs.disable-library-validation"] == true else error("entitlementsがdictionaryではありません") end'
  )
fi
if (( (16#$flags_hex & 0x10000) != 0 )) && [[ "$team_id" == 'not set' && "$library_validation_disabled" != true ]]; then
  printf '%s\n' 'Hardened Runtimeが有効でTeam IDがないmacOS appにはcom.apple.security.cs.disable-library-validation=trueが必要です' >&2
  exit 1
fi
