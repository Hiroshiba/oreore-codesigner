#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 1 ]]; then
  printf '%s\n' '使い方: extract-certificate-cn.sh certificate' >&2
  exit 2
fi

certificate_path=$1
if [[ ! -f "$certificate_path" || -L "$certificate_path" ]]; then
  printf '%s\n' '証明書pathが通常fileではありません' >&2
  exit 1
fi

subject=$(openssl x509 -in "$certificate_path" -noout -subject -nameopt RFC2253,sep_multiline)
mapfile -t common_names < <(sed -n 's/^    CN=//p' <<<"$subject")
if (( ${#common_names[@]} != 1 )) || [[ -z "${common_names[0]:-}" ]]; then
  printf '%s\n' '証明書subjectのCNが一件ではありません' >&2
  exit 1
fi
printf '%s\n' "${common_names[0]}"
