#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 5 ]]; then
  printf '%s\n' '使い方: sign-macos.sh unsigned-app-archive package-input-directory repository tag release-output-directory' >&2
  exit 2
fi

unsigned_archive=$1
package_input_directory=$2
repository=$3
tag=$4
release_output_directory=$5

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
central_root=$(cd -- "$script_directory/../.." && pwd -P)
safe_extract_path="$script_directory/safe-extract.py"
signing_path="$central_root/config/signing.json"
package_input_path="$package_input_directory/package-input.json"

if [[ ! -f "$unsigned_archive" || -L "$unsigned_archive" ]]; then
  printf '%s\n' 'unsigned app archiveが通常fileではありません' >&2
  exit 1
fi
if [[ ! -d "$package_input_directory" || -L "$package_input_directory" ]]; then
  printf '%s\n' 'package-input directoryが通常directoryではありません' >&2
  exit 1
fi
if [[ ! -f "$package_input_path" || -L "$package_input_path" ]]; then
  printf '%s\n' 'package-input.jsonが通常fileではありません' >&2
  exit 1
fi
if [[ ! -f "$safe_extract_path" || -L "$safe_extract_path" ]]; then
  printf '%s\n' 'safe-extract.pyが通常fileではありません' >&2
  exit 1
fi
if [[ ! -f "$signing_path" || -L "$signing_path" ]]; then
  printf '%s\n' '中央署名設定が通常fileではありません' >&2
  exit 1
fi
if [[ ! -d "$central_root" || -L "$central_root" ]]; then
  printf '%s\n' '中央repoのpathが不正です' >&2
  exit 1
fi
if [[ ! "$repository" =~ ^[A-Za-z0-9]([A-Za-z0-9_.-]*[A-Za-z0-9])?/[A-Za-z0-9]([A-Za-z0-9_.-]*[A-Za-z0-9])?$ ]]; then
  printf '%s\n' 'repositoryはowner/name形式でなければなりません' >&2
  exit 1
fi
if [[ -z "$tag" || "$tag" == *$'\n'* || "$tag" == *$'\r'* ]]; then
  printf '%s\n' 'tagが不正です' >&2
  exit 1
fi
if [[ -z "$release_output_directory" ]]; then
  printf '%s\n' 'release output directoryが空です' >&2
  exit 1
