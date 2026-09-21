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

for artifact_path in \
  "$output_directory/certificate.cer" \
  "$output_directory/certificate.p12" \
  "$output_directory/fingerprint.txt"; do
  if [[ -e "$artifact_path" || -L "$artifact_path" ]]; then
    fail "出力ファイルが既に存在します: $artifact_path"
  fi
done

umask 077
temp_directory=$(mktemp -d "${TMPDIR:-/tmp}/personal-signing.XXXXXXXX")

cleanup() {
  local status=$?
  local cleanup_failed=0
  local cleanup_detail=''

  trap - EXIT
  if [[ -n "${verification_keychain_path:-}" && -e "$verification_keychain_path" ]]; then
    if ! security delete-keychain "$verification_keychain_path" >/dev/null 2>&1; then
      cleanup_failed=1
      cleanup_detail="${cleanup_detail} 検証用keychain削除失敗: $verification_keychain_path"
    fi
  fi
  if [[ -d "$temp_directory" ]]; then
    if ! rm -rf -- "$temp_directory"; then
      cleanup_failed=1
      cleanup_detail="${cleanup_detail} 一時directory削除失敗: $temp_directory"
    fi
  fi
  unset p12_password p12_password_confirmation verification_keychain_password
  if (( cleanup_failed != 0 )); then
    printf 'エラー: cleanupに失敗しました。%s\n' "$cleanup_detail" >&2
    if (( status == 0 )); then
      status=1
    fi
  fi
  exit "$status"
}

trap cleanup EXIT

openssl_config_path="$temp_directory/openssl.cnf"
subject_text_path="$temp_directory/subject.txt"
private_key_path="$temp_directory/private-key.pem"
certificate_pem_path="$temp_directory/certificate.pem"
certificate_der_path="$temp_directory/certificate.cer"
p12_path="$temp_directory/certificate.p12"
fingerprint_path="$temp_directory/fingerprint.txt"
reimport_certificate_pem_path="$temp_directory/reimport-certificate.pem"
reimport_certificate_der_path="$temp_directory/reimport-certificate.cer"
verification_keychain_path="$temp_directory/verification.keychain-db"

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

openssl x509 -in "$certificate_pem_path" -noout -subject -nameopt RFC2253 > "$subject_text_path"
if ! grep -Fqx "subject=CN=$display_name" "$subject_text_path"; then
  fail '生成された証明書のsubjectが指定値と一致しません。'
fi

sha1_fingerprint=$(openssl dgst -sha1 -r "$certificate_der_path" | awk '{ print toupper($1) }')
sha256_fingerprint=$(openssl dgst -sha256 -r "$certificate_der_path" | awk '{ print toupper($1) }')
if [[ ! "$sha1_fingerprint" =~ ^[0-9A-F]{40}$ || ! "$sha256_fingerprint" =~ ^[0-9A-F]{64}$ ]]; then
  fail '証明書のfingerprintを計算できません。'
fi

if ! security verify-cert -c "$certificate_der_path" -r "$certificate_der_path" -p codeSign >/dev/null 2>&1; then
  fail 'securityによるCode Signing証明書の検証に失敗しました。'
fi

# macOSのsecurity importはPBES2とSHA-256 MACのP12を読めないため、PKCS#12の伝統的なPBEとSHA-1 MACで出力します
openssl pkcs12 \
  -export \
  -keypbe PBE-SHA1-3DES \
  -certpbe PBE-SHA1-3DES \
  -macalg sha1 \
  -inkey "$private_key_path" \
  -in "$certificate_pem_path" \
  -name "$display_name" \
  -out "$p12_path" \
  -passout fd:3 \
  3<<<"$p12_password"

openssl pkcs12 \
  -in "$p12_path" \
  -passin fd:3 \
  -clcerts \
  -nokeys \
  -out "$reimport_certificate_pem_path" \
  3<<<"$p12_password"
openssl x509 \
  -in "$reimport_certificate_pem_path" \
  -outform DER \
  -out "$reimport_certificate_der_path"
if ! cmp -s "$certificate_der_path" "$reimport_certificate_der_path"; then
  fail 'P12から再取得した証明書がDER CERと一致しません。'
fi

verification_keychain_password=$(openssl rand -hex 32)
if ! security create-keychain -p "$verification_keychain_password" "$verification_keychain_path" >/dev/null 2>&1; then
  fail '検証用keychainを作成できません。'
fi
if ! security import "$p12_path" \
  -k "$verification_keychain_path" \
  -T /usr/bin/codesign \
  -T /usr/bin/productbuild \
  -P "$p12_password" >/dev/null 2>&1; then
  fail 'securityによるP12の取り込みに失敗しました。'
fi
# 自己署名は信頼設定をしないためvalid扱いにはならず、identityとして見つかることだけを確認します
if ! security find-identity -p codesigning "$verification_keychain_path" |
  grep -Fq "$sha1_fingerprint \"$display_name\""; then
  fail '取り込んだP12からCode Signing identityを取得できません。'
fi

printf 'subject=CN=%s\nsha1_fingerprint=%s\nsha256_fingerprint=%s\nvalidity_days=%s\n' \
  "$display_name" "$sha1_fingerprint" "$sha256_fingerprint" "$validity_days" > "$fingerprint_path"

mv -n "$certificate_der_path" "$output_directory/certificate.cer"

mv -n "$p12_path" "$output_directory/certificate.p12"

mv -n "$fingerprint_path" "$output_directory/fingerprint.txt"

chmod 600 "$output_directory/certificate.p12"
chmod 644 "$output_directory/certificate.cer" "$output_directory/fingerprint.txt"

printf '証明書を生成しました: %s\n' "$output_directory"
