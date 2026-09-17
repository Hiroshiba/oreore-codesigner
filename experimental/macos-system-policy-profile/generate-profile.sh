#!/bin/bash

set -euo pipefail

usage() {
  printf '使い方: %s CERTIFICATE_DER OUTPUT_PROFILE\n' "$0" >&2
}

fail() {
  printf 'エラー: %s\n' "$1" >&2
  exit 1
}

if [[ "$#" -ne 2 ]]; then
  usage
  exit 2
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  fail 'このスクリプトはmacOSで実行してください。'
fi

for required_command in openssl uuidgen mktemp awk grep sed base64 tr plutil chmod mv dirname basename; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    fail "必要なコマンドが見つかりません: $required_command"
  fi
done

certificate_path=$1
output_path=$2

if [[ ! -f "$certificate_path" || -L "$certificate_path" ]]; then
  fail '入力証明書は既存の通常ファイルで指定してください。'
fi
certificate_path=$(cd "$(dirname "$certificate_path")" && pwd -P)/$(basename "$certificate_path")

output_name=$(basename "$output_path")
output_parent=$(dirname "$output_path")
if [[ -z "$output_name" || "$output_name" == '.' || "$output_name" == '..' ]]; then
  fail '出力プロファイルのパスが不正です。'
fi
if [[ ! -d "$output_parent" || -L "$output_parent" ]]; then
  fail '出力先の親ディレクトリは既存の通常ディレクトリで指定してください。'
fi
output_parent=$(cd "$output_parent" && pwd -P)
output_path="$output_parent/$output_name"
if [[ -e "$output_path" || -L "$output_path" ]]; then
  fail '出力プロファイルが既に存在します。'
fi

umask 077
temp_directory=$(mktemp -d "${TMPDIR:-/tmp}/personal-signing-profile.XXXXXXXX")
trap 'rm -rf -- "$temp_directory"' EXIT

canonical_der_path="$temp_directory/certificate.der"
certificate_text_path="$temp_directory/certificate.txt"
profile_temp_path="$temp_directory/profile.mobileconfig"

openssl x509 \
  -inform DER \
  -in "$certificate_path" \
  -outform DER \
  -out "$canonical_der_path"
openssl x509 \
  -inform DER \
  -in "$canonical_der_path" \
  -noout \
  -text > "$certificate_text_path"

if ! grep -Fq 'Code Signing' "$certificate_text_path"; then
  fail '入力証明書にCode Signing EKUがありません。'
fi

sha1_fingerprint=$(openssl dgst -sha1 -r "$canonical_der_path" | awk '{ print toupper($1) }')
if [[ ! "$sha1_fingerprint" =~ ^[0-9A-F]{40}$ ]]; then
  fail '証明書のSHA-1 fingerprintを計算できません。'
fi

include_root_payload=false
certificate_subject=$(openssl x509 -inform DER -in "$canonical_der_path" -noout -subject -nameopt RFC2253 | sed -n 's/^subject=//p')
certificate_issuer=$(openssl x509 -inform DER -in "$canonical_der_path" -noout -issuer -nameopt RFC2253 | sed -n 's/^issuer=//p')
if [[ "$certificate_subject" == "$certificate_issuer" ]] && awk '
/X509v3 Basic Constraints:/ { in_constraints = 1; next }
in_constraints && /^[[:space:]]*X509v3 / { in_constraints = 0 }
in_constraints && /CA:TRUE/ { found = 1 }
END { exit(found ? 0 : 1) }
' "$certificate_text_path"; then
  include_root_payload=true
fi

profile_uuid=$(uuidgen | tr '[:lower:]' '[:upper:]')
rule_uuid=$(uuidgen | tr '[:lower:]' '[:upper:]')
root_uuid=$(uuidgen | tr '[:lower:]' '[:upper:]')
if [[ ! "$profile_uuid" =~ ^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$ || ! "$rule_uuid" =~ ^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$ || ! "$root_uuid" =~ ^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$ ]]; then
  fail 'UUIDを生成できません。'
fi

certificate_base64=''
if [[ "$include_root_payload" == true ]]; then
  certificate_base64=$(base64 < "$canonical_der_path" | tr -d '\n')
fi

cat > "$profile_temp_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>PayloadContent</key>
  <array>
EOF

if [[ "$include_root_payload" == true ]]; then
  cat >> "$profile_temp_path" <<EOF
    <dict>
      <key>PayloadCertificateFileName</key>
      <string>certificate.cer</string>
      <key>PayloadContent</key>
      <data>$certificate_base64</data>
      <key>PayloadDisplayName</key>
      <string>Personal Signing Certificate Trust</string>
      <key>PayloadIdentifier</key>
      <string>com.personal-signing.experimental.macos-system-policy.root</string>
      <key>PayloadType</key>
      <string>com.apple.security.root</string>
      <key>PayloadUUID</key>
      <string>$root_uuid</string>
      <key>PayloadVersion</key>
      <integer>1</integer>
    </dict>
EOF
fi

cat >> "$profile_temp_path" <<EOF
    <dict>
      <key>OperationType</key>
      <string>execute</string>
      <key>PayloadDisplayName</key>
      <string>Personal Signing Execute Rule</string>
      <key>PayloadIdentifier</key>
      <string>com.personal-signing.experimental.macos-system-policy.rule</string>
      <key>PayloadType</key>
      <string>com.apple.systempolicy.rule</string>
      <key>PayloadUUID</key>
      <string>$rule_uuid</string>
      <key>PayloadVersion</key>
      <integer>1</integer>
      <key>Requirement</key>
      <string>certificate leaf = H&quot;$sha1_fingerprint&quot;</string>
      <key>RuleType</key>
      <string>leaf</string>
    </dict>
  </array>
  <key>PayloadDisplayName</key>
  <string>Personal Signing macOS System Policy Experimental</string>
  <key>PayloadIdentifier</key>
  <string>com.personal-signing.experimental.macos-system-policy</string>
  <key>PayloadOrganization</key>
  <string>Personal Signing</string>
  <key>PayloadRemovalDisallowed</key>
  <false/>
  <key>PayloadScope</key>
  <string>System</string>
  <key>PayloadType</key>
  <string>Configuration</string>
  <key>PayloadUUID</key>
  <string>$profile_uuid</string>
  <key>PayloadVersion</key>
  <integer>1</integer>
</dict>
</plist>
EOF

plutil -lint "$profile_temp_path" >/dev/null
mv -n "$profile_temp_path" "$output_path"
if [[ -e "$profile_temp_path" || -L "$profile_temp_path" ]]; then
  fail 'プロファイル出力中に既存の出力先が検出されました。'
fi
chmod 644 "$output_path"

if [[ "$include_root_payload" == true ]]; then
  printf '証明書trust payloadとsystem policy ruleの候補を生成しました: %s\n' "$output_path"
else
  printf 'system policy ruleだけの候補を生成しました: %s\n' "$output_path"
fi
printf 'certificate leafのSHA-1 fingerprint: %s\n' "$sha1_fingerprint"
