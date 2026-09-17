#!/bin/bash

set -euo pipefail

usage() {
  printf '使い方: %s OUTPUT_DIRECTORY DISPLAY_NAME VALIDITY_DAYS\n' "$0" >&2
}

fail() {
  printf 'エラー: %s\n' "$1" >&2
  exit 1
}

if [[ "$#" -ne 3 ]]; then
  usage
  exit 2
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  fail 'このスクリプトはmacOSで実行してください。'
fi

for required_command in openssl security mktemp chmod awk grep; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    fail "必要なコマンドが見つかりません: $required_command"
  fi
done

output_directory=$1
display_name=$2
validity_days=$3

if [[ ! -d "$output_directory" || -L "$output_directory" ]]; then
  fail '出力先は既存の通常ディレクトリで指定してください。'
fi

output_directory=$(cd "$output_directory" && pwd -P)
if [[ "$output_directory" == "/" ]]; then
  fail 'ルートディレクトリは出力先に指定できません。'
fi

has_entry=false
for entry in "$output_directory"/.[!.]* "$output_directory"/..?* "$output_directory"/*; do
  if [[ -e "$entry" || -L "$entry" ]]; then
    has_entry=true
    break
  fi
done
if [[ "$has_entry" == true ]]; then
  fail '出力先は空のディレクトリでなければなりません。'
fi

if [[ -z "$display_name" ]]; then
  fail '証明書表示名は空にできません。'
fi
if [[ "$display_name" =~ [[:cntrl:]/\\,=:#\;\"] ]]; then
  fail '証明書表示名に使用できない文字が含まれています。'
fi
if [[ "$display_name" =~ ^[[:space:]] || "$display_name" =~ [[:space:]]$ ]]; then
  fail '証明書表示名の先頭または末尾に空白を指定できません。'
fi

if [[ ! "$validity_days" =~ ^[1-9][0-9]*$ ]]; then
  fail '有効日数は1以上の整数で指定してください。'
fi
if (( validity_days > 36500 )); then
  fail '有効日数は36500以下で指定してください。'
fi

if [[ ! -t 0 || ! -t 2 ]]; then
  fail 'P12 passwordは対話入力で指定するため、端末から実行してください。'
fi

IFS= read -r -s -p 'P12 password: ' p12_password || fail 'P12 passwordの入力に失敗しました。'
printf '\n' >&2
if [[ -z "$p12_password" ]]; then
  unset p12_password
  fail 'P12 passwordは空にできません。'
fi

IFS= read -r -s -p 'P12 password again: ' p12_password_confirmation || fail 'P12 passwordの確認入力に失敗しました。'
printf '\n' >&2
if [[ "$p12_password" != "$p12_password_confirmation" ]]; then
  unset p12_password p12_password_confirmation
  fail 'P12 passwordが一致しません。'
fi

private_key_path="$output_directory/private-key.pem"
certificate_pem_path="$output_directory/certificate.pem"
certificate_der_path="$output_directory/certificate.cer"
p12_path="$output_directory/certificate.p12"
fingerprint_path="$output_directory/fingerprint.txt"

for artifact_path in "$private_key_path" "$certificate_pem_path" "$certificate_der_path" "$p12_path" "$fingerprint_path"; do
  if [[ -e "$artifact_path" || -L "$artifact_path" ]]; then
    unset p12_password p12_password_confirmation
    fail "出力ファイルが既に存在します: $artifact_path"
  fi
done

umask 077
temp_directory=$(mktemp -d "${TMPDIR:-/tmp}/personal-signing.XXXXXXXX")
trap 'unset p12_password p12_password_confirmation; rm -rf -- "$temp_directory"' EXIT

openssl_config_path="$temp_directory/openssl.cnf"
certificate_text_path="$temp_directory/certificate.txt"
private_key_text_path="$temp_directory/private-key.txt"

cat > "$openssl_config_path" <<EOF
[ req ]
prompt = no
distinguished_name = distinguished_name
x509_extensions = extensions

[ distinguished_name ]
CN = $display_name

[ extensions ]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

openssl req \
  -new \
  -x509 \
  -newkey rsa:3072 \
  -sha256 \
  -days "$validity_days" \
  -nodes \
  -config "$openssl_config_path" \
  -keyout "$private_key_path" \
  -out "$certificate_pem_path" \
  >/dev/null

openssl x509 \
  -in "$certificate_pem_path" \
  -outform DER \
  -out "$certificate_der_path"

openssl rsa -in "$private_key_path" -text -noout > "$private_key_text_path" 2>/dev/null
if ! grep -Fq '3072 bit' "$private_key_text_path"; then
  fail '生成された秘密鍵がRSA 3072ではありません。'
fi

openssl x509 -in "$certificate_pem_path" -noout -text > "$certificate_text_path"
if ! grep -Fq 'sha256WithRSAEncryption' "$certificate_text_path"; then
  fail '生成された証明書の署名アルゴリズムがSHA-256ではありません。'
fi
if ! grep -Fq 'Code Signing' "$certificate_text_path"; then
  fail '生成された証明書にCode Signing EKUがありません。'
fi

sha1_fingerprint=$(openssl dgst -sha1 -r "$certificate_der_path" | awk '{ print toupper($1) }')
sha256_fingerprint=$(openssl dgst -sha256 -r "$certificate_der_path" | awk '{ print toupper($1) }')
if [[ ! "$sha1_fingerprint" =~ ^[0-9A-F]{40}$ || ! "$sha256_fingerprint" =~ ^[0-9A-F]{64}$ ]]; then
  fail '証明書のfingerprintを計算できません。'
fi

if ! security verify-cert -c "$certificate_der_path" -r "$certificate_der_path" -p codeSign >/dev/null 2>&1; then
  fail 'securityによるCode Signing証明書の検証に失敗しました。'
fi

openssl pkcs12 \
  -export \
  -inkey "$private_key_path" \
  -in "$certificate_pem_path" \
  -name "$display_name" \
  -out "$p12_path" \
  -passout fd:3 \
  3<<<"$p12_password"

printf 'subject=CN=%s\nsha1_fingerprint=%s\nsha256_fingerprint=%s\nvalidity_days=%s\n' \
  "$display_name" "$sha1_fingerprint" "$sha256_fingerprint" "$validity_days" > "$fingerprint_path"

chmod 600 "$private_key_path" "$p12_path"
chmod 644 "$certificate_pem_path" "$certificate_der_path" "$fingerprint_path"
unset p12_password p12_password_confirmation

printf '証明書を生成しました: %s\n' "$output_directory"
