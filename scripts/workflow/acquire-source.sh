#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 4 ]]; then
  printf '%s\n' '使い方: acquire-source.sh contract.json source-artifact-dir source.tar source-manifest.json' >&2
  exit 2
fi

contract_path=$1
artifact_directory=$2
archive_path=$3
manifest_path=$4
central_root=${GITHUB_WORKSPACE:?GITHUB_WORKSPACEが必要です}
token=${CENTRAL_APP_TOKEN:?CENTRAL_APP_TOKENが必要です}
if [[ -z "$token" || "$token" == *$'\n'* || "$token" == *$'\r'* ]]; then
  printf '%s\n' 'GitHub App tokenが空またはtransport上不正です' >&2
  exit 1
fi

repository=$(jq -er '.repository' "$contract_path")
tag=$(jq -er '.tag' "$contract_path")
app_id=$(jq -er '.appId' "$contract_path")
config_digest=$(jq -er '.configDigest' "$contract_path")

work_directory=$(mktemp -d "${RUNNER_TEMP:-/tmp}/central-acquire-source.XXXXXX")
cleanup() {
  local status=$?
  local cleanup_status=0
  if ! rm -rf -- "$work_directory"; then
    printf '%s\n' 'source取得用一時ディレクトリの削除に失敗しました' >&2
    cleanup_status=1
  fi
  if (( status != 0 )); then
    exit "$status"
  fi
  exit "$cleanup_status"
}
trap cleanup EXIT

resolved_path="${work_directory}/resolved-tag.json"
CENTRAL_APP_TOKEN="$token" \
  CENTRAL_SOURCE_REPOSITORY="$repository" \
  CENTRAL_SOURCE_TAG="$tag" \
  CENTRAL_TAG_OUTPUT="$resolved_path" \
  "$central_root/scripts/workflow/resolve-tag.sh"
source_sha=$(jq -er '.sourceSha' "$resolved_path")
commit_timestamp=$(jq -er '.commitTimestamp' "$resolved_path")
if [[ ! "$source_sha" =~ ^[0-9a-fA-F]{40}$ || ! "$commit_timestamp" =~ ^[0-9]+$ ]]; then
  printf '%s\n' 'tag解決結果が不正です' >&2
  exit 1
fi

checkout_directory="${work_directory}/source"
git init --quiet "$checkout_directory"
git -C "$checkout_directory" config submodule.recurse false
git -C "$checkout_directory" remote add origin "https://github.com/${repository}.git"
if ! GIT_HTTP_EXTRAHEADER="Authorization: Bearer ${token}" \
  GIT_LFS_SKIP_SMUDGE=1 \
  git -C "$checkout_directory" fetch --no-tags --filter=blob:none --depth=1 origin "$source_sha"; then
  printf 'source SHAの取得に失敗しました: %s\n' "$source_sha" >&2
  exit 1
fi
git -C "$checkout_directory" checkout --quiet --detach FETCH_HEAD
checked_out_sha=$(git -C "$checkout_directory" rev-parse HEAD)
if [[ "${checked_out_sha,,}" != "${source_sha,,}" ]]; then
  printf 'checkout後のHEADが一致しません: %s\n' "$checked_out_sha" >&2
  exit 1
fi

if git -C "$checkout_directory" ls-tree -r --name-only "$source_sha" | grep -Eq '(^|/)\.gitmodules$'; then
  printf '%s\n' '.gitmodulesは中央source契約でサポートしていません' >&2
  exit 1
fi
if git -C "$checkout_directory" ls-tree -r --full-tree "$source_sha" | awk '$1 == "160000" { found = 1 } END { exit found ? 0 : 1 }'; then
  printf '%s\n' 'submodule entryは中央source契約でサポートしていません' >&2
  exit 1
fi
while IFS= read -r -d '' source_path; do
  attribute=$(git -C "$checkout_directory" check-attr --cached filter -- "$source_path")
  if [[ "$attribute" == *': lfs' ]]; then
    printf 'Git LFS filterは中央source契約でサポートしていません: %s\n' "$source_path" >&2
    exit 1
  fi
done < <(git -C "$checkout_directory" ls-files -z)

mkdir -p -- "$artifact_directory" "$(dirname -- "$archive_path")" "$(dirname -- "$manifest_path")"
(cd "$central_root" && env -u CENTRAL_APP_TOKEN pnpm exec tsx src/cli.ts validate-source \
  --contract "$contract_path" --source-directory "$checkout_directory" \
  --output "$artifact_directory/release-contract.json")
copy_if_different() {
  local source_path=$1
  local destination_path=$2
  if [[ "$(realpath -m -- "$source_path")" != "$(realpath -m -- "$destination_path")" ]]; then
    cp -- "$source_path" "$destination_path"
  fi
}
env -u CENTRAL_APP_TOKEN GIT_LFS_SKIP_SMUDGE=1 \
git -C "$checkout_directory" archive \
  --format=tar \
  --prefix=source/ \
  --mtime="@${commit_timestamp}" \
  "$source_sha" >"$archive_path"
archive_listing="${work_directory}/archive-list.txt"
tar -tf "$archive_path" >"$archive_listing"
if grep -Eq '(^|/)\.git(/|$)|(^|/)\.gitmodules$' "$archive_listing"; then
  printf '%s\n' 'source archiveにGit metadataが含まれています' >&2
  exit 1
fi
copy_if_different "$archive_path" "$artifact_directory/source.tar"

jq -n \
  --arg appId "$app_id" \
  --arg repository "$repository" \
  --arg tag "$tag" \
  --arg sourceSha "${source_sha,,}" \
  --arg configDigest "$config_digest" \
  --argjson commitTimestamp "$commit_timestamp" \
  '{schemaVersion: 1, appId: $appId, repository: $repository, tag: $tag, sourceSha: $sourceSha, commitTimestamp: $commitTimestamp, configDigest: $configDigest}' \
  >"$manifest_path"
copy_if_different "$manifest_path" "$artifact_directory/source-manifest.json"
