#!/usr/bin/env bash
set -Eeuo pipefail

api_url=${GITHUB_API_URL:-https://api.github.com}
token=${CENTRAL_APP_TOKEN:?CENTRAL_APP_TOKENが必要です}
repository=${CENTRAL_SOURCE_REPOSITORY:?CENTRAL_SOURCE_REPOSITORYが必要です}
tag=${CENTRAL_SOURCE_TAG:?CENTRAL_SOURCE_TAGが必要です}
output_path=${CENTRAL_TAG_OUTPUT:?CENTRAL_TAG_OUTPUTが必要です}

if [[ "$repository" == *$'\n'* || "$repository" == *$'\r'* || "$tag" == *$'\n'* || "$tag" == *$'\r'* ]]; then
  printf '%s\n' 'repositoryまたはtagにtransport上の改行があります' >&2
  exit 1
fi
if [[ -z "$token" || "$token" == *$'\n'* || "$token" == *$'\r'* ]]; then
  printf '%s\n' 'GitHub App tokenが空です' >&2
  exit 1
fi

work_directory=$(mktemp -d "${RUNNER_TEMP:-/tmp}/central-resolve-tag.XXXXXX")
cleanup() {
  local status=$?
  local cleanup_status=0
  if ! rm -rf -- "$work_directory"; then
    printf '%s\n' 'tag解決用一時ディレクトリの削除に失敗しました' >&2
    cleanup_status=1
  fi
  if (( status != 0 )); then
    exit "$status"
  fi
  exit "$cleanup_status"
}
trap cleanup EXIT

urlencode() {
  jq -nr --arg value "$1" '$value | @uri'
}

owner=${repository%%/*}
repo=${repository#*/}
if [[ "$owner" == "$repository" || -z "$owner" || -z "$repo" ]]; then
  printf '%s\n' 'repositoryをAPI pathへ変換できません' >&2
  exit 1
fi
encoded_owner=$(urlencode "$owner")
encoded_repo=$(urlencode "$repo")
encoded_tag=$(urlencode "$tag")
auth_header_path="${work_directory}/authorization-header.txt"
umask 077
printf 'Authorization: Bearer %s\n' "$token" >"$auth_header_path"

api_get() {
  local path=$1
  local response_path=$2
  local attempt
  local response_code
  local curl_status
  for attempt in 1 2 3; do
    curl_status=0
    response_code=$(curl --silent --show-error --location \
      --header 'Accept: application/vnd.github+json' \
      --header 'X-GitHub-Api-Version: 2022-11-28' \
      --header "@$auth_header_path" \
      --output "$response_path" --write-out '%{http_code}' "${api_url%/}/$path") || curl_status=$?
    if (( curl_status == 0 )) && [[ "$response_code" =~ ^2[0-9][0-9]$ ]]; then
      return 0
    fi
    if (( curl_status != 0 )); then
      response_code=000
    fi
    if [[ "$response_code" != 000 && ! "$response_code" =~ ^429$ && ! "$response_code" =~ ^5[0-9][0-9]$ ]] || (( attempt == 3 )); then
      printf 'GitHub APIの取得に失敗しました: %s HTTP %s\n' "$path" "$response_code" >&2
      return 1
    fi
    sleep "$attempt"
  done
  return 1
}

reference_path="${work_directory}/reference.json"
api_get "repos/${encoded_owner}/${encoded_repo}/git/ref/tags/${encoded_tag}" "$reference_path"

current_type=$(jq -er '.object.type' "$reference_path")
current_sha=$(jq -er '.object.sha' "$reference_path")
if [[ ! "$current_sha" =~ ^[0-9a-fA-F]{40}$ ]]; then
  printf 'tag objectのSHAが40桁ではありません\n' >&2
  exit 1
fi

declare -a seen_shas=()
source_sha=''
for depth in 0 1 2 3 4 5 6 7 8; do
  for seen_sha in "${seen_shas[@]}"; do
    if [[ "${seen_sha,,}" == "${current_sha,,}" ]]; then
      printf '%s\n' 'annotated tagの循環を検出しました' >&2
      exit 1
    fi
  done
  seen_shas+=("${current_sha,,}")

  if [[ "$current_type" == commit ]]; then
    source_sha=${current_sha,,}
    break
  fi
  if [[ "$current_type" != tag ]]; then
    printf 'tagがcommitまたはannotated tagではありません: %s\n' "$current_type" >&2
    exit 1
  fi
  if (( depth == 8 )); then
    printf '%s\n' 'annotated tagの参照が8段を超えました' >&2
    exit 1
  fi

  tag_path="${work_directory}/tag-${depth}.json"
  api_get "repos/${encoded_owner}/${encoded_repo}/git/tags/${current_sha,,}" "$tag_path"
  current_type=$(jq -er '.object.type' "$tag_path")
  current_sha=$(jq -er '.object.sha' "$tag_path")
  if [[ ! "$current_sha" =~ ^[0-9a-fA-F]{40}$ ]]; then
    printf 'annotated tag objectのSHAが40桁ではありません\n' >&2
    exit 1
  fi
done

if [[ -z "$source_sha" ]]; then
  printf '%s\n' 'commit SHAを解決できませんでした' >&2
  exit 1
fi

commit_path="${work_directory}/commit.json"
api_get "repos/${encoded_owner}/${encoded_repo}/commits/${source_sha}" "$commit_path"
commit_date=$(jq -er '.commit.committer.date' "$commit_path")
commit_timestamp=$(date --utc --date="$commit_date" '+%s')
if [[ ! "$commit_timestamp" =~ ^[0-9]+$ ]]; then
  printf '%s\n' 'commit timestampが整数ではありません' >&2
  exit 1
fi

mkdir -p -- "$(dirname -- "$output_path")"
jq -n \
  --arg repository "$repository" \
  --arg tag "$tag" \
  --arg sourceSha "$source_sha" \
  --argjson commitTimestamp "$commit_timestamp" \
  '{schemaVersion: 1, repository: $repository, tag: $tag, sourceSha: $sourceSha, commitTimestamp: $commitTimestamp}' \
  >"$output_path"
