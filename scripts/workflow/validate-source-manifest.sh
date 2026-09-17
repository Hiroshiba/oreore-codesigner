#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 2 ]]; then
  printf '%s\n' '使い方: validate-source-manifest.sh prepared-contract.json source-manifest.json' >&2
  exit 2
fi

contract_path=$1
manifest_path=$2
jq -e --arg repository "$(jq -er '.repository' "$contract_path")" \
  --arg tag "$(jq -er '.tag' "$contract_path")" \
  --arg app_id "$(jq -er '.appId' "$contract_path")" \
  --arg config_digest "$(jq -er '.configDigest' "$contract_path")" \
  '.schemaVersion == 1 and .appId == $app_id and .repository == $repository and .tag == $tag and
   (.sourceSha | type == "string" and test("^[0-9a-fA-F]{40}$")) and
   (.commitTimestamp | type == "number" and floor == .) and .configDigest == $config_digest' \
  "$manifest_path" >/dev/null