fi
if [[ -e "$release_output_directory" || -L "$release_output_directory" ]]; then
  if [[ ! -d "$release_output_directory" || -L "$release_output_directory" || -n "$(find "$release_output_directory" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    printf '%s\n' 'release outputは空のdirectoryでなければなりません' >&2
    exit 1
  fi
else
  mkdir -p -- "$release_output_directory"
fi

release_payload_directory="$release_output_directory/payload"
release_metadata_directory="$release_output_directory/metadata"
mkdir -p -- "$release_payload_directory" "$release_metadata_directory"

umask 077
work_directory=$(mktemp -d "${RUNNER_TEMP:-/tmp}/central-sign-macos.XXXXXX")
keychain_path="$work_directory/signing.keychain-db"
p12_path="$work_directory/certificate.p12"
leaf_certificate_path="$work_directory/leaf-certificate.pem"
app_root="$work_directory/app"
package_project="$work_directory/package-project"
keychain_created=false
cleanup() {
  local status=$?
  local cleanup_status=0
  trap - EXIT
  unset MACOS_CERTIFICATE_P12_BASE64 MACOS_CERTIFICATE_PASSWORD
  if [[ "$keychain_created" == true ]]; then
    if ! security delete-keychain "$keychain_path" >/dev/null; then
      printf '%s\n' '一時keychainの削除に失敗しました' >&2
      cleanup_status=1
    fi
  fi
  if ! rm -rf -- "$work_directory"; then
    printf '%s\n' 'macOS signing用一時directoryの削除に失敗しました' >&2
    cleanup_status=1
  fi
  if (( status != 0 )); then
    exit "$status"
  fi
  exit "$cleanup_status"
}
trap cleanup EXIT

if ! (cd "$central_root" && pnpm cli create-package-project \
  --package-input-directory "$package_input_directory" --target macos \
  --repository "$repository" --tag "$tag" --output-directory "$package_project"); then
  printf '%s\n' 'macOS package projectの生成に失敗しました' >&2
  exit 1
fi
if [[ ! -d "$package_project" || -L "$package_project" ]]; then
  printf '%s\n' 'macOS package projectが生成されませんでした' >&2
  exit 1
fi
app_id=$(jq -er '.appId' "$package_input_path")
version=$(jq -er '.version' "$package_input_path")
product_name=$(jq -er '.productName' "$package_input_path")
entitlements_path=''
entitlements_inherit_path=''
entitlements_name=$(jq -r '.macos.entitlements // empty' "$package_input_path")
if [[ -n "$entitlements_name" ]]; then
  entitlements_path="$package_project/entitlements.plist"
fi
entitlements_inherit_name=$(jq -r '.macos.entitlementsInherit // empty' "$package_input_path")
if [[ -n "$entitlements_inherit_name" ]]; then
  entitlements_inherit_path="$package_project/entitlements-inherit.plist"
fi
for optional_path in "$entitlements_path" "$entitlements_inherit_path"; do
  if [[ -z "$optional_path" ]]; then
    continue
  fi
  if [[ ! -f "$optional_path" || -L "$optional_path" ]]; then
    printf '生成されたentitlementsが通常fileではありません: %s\n' "$optional_path" >&2
    exit 1
  fi
done

python_path=$(command -v python3 || true)
if [[ -z "$python_path" ]]; then
  printf '%s\n' 'python3が見つかりません' >&2
  exit 1
fi
if ! "$python_path" "$safe_extract_path" \
  --archive "$unsigned_archive" --output "$app_root" --platform macos; then
  printf '%s\n' 'unsigned app archiveの安全な展開に失敗しました' >&2
  exit 1
fi
mapfile -d '' -t app_entries < <(find "$app_root" -mindepth 1 -maxdepth 1 -type d -name '*.app' -print0)
if (( ${#app_entries[@]} != 1 )); then
  printf '%s\n' 'unsigned app archiveは直下一件の.appでなければなりません' >&2
  exit 1
fi
app_path=${app_entries[0]}

info_plist_path="$app_path/Contents/Info.plist"
if [[ ! -f "$info_plist_path" || -L "$info_plist_path" ]]; then
  printf '%s\n' 'prepackaged appのInfo.plistが通常fileではありません' >&2
  exit 1
fi
if ! bundle_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist_path"); then
  printf '%s\n' 'prepackaged appのbundle identifierを読み込めません' >&2
  exit 1
fi
if ! bundle_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$info_plist_path" 2>/dev/null); then
  if ! bundle_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$info_plist_path" 2>/dev/null); then
    printf '%s\n' 'prepackaged appの名前を読み込めません' >&2
    exit 1
  fi
fi
short_version=''
if short_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist_path" 2>/dev/null); then
  :
fi
bundle_version=''
if bundle_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist_path" 2>/dev/null); then
  :
fi
if [[ "$bundle_identifier" != "$app_id" || "$bundle_name" != "$product_name" ]]; then
  printf '%s\n' 'prepackaged appのInfo.plistがpackage-inputと一致しません' >&2
  exit 1
fi
if [[ -n "$short_version" && "$short_version" != "$version" ]]; then
  printf '%s\n' 'prepackaged appのCFBundleShortVersionStringがpackage-inputと一致しません' >&2
  exit 1
fi
if [[ -n "$bundle_version" && "$bundle_version" != "$version" ]]; then
  printf '%s\n' 'prepackaged appのCFBundleVersionがpackage-inputと一致しません' >&2
  exit 1
fi
if [[ -z "$short_version" && -z "$bundle_version" ]]; then
  printf '%s\n' 'prepackaged appにversionがありません' >&2
  exit 1
fi

if [[ -z "${MACOS_CERTIFICATE_P12_BASE64:-}" || -z "${MACOS_CERTIFICATE_PASSWORD:-}" ]]; then
  printf '%s\n' 'macOS signing secretが必要です' >&2
  exit 1
fi
if ! printf '%s' "$MACOS_CERTIFICATE_P12_BASE64" | openssl base64 -d -A >"$p12_path"; then
  printf '%s\n' 'P12をdecodeできません' >&2
  exit 1
fi
chmod 600 "$p12_path"
unset MACOS_CERTIFICATE_P12_BASE64
if [[ ! -s "$p12_path" ]]; then
  printf '%s\n' 'P12をdecodeできません' >&2
  exit 1
fi
if ! openssl pkcs12 -in "$p12_path" -clcerts -nokeys \
  -passin env:MACOS_CERTIFICATE_PASSWORD -out "$leaf_certificate_path"; then
  printf '%s\n' 'P12のpasswordまたは内容が不正です' >&2
  exit 1
fi
chmod 600 "$leaf_certificate_path"

if ! macos_configured=$(jq -er '.macos.configured' "$signing_path"); then
  printf '%s\n' 'macOS signing設定を読み込めません' >&2
  exit 1
fi
if [[ "$macos_configured" != true ]]; then
  printf '%s\n' 'macOS signingが未設定です' >&2
  exit 1
fi
if ! certificate_fingerprint=$(jq -er '.macos.fingerprint' "$signing_path" | tr -d ':[:space:]' | tr '[:lower:]' '[:upper:]'); then
  printf '%s\n' 'macOS証明書fingerprintを読み込めません' >&2
  exit 1
fi
if ! display_name=$(jq -er '.macos.displayName' "$signing_path"); then
  printf '%s\n' 'macOS証明書displayNameを読み込めません' >&2
  exit 1
fi
if [[ ! "$certificate_fingerprint" =~ ^[0-9A-F]{64}$ ]]; then
  printf '%s\n' 'macOS証明書fingerprintが不正です' >&2
  exit 1
fi
if ! p12_fingerprint=$(openssl x509 -in "$leaf_certificate_path" -outform DER | openssl dgst -sha256 -r | awk '{print toupper($1)}'); then
  printf '%s\n' 'P12のSHA-256 fingerprintを取得できません' >&2
  exit 1
fi
if [[ "$p12_fingerprint" != "$certificate_fingerprint" ]]; then
  printf '%s\n' 'P12のSHA-256 fingerprintが設定と一致しません' >&2
  exit 1
fi
if ! p12_common_name=$("$script_directory/extract-certificate-cn.sh" "$leaf_certificate_path"); then
  printf '%s\n' 'P12のCNを取得できません' >&2
  exit 1
fi
if [[ "$p12_common_name" != "$display_name" ]]; then
  printf '%s\n' 'P12のCNがdisplayNameと一致しません' >&2
  exit 1
fi

if ! security create-keychain -p '' "$keychain_path" >/dev/null; then
  printf '%s\n' '一時keychainを作成できません' >&2
  exit 1
fi
keychain_created=true
if ! security set-keychain-settings -lut 900 "$keychain_path" >/dev/null; then
  printf '%s\n' '一時keychainの設定に失敗しました' >&2
  exit 1
fi
if ! security unlock-keychain -p '' "$keychain_path" >/dev/null; then
  printf '%s\n' '一時keychainをunlockできません' >&2
  exit 1
fi
if ! security import "$p12_path" -k "$keychain_path" -P "$MACOS_CERTIFICATE_PASSWORD" \
  -T /usr/bin/codesign >/dev/null; then
  printf '%s\n' 'P12を一時keychainへimportできません' >&2
  exit 1
fi
unset MACOS_CERTIFICATE_PASSWORD
if ! security set-key-partition-list -S apple-tool:,apple: -s -k '' "$keychain_path" >/dev/null; then
  printf '%s\n' '一時keychainのpartition設定に失敗しました' >&2
  exit 1
fi
if ! identity=$(openssl x509 -in "$leaf_certificate_path" -outform DER | openssl dgst -sha1 -r | awk '{print toupper($1)}'); then
  printf '%s\n' 'P12の署名identityを取得できません' >&2
  exit 1
fi
if [[ ! "$identity" =~ ^[0-9A-F]{40}$ ]]; then
  printf '%s\n' 'P12の署名identityが不正です' >&2
  exit 1
fi

export CENTRAL_SIGN_APP="$app_path"
export CENTRAL_SIGN_IDENTITY="$identity"
export CENTRAL_SIGN_KEYCHAIN="$keychain_path"
if [[ -f "$entitlements_path" ]]; then
  export CENTRAL_SIGN_ENTITLEMENTS="$entitlements_path"
else
  unset CENTRAL_SIGN_ENTITLEMENTS
fi
if [[ -f "$entitlements_inherit_path" ]]; then
  export CENTRAL_SIGN_ENTITLEMENTS_INHERIT="$entitlements_inherit_path"
else
  unset CENTRAL_SIGN_ENTITLEMENTS_INHERIT
fi
node --input-type=module <<'NODE'
import { sign } from "@electron/osx-sign";

const app = process.env.CENTRAL_SIGN_APP;
const identity = process.env.CENTRAL_SIGN_IDENTITY;
const keychain = process.env.CENTRAL_SIGN_KEYCHAIN;
const entitlements = process.env.CENTRAL_SIGN_ENTITLEMENTS;
const entitlementsInherit = process.env.CENTRAL_SIGN_ENTITLEMENTS_INHERIT;
if (app === undefined || identity === undefined || keychain === undefined) {
  throw new Error("macOS signing inputがありません");
}
await sign({
  app,
  identity,
  keychain,
  platform: "darwin",
  type: "distribution",
  preAutoEntitlements: false,
  preEmbedProvisioningProfile: false,
  strictVerify: true,
  optionsForFile: (filePath) => {
    const options = { hardenedRuntime: true, timestamp: "none" };
    if (filePath === app && entitlements !== undefined) {
      options.entitlements = entitlements;
    }
    if (filePath !== app && entitlementsInherit !== undefined) {
      options.entitlements = entitlementsInherit;
    }
    return options;
  }
});
NODE
unset CENTRAL_SIGN_APP CENTRAL_SIGN_IDENTITY CENTRAL_SIGN_KEYCHAIN CENTRAL_SIGN_ENTITLEMENTS CENTRAL_SIGN_ENTITLEMENTS_INHERIT

if ! codesign --verify --deep --strict --verbose=2 "$app_path"; then
  printf '%s\n' '署名検証に失敗しました' >&2
  exit 1
fi

if ! (cd "$central_root" && pnpm exec electron-builder \
  --projectDir "$package_project" --prepackaged "$app_path" --publish never); then
  printf '%s\n' 'macOS ZIPの生成に失敗しました' >&2
  exit 1
fi

dist_directory="$package_project/dist"
if [[ ! -d "$dist_directory" || -L "$dist_directory" ]]; then
  printf '%s\n' 'macOS package outputのdirectoryがありません' >&2
  exit 1
fi
mapfile -d '' -t zip_entries < <(find "$dist_directory" -mindepth 1 -maxdepth 1 -type f -name '*.zip' -print0)
mapfile -d '' -t blockmap_entries < <(find "$dist_directory" -mindepth 1 -maxdepth 1 -type f -name '*.blockmap' -print0)
mapfile -d '' -t metadata_entries < <(find "$dist_directory" -mindepth 1 -maxdepth 1 -type f -name '*-mac.yml' -print0)
if (( ${#zip_entries[@]} != 1 || ${#blockmap_entries[@]} != 1 || ${#metadata_entries[@]} != 1 )); then
  printf '%s\n' 'macOS packageのZIP、blockmap、update metadataが揃っていません' >&2
  exit 1
fi
zip_path=${zip_entries[0]}
blockmap_path=${blockmap_entries[0]}
metadata_path=${metadata_entries[0]}
zip_name=$(basename -- "$zip_path")
blockmap_name=$(basename -- "$blockmap_path")
metadata_name=$(basename -- "$metadata_path")
for output_path in \
  "$release_payload_directory/$zip_name" \
  "$release_payload_directory/$blockmap_name" \
  "$release_metadata_directory/$metadata_name"; do
  if [[ -e "$output_path" || -L "$output_path" ]]; then
    printf 'release outputが既に存在します: %s\n' "$output_path" >&2
    exit 1
  fi
done
cp -- "$zip_path" "$release_payload_directory/$zip_name"
cp -- "$blockmap_path" "$release_payload_directory/$blockmap_name"
cp -- "$metadata_path" "$release_metadata_directory/$metadata_name"
