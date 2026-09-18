#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 8 ]]; then
  printf '%s\n' '使い方: sign-macos.sh central-root release-contract.json source-manifest.json unsigned-app.tar assets-directory assets-archive package-project designated-requirement' >&2
  exit 2
fi

central_root=$1
contract_path=$2
source_manifest_path=$3
unsigned_archive=$4
assets_directory=$5
assets_archive=$6
package_project=$7
designated_requirement_path=$8

if [[ ! -d "$central_root" || -L "$central_root" ]]; then
  printf '%s\n' '中央repoのpathが不正です' >&2
  exit 1
fi
for required_path in "$contract_path" "$source_manifest_path" "$unsigned_archive"; do
  if [[ ! -f "$required_path" || -L "$required_path" ]]; then
    printf '入力pathが通常fileではありません: %s\n' "$required_path" >&2
    exit 1
  fi
done
if [[ -e "$package_project" || -L "$package_project" ]]; then
  printf '%s\n' 'macOS package projectのoutputは生成開始時に存在してはいけません' >&2
  exit 1
fi
package_project_parent=$(dirname -- "$package_project")
mkdir -p -- "$package_project_parent"
if [[ -e "$assets_directory" || -L "$assets_directory" ]]; then
  if [[ ! -d "$assets_directory" || -n "$(find "$assets_directory" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    printf '出力先は空のdirectoryでなければなりません: %s\n' "$assets_directory" >&2
    exit 1
  fi
else
  mkdir -p -- "$assets_directory"
fi

source_app_id=$(jq -er '.appId' "$source_manifest_path")
source_repository=$(jq -er '.repository' "$source_manifest_path")
source_tag=$(jq -er '.tag' "$source_manifest_path")
config_digest=$(jq -er '.configDigest' "$source_manifest_path")
jq -e --arg app_id "$source_app_id" --arg repository "$source_repository" --arg tag "$source_tag" \
  --arg config_digest "$config_digest" \
  '.appId == $app_id and .repository == $repository and .tag == $tag and .configDigest == $config_digest' \
  "$contract_path" >/dev/null

signing_path="$central_root/config/signing.json"
macos_configured=$(jq -er '.macos.configured' "$signing_path")
if [[ "$macos_configured" != true ]]; then
  printf '%s\n' 'macOS signingが未設定です' >&2
  exit 1
fi
certificate_relative_path=$(jq -er '.macos.certificatePath' "$signing_path")
certificate_path="$central_root/$certificate_relative_path"
certificate_fingerprint=$(jq -er '.macos.fingerprint' "$signing_path" | tr -d ':[:space:]' | tr '[:lower:]' '[:upper:]')
display_name=$(jq -er '.macos.displayName' "$signing_path")
entitlements_path="$central_root/$(jq -er '.application.macos.entitlements' "$contract_path")"
entitlements_inherit_path="$central_root/$(jq -er '.application.macos.entitlementsInherit' "$contract_path")"
for required_path in "$certificate_path" "$entitlements_path" "$entitlements_inherit_path"; do
  if [[ ! -f "$required_path" || -L "$required_path" ]]; then
    printf '中央署名設定のfileがありません: %s\n' "$required_path" >&2
    exit 1
  fi
done
if [[ ! "$certificate_fingerprint" =~ ^[0-9A-F]{64}$ ]]; then
  printf '%s\n' 'macOS証明書fingerprintが不正です' >&2
  exit 1
fi

work_directory=$(mktemp -d "${RUNNER_TEMP:-/tmp}/central-sign-macos.XXXXXX")
umask 077
keychain_path="$work_directory/signing.keychain-db"
p12_path="$work_directory/certificate.p12"
certificate_from_p12="$work_directory/p12-certificate.pem"
private_key_from_p12="$work_directory/p12-private-key.pem"
import_p12_path="$work_directory/import-certificate.p12"
app_root="$work_directory/app"
mount_point="$work_directory/dmg"
keychain_created=false
mounted=false
package_project_created=false
cleanup() {
  local status=$?
  local cleanup_status=0
  trap - EXIT
  if [[ "$mounted" == true ]]; then
    if ! hdiutil detach "$mount_point" >/dev/null; then
      printf '%s\n' 'DMGのunmountに失敗しました' >&2
      cleanup_status=1
    fi
  fi
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
  if [[ "$package_project_created" == true && ( -e "$package_project" || -L "$package_project" ) ]]; then
    if ! rm -rf -- "$package_project"; then
      printf '%s\n' 'macOS package projectの削除に失敗しました' >&2
      cleanup_status=1
    fi
  fi
  unset p12_base64
  unset MACOS_CERTIFICATE_P12_BASE64 MACOS_CERTIFICATE_PASSWORD
  if (( status != 0 )); then
    exit "$status"
  fi
  exit "$cleanup_status"
}
trap cleanup EXIT

"$central_root/scripts/workflow/extract-archive.sh" "$unsigned_archive" "$app_root" macos
mapfile -t app_entries < <(find "$app_root" -mindepth 1 -maxdepth 1 -type d -name '*.app' -print)
if (( ${#app_entries[@]} != 1 )); then
  printf '%s\n' 'unsigned macOS archiveは直下一件の.appでなければなりません' >&2
  exit 1
fi
app_path=${app_entries[0]}

p12_base64=${MACOS_CERTIFICATE_P12_BASE64:?MACOS_CERTIFICATE_P12_BASE64が必要です}
if [[ -z "$p12_base64" || -z "${MACOS_CERTIFICATE_PASSWORD:-}" ]]; then
  printf '%s\n' 'macOS signing secretが空です' >&2
  exit 1
fi

mkdir -p -- "$mount_point"
printf '%s' "$p12_base64" | openssl base64 -d -A >"$p12_path"
chmod 600 "$p12_path"
if [[ ! -s "$p12_path" ]]; then
  printf '%s\n' 'P12をdecodeできません' >&2
  exit 1
fi

if ! openssl pkcs12 -in "$p12_path" -clcerts -nokeys \
  -passin env:MACOS_CERTIFICATE_PASSWORD >"$certificate_from_p12"; then
  printf '%s\n' 'P12のpasswordまたは内容が不正です' >&2
  exit 1
fi
if ! openssl pkcs12 -in "$p12_path" -nocerts -nodes \
  -passin env:MACOS_CERTIFICATE_PASSWORD >"$private_key_from_p12"; then
  printf '%s\n' 'P12のprivate keyを抽出できません' >&2
  exit 1
fi
chmod 600 "$certificate_from_p12" "$private_key_from_p12"
unset MACOS_CERTIFICATE_P12_BASE64 MACOS_CERTIFICATE_PASSWORD p12_base64
to_der() {
  local input_path=$1
  local output_path=$2
  if openssl x509 -in "$input_path" -outform DER -out "$output_path" 2>/dev/null; then
    return 0
  fi
  openssl x509 -inform DER -in "$input_path" -outform DER -out "$output_path"
}
p12_certificate_der="$work_directory/p12-certificate.cer"
public_certificate_der="$work_directory/public-certificate.cer"
to_der "$certificate_from_p12" "$p12_certificate_der"
to_der "$certificate_path" "$public_certificate_der"
p12_fingerprint=$(openssl dgst -sha256 -r "$p12_certificate_der" | awk '{print toupper($1)}')
public_fingerprint=$(openssl dgst -sha256 -r "$public_certificate_der" | awk '{print toupper($1)}')
if [[ "$p12_fingerprint" != "$certificate_fingerprint" || "$public_fingerprint" != "$certificate_fingerprint" ]]; then
  printf '%s\n' 'P12または公開証明書のSHA-256 fingerprintが設定と一致しません' >&2
  exit 1
fi
p12_common_name=$(bash "$central_root/scripts/workflow/extract-certificate-cn.sh" "$certificate_from_p12")
if [[ "$p12_common_name" != "$display_name" ]]; then
  printf 'P12のCNがdisplayNameと一致しません: %s\n' "$p12_common_name" >&2
  exit 1
fi

if ! openssl pkcs12 -export -out "$import_p12_path" -inkey "$private_key_from_p12" \
  -in "$certificate_from_p12" -passout fd:4 4<<<''; then
  printf '%s\n' '署名用P12を一時生成できません' >&2
  exit 1
fi
chmod 600 "$import_p12_path"
security create-keychain -p '' "$keychain_path" >/dev/null
keychain_created=true
security set-keychain-settings -lut 900 "$keychain_path"
security unlock-keychain -p '' "$keychain_path"
security import "$import_p12_path" -k "$keychain_path" -P '' \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k '' "$keychain_path" >/dev/null
identities_path="$work_directory/identities.txt"
security find-identity -v -p codesigning "$keychain_path" >"$identities_path"
identity_hash_from_p12=$(openssl x509 -in "$certificate_from_p12" -fingerprint -sha1 -noout | sed 's/.*=//; s/://g' | tr '[:lower:]' '[:upper:]')
if [[ ! "$identity_hash_from_p12" =~ ^[0-9A-F]{40}$ ]]; then
  printf '%s\n' 'P12のSHA-1 identityを取得できません' >&2
  exit 1
fi
identity_hash=''
identity_match_count=0
while IFS= read -r identity_line; do
  candidate_hash=$(awk '{print $2}' <<<"$identity_line")
  if [[ "${candidate_hash^^}" != "$identity_hash_from_p12" ]]; then
    continue
  fi
  if [[ ! "$candidate_hash" =~ ^[0-9A-Fa-f]{40}$ || "$identity_line" != *"\"$display_name\""* ]]; then
    printf '%s\n' '署名identityのSHA-1またはdisplayNameが一致しません' >&2
    exit 1
  fi
  identity_hash=$candidate_hash
  identity_match_count=$((identity_match_count + 1))
done <"$identities_path"
if (( identity_match_count != 1 )); then
  printf '%s\n' '署名identityのSHA-1一致が一件ではありません' >&2
  exit 1
fi
export CENTRAL_SIGN_APP="$app_path"
export CENTRAL_SIGN_IDENTITY="$identity_hash"
export CENTRAL_SIGN_KEYCHAIN="$keychain_path"
export CENTRAL_SIGN_ENTITLEMENTS="$entitlements_path"
export CENTRAL_SIGN_ENTITLEMENTS_INHERIT="$entitlements_inherit_path"
export CSC_NAME="$identity_hash"
node --input-type=module <<'NODE'
import { sign } from "@electron/osx-sign";

const app = process.env.CENTRAL_SIGN_APP;
const identity = process.env.CENTRAL_SIGN_IDENTITY;
const keychain = process.env.CENTRAL_SIGN_KEYCHAIN;
const entitlements = process.env.CENTRAL_SIGN_ENTITLEMENTS;
const entitlementsInherit = process.env.CENTRAL_SIGN_ENTITLEMENTS_INHERIT;
if (app === undefined || identity === undefined || keychain === undefined || entitlements === undefined || entitlementsInherit === undefined) {
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
  optionsForFile: (filePath) => ({
    entitlements: filePath === app ? entitlements : entitlementsInherit,
    hardenedRuntime: true,
    timestamp: "none"
  })
});
NODE
unset CENTRAL_SIGN_APP CENTRAL_SIGN_IDENTITY CENTRAL_SIGN_KEYCHAIN CENTRAL_SIGN_ENTITLEMENTS CENTRAL_SIGN_ENTITLEMENTS_INHERIT

codesign --verify --deep --strict --verbose=2 "$app_path"
codesign -d -r- --verbose=4 "$app_path" 2>"$designated_requirement_path"
if [[ ! -s "$designated_requirement_path" ]]; then
  printf '%s\n' 'designated requirementを記録できません' >&2
  exit 1
fi

package_project_created=true
(cd "$central_root" && CSC_IDENTITY_AUTO_DISCOVERY=false CSC_NAME="$identity_hash" pnpm exec tsx src/cli.ts create-package-project \
  --contract "$contract_path" --target macos --output-directory "$package_project")
if ! grep -Fq 'gatekeeperAssess: false' "$package_project/electron-builder.yml"; then
  printf '%s\n' 'macOS package projectのgatekeeperAssessが無効ではありません' >&2
  exit 1
fi
(cd "$central_root" && CSC_IDENTITY_AUTO_DISCOVERY=false CSC_NAME="$identity_hash" pnpm exec electron-builder \
  --projectDir "$package_project" --config "$package_project/electron-builder.yml" \
  --prepackaged "$app_path" --publish never)

version=$(jq -er '.version' "$contract_path")
artifact_name=$(jq -er '.application.identity.artifactName' "$contract_path")
architecture=$(jq -er '.application.macos.architecture' "$contract_path")
channel=$(jq -er '.application.release.channel' "$contract_path")
zip_name="$artifact_name-$version-$architecture.zip"
dmg_name="$artifact_name-$version-$architecture.dmg"
metadata_name="$channel-mac.yml"
dist_directory="$package_project/dist"
for file_name in "$zip_name" "$dmg_name" "$metadata_name"; do
  if [[ ! -f "$dist_directory/$file_name" || -L "$dist_directory/$file_name" ]]; then
    printf 'macOS package assetがありません: %s\n' "$file_name" >&2
    exit 1
  fi
done
zip_directory="$work_directory/zip"
mkdir -p -- "$zip_directory"
unzip -q "$dist_directory/$zip_name" -d "$zip_directory"
mapfile -t zipped_apps < <(find "$zip_directory" -mindepth 1 -maxdepth 1 -type d -name '*.app' -print)
if (( ${#zipped_apps[@]} != 1 )); then
  printf '%s\n' 'ZIP内の.appが一件ではありません' >&2
  exit 1
fi
codesign --verify --deep --strict --verbose=2 "${zipped_apps[0]}"
hdiutil verify "$dist_directory/$dmg_name" >/dev/null
if ! hdiutil attach -nobrowse -readonly -mountpoint "$mount_point" "$dist_directory/$dmg_name" >/dev/null; then
  printf '%s\n' 'DMGをmountできません' >&2
  exit 1
fi
mounted=true
mapfile -t mounted_apps < <(find "$mount_point" -mindepth 1 -maxdepth 2 -type d -name '*.app' -print)
if (( ${#mounted_apps[@]} != 1 )); then
  printf '%s\n' 'DMG内の.appが一件ではありません' >&2
  exit 1
fi
codesign --verify --deep --strict --verbose=2 "${mounted_apps[0]}"
hdiutil detach "$mount_point" >/dev/null
mounted=false

cp -- "$dist_directory/$zip_name" "$assets_directory/$zip_name"
cp -- "$dist_directory/$dmg_name" "$assets_directory/$dmg_name"
cp -- "$dist_directory/$metadata_name" "$assets_directory/$metadata_name"
tar -cf "$assets_archive" -C "$assets_directory" .
if [[ ! -s "$assets_archive" ]]; then
  printf '%s\n' 'macOS signed assets archiveが空です' >&2
  exit 1
fi
