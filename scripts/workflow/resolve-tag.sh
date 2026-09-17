#!/usr/bin/env bash
set -Eeuo pipefail

api_url=${GITHUB_API_URL:-https://api.github.com}
token_file=${CENTRAL_APP_TOKEN_FILE:?CENTRAL_APP_TOKEN_FILEが必要です}
repository=${CENTRAL_SOURCE_REPOSITORY:?CENTRAL_SOURCE_REPOSITORYが必要です}
tag=${CENTRAL_SOURCE_TAG:?CENTRAL_SOURCE_TAGが必要です}
output_path=${CENTRAL_TAG_OUTPUT:?CENTRAL_TAG_OUTPUTが必要です}

if [[ ! "$repository" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
  printf 'repositoryが不正です: %s\n' "$repository" >&2
  exit 1
fi
if [[ ! "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ || "$tag" == */ || "$tag" == *//* ]]; then
  printf 'tagが不正です: %s\n' "$tag" >&2
  exit 1
fi
if [[ ! -f "$token_file" || -L "$token_file" ]]; then
  printf '%s\n' 'GitHub App token fileが不正です' >&2
  exit 1
fi
token=$(<"$token_file")
if [[ -z "$token" ]]; then
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

api_get() {
  local path=$1
  local response_path=$2
  if ! curl --fail-with-body --silent --show-error --location \
    --retry 3 --retry-delay 1 --retry-all-errors \
    --header 'Accept: application/vnd.github+json' \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    --header "Authorization: Bearer $token" \
    "${api_url%/}/$path" >"$response_path"; then
    printf 'GitHub APIの取得に失敗しました: %s\n' "$path" >&2
    return 1
  fi
}

encoded_tag=$(urlencode "$tag")
reference_path="${work_directory}/reference.json"
api_get "repos/${repository}/git/ref/tags/${encoded_tag}" "$reference_path"

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
  api_get "repos/${repository}/git/tags/${current_sha,,}" "$tag_path"
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
api_get "repos/${repository}/commits/${source_sha}" "$commit_path"
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
