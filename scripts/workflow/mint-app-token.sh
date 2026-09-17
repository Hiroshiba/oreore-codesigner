#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 1 || ("$1" != read && "$1" != write) ]]; then
  printf '%s\n' '使い方: mint-app-token.sh read|write' >&2
  exit 2
fi

mode=$1
api_url=${GITHUB_API_URL:-https://api.github.com}
app_id=${SIGNING_APP_ID:?SIGNING_APP_IDが必要です}
private_key=${SIGNING_APP_PRIVATE_KEY:?SIGNING_APP_PRIVATE_KEYが必要です}
repository=${CENTRAL_TARGET_REPOSITORY:?CENTRAL_TARGET_REPOSITORYが必要です}
output_path=${CENTRAL_APP_TOKEN_OUTPUT:?CENTRAL_APP_TOKEN_OUTPUTが必要です}
if [[ ! "$app_id" =~ ^[0-9]+$ ]]; then
  printf '%s\n' 'SIGNING_APP_IDは整数でなければなりません' >&2
  exit 1
fi
if [[ ! "$repository" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
  printf 'repositoryが不正です: %s\n' "$repository" >&2
  exit 1
fi
if [[ -e "$output_path" || -L "$output_path" ]]; then
  printf '%s\n' 'GitHub App tokenの出力先は存在してはいけません' >&2
  exit 1
fi

work_directory=$(mktemp -d "${RUNNER_TEMP:-/tmp}/central-app-token.XXXXXX")
cleanup() {
  local status=$?
  local cleanup_status=0
  if ! rm -rf -- "$work_directory"; then
    printf '%s\n' 'GitHub App token用一時ディレクトリの削除に失敗しました' >&2
    cleanup_status=1
  fi
  if (( status != 0 )); then
    exit "$status"
  fi
  exit "$cleanup_status"
}
trap cleanup EXIT

key_path="${work_directory}/private-key.pem"
printf '%s\n' "$private_key" >"$key_path"
chmod 600 "$key_path"
unset private_key

base64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

issued_at=$(date +%s)
expires_at=$((issued_at + 540))
header=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | base64url)
payload=$(jq -cn --arg iss "$app_id" --argjson iat "$issued_at" --argjson exp "$expires_at" \
  '{iat: $iat, exp: $exp, iss: ($iss | tonumber)}' | base64url)
unsigned="${header}.${payload}"
signature=$(printf '%s' "$unsigned" | openssl dgst -sha256 -sign "$key_path" | base64url)
jwt="${unsigned}.${signature}"

installation_path="${work_directory}/installation.json"
if ! curl --fail-with-body --silent --show-error --location \
  --retry 3 --retry-delay 1 --retry-all-errors \
  --header 'Accept: application/vnd.github+json' \
  --header 'X-GitHub-Api-Version: 2022-11-28' \
  --header "Authorization: Bearer $jwt" \
  "${api_url%/}/repos/${repository}/installation" >"$installation_path"; then
  printf '%s\n' 'GitHub App installationを取得できません' >&2
  exit 1
fi
installation_id=$(jq -er '.id | numbers' "$installation_path")

permissions='read'
if [[ "$mode" == write ]]; then
  permissions='write'
fi
request_path="${work_directory}/request.json"
jq -n --arg repo "${repository#*/}" --arg permission "$permissions" \
  '{repositories: [$repo], permissions: {contents: $permission}}' >"$request_path"
token_response_path="${work_directory}/token.json"
if ! curl --fail-with-body --silent --show-error --location \
  --retry 3 --retry-delay 1 --retry-all-errors \
  --request POST \
  --header 'Accept: application/vnd.github+json' \
  --header 'X-GitHub-Api-Version: 2022-11-28' \
  --header "Authorization: Bearer $jwt" \
  --header 'Content-Type: application/json' \
  --data-binary "@$request_path" \
  "${api_url%/}/app/installations/${installation_id}/access_tokens" >"$token_response_path"; then
  printf '%s\n' 'GitHub App installation tokenを発行できません' >&2
  exit 1
fi
token=$(jq -er '.token | strings | select(length > 0)' "$token_response_path")
actual_permission=$(jq -er '.permissions.contents' "$token_response_path")
if [[ "$actual_permission" != "$permissions" ]]; then
  printf 'GitHub App tokenのContents権限が想定外です: %s\n' "$actual_permission" >&2
  exit 1
fi

mkdir -p -- "$(dirname -- "$output_path")"
umask 077
printf '%s\n' "$token" >"$output_path"
