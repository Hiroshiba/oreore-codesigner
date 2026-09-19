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

for required_command in uname openssl security uuidgen mktemp awk sed base64 tr plutil chmod mv dirname basename cmp cat rm; do
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
cleanup() {
  local status=$?
  local cleanup_detail=''

  trap - EXIT
  if [[ -d "$temp_directory" ]]; then
    if ! rm -rf -- "$temp_directory"; then
      cleanup_detail=" 一時directory削除失敗: $temp_directory"
    fi
  fi
  if [[ -n "$cleanup_detail" ]]; then
    printf 'エラー: cleanupに失敗しました。%s\n' "$cleanup_detail" >&2
    if (( status == 0 )); then
      status=1
    fi
  fi
  exit "$status"
}
trap cleanup EXIT

canonical_der_path="$temp_directory/certificate.der"
certificate_text_path="$temp_directory/certificate.txt"
verify_text_path="$temp_directory/certificate-verify.txt"
profile_temp_path="$temp_directory/profile.mobileconfig"

openssl x509 \
  -inform DER \
  -in "$certificate_path" \
  -outform DER \
  -out "$canonical_der_path"
if ! cmp -s "$certificate_path" "$canonical_der_path"; then
  fail '入力証明書はDER形式で指定してください。'
fi
openssl x509 \
  -inform DER \
  -in "$canonical_der_path" \
  -noout \
  -text > "$certificate_text_path"

certificate_subject=$(openssl x509 -inform DER -in "$canonical_der_path" -noout -subject -nameopt RFC2253 | sed -n 's/^subject=//p')
certificate_issuer=$(openssl x509 -inform DER -in "$canonical_der_path" -noout -issuer -nameopt RFC2253 | sed -n 's/^issuer=//p')
if [[ -z "$certificate_subject" || "$certificate_subject" != "$certificate_issuer" ]]; then
  fail '入力証明書は自己署名証明書でなければなりません。'
fi
if ! security verify-cert -c "$canonical_der_path" -r "$canonical_der_path" -p codeSign > "$verify_text_path" 2>&1; then
  fail '入力証明書の自己署名を検証できません。'
fi

if ! awk '
/X509v3 Basic Constraints:/ { in_constraints = 1; next }
in_constraints && /^[[:space:]]*X509v3 / { in_constraints = 0 }
in_constraints && /CA:TRUE/ { found_true = 1 }
in_constraints && /CA:FALSE/ { found_false = 1 }
END { exit(found_true || !found_false ? 1 : 0) }
' "$certificate_text_path"; then
  fail '入力証明書はCA:FALSEのleaf証明書でなければなりません。'
fi
if ! awk '
/X509v3 Extended Key Usage:/ { in_eku = 1; next }
in_eku && /^[[:space:]]*X509v3 / { in_eku = 0 }
in_eku && tolower($0) ~ /code signing/ { found = 1 }
END { exit(found ? 0 : 1) }
' "$certificate_text_path"; then
  fail '入力証明書のExtended Key UsageにCode Signingがありません。'
fi

sha1_fingerprint=$(openssl dgst -sha1 -r "$canonical_der_path" | awk '{ print toupper($1) }')
sha256_fingerprint=$(openssl dgst -sha256 -r "$canonical_der_path" | awk '{ print toupper($1) }')
if [[ ! "$sha1_fingerprint" =~ ^[0-9A-F]{40}$ || ! "$sha256_fingerprint" =~ ^[0-9A-F]{64}$ ]]; then
  fail '証明書のfingerprintを計算できません。'
fi

leaf_certificate_base64=$(base64 < "$canonical_der_path" | tr -d '\n')
if [[ ! "$leaf_certificate_base64" =~ ^[A-Za-z0-9+/]+=*$ ]]; then
  fail 'leaf証明書のbase64化に失敗しました。'
fi

profile_uuid=$(uuidgen | tr '[:lower:]' '[:upper:]')
rule_uuid=$(uuidgen | tr '[:lower:]' '[:upper:]')
if [[ ! "$profile_uuid" =~ ^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$ || ! "$rule_uuid" =~ ^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$ || "$profile_uuid" == "$rule_uuid" ]]; then
  fail 'UUIDを生成できません。'
fi

cat > "$profile_temp_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>PayloadContent</key>
  <array>
    <dict>
      <key>Comment</key>
      <string>certificate-sha256=$sha256_fingerprint</string>
      <key>LeafCertificate</key>
      <data>$leaf_certificate_base64</data>
      <key>OperationType</key>
      <string>operation:execute</string>
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
chmod 644 "$profile_temp_path"
mv -n "$profile_temp_path" "$output_path"
if [[ -e "$profile_temp_path" || -L "$profile_temp_path" ]]; then
  fail 'プロファイル出力中に既存の出力先が検出されました。'
fi

printf 'system policy ruleの候補を生成しました: %s\n' "$output_path"
printf 'certificate leafのSHA-1 fingerprint: %s\n' "$sha1_fingerprint"
printf 'certificate leafのSHA-256 fingerprint: %s\n' "$sha256_fingerprint"
