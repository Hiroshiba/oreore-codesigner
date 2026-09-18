#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 4 ]]; then
  printf '%s\n' '使い方: acquire-source.sh repository tag source.tar github-output-path' >&2
  exit 2
fi

repository=$1
tag=$2
archive_path=$3
github_output_path=$4

if [[ ! "$repository" =~ ^[A-Za-z0-9]([A-Za-z0-9_.-]*[A-Za-z0-9])?/[A-Za-z0-9]([A-Za-z0-9_.-]*[A-Za-z0-9])?$ ]]; then
  printf '%s\n' 'repositoryはowner/name形式でなければなりません' >&2
  exit 1
fi
if [[ -z "$tag" || "$tag" == *$'\n'* || "$tag" == *$'\r'* ]]; then
  printf '%s\n' 'tagが不正です' >&2
  exit 1
fi
if [[ -z "$archive_path" || -z "$github_output_path" ]]; then
  printf '%s\n' '出力pathを空にできません' >&2
  exit 1
fi

token=${GH_TOKEN:-}
if [[ -z "$token" || "$token" == *$'\n'* || "$token" == *$'\r'* ]]; then
  printf '%s\n' 'GH_TOKENが空またはtransport上不正です' >&2
  exit 1
fi
unset GH_TOKEN

owner=${repository%%/*}
repo=${repository#*/}
work_directory=$(mktemp -d "${RUNNER_TEMP:-/tmp}/central-acquire-source.XXXXXX")
cleanup() {
  local status=$?
  local cleanup_status=0
  trap - EXIT
  if ! rm -rf -- "$work_directory"; then
    printf '%s\n' 'source取得用一時directoryの削除に失敗しました' >&2
    cleanup_status=1
  fi
  if (( status != 0 )); then
    if (( cleanup_status != 0 )); then
      exit 1
    fi
    exit "$status"
  fi
  exit "$cleanup_status"
}
trap cleanup EXIT

token_path="$work_directory/token"
askpass_path="$work_directory/askpass"
umask 077
printf '%s' "$token" >"$token_path"
unset token
cat >"$askpass_path" <<'EOF'
#!/usr/bin/env sh
set -eu
case "${1-}" in
  *Username*) printf '%s\n' 'x-access-token' ;;
  *Password*) cat -- "${GIT_TOKEN_PATH:?}" ;;
  *) exit 1 ;;
esac
EOF
chmod 700 "$askpass_path"

checkout_directory="$work_directory/source"
git init --quiet "$checkout_directory"
git -C "$checkout_directory" remote add origin "https://github.com/${repository}.git"
tag_ref="refs/tags/$tag"
if ! git check-ref-format "$tag_ref" >/dev/null; then
  printf '%s\n' 'tagがGit refとして不正です' >&2
  exit 1
fi

if ! GIT_ASKPASS="$askpass_path" GIT_TOKEN_PATH="$token_path" GIT_TERMINAL_PROMPT=0 GIT_LFS_SKIP_SMUDGE=1 \
  git -c credential.helper= -C "$checkout_directory" fetch --no-tags --depth=1 origin "$tag_ref:$tag_ref"; then
  printf '%s\n' '対象sourceのtag取得に失敗しました' >&2
  exit 1
fi

if ! source_sha=$(git -C "$checkout_directory" rev-parse --verify "${tag_ref}^{commit}"); then
  printf '%s\n' 'tagからcommit SHAを解決できませんでした' >&2
  exit 1
fi
source_sha=${source_sha,,}
if [[ ! "$source_sha" =~ ^[0-9a-f]{40}$ ]]; then
  printf '%s\n' 'source SHAが40桁ではありません' >&2
  exit 1
fi
if ! commit_timestamp=$(git -C "$checkout_directory" show -s --format=%ct "$source_sha"); then
  printf '%s\n' 'commit timestampを取得できませんでした' >&2
  exit 1
fi
if [[ ! "$commit_timestamp" =~ ^[0-9]+$ ]]; then
  printf '%s\n' 'commit timestampが整数ではありません' >&2
  exit 1
fi

if ! git -C "$checkout_directory" checkout --quiet --detach "$source_sha"; then
  printf '%s\n' 'source checkoutに失敗しました' >&2
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

mkdir -p -- "$(dirname -- "$archive_path")" "$(dirname -- "$github_output_path")"
if [[ -e "$archive_path" || -L "$archive_path" ]]; then
  printf '%s\n' 'source archiveは開始時に存在してはいけません' >&2
  exit 1
fi
if ! GIT_LFS_SKIP_SMUDGE=1 git -C "$checkout_directory" archive \
  --format=tar --prefix=source/ --mtime="@${commit_timestamp}" "$source_sha" >"$archive_path"; then
  printf '%s\n' 'source archiveの生成に失敗しました' >&2
  exit 1
fi
if [[ ! -f "$archive_path" || -L "$archive_path" || ! -s "$archive_path" ]]; then
  printf '%s\n' 'source archiveが通常fileではありません' >&2
  exit 1
fi
if ! archive_sha=$(git get-tar-commit-id <"$archive_path"); then
  printf '%s\n' 'source archiveのcommit SHAを確認できません' >&2
  exit 1
fi
archive_sha=${archive_sha,,}
if [[ "$archive_sha" != "$source_sha" ]]; then
  printf '%s\n' 'source archiveのcommit SHAが一致しません' >&2
  exit 1
fi
archive_listing="$work_directory/archive-list.txt"
if ! tar -tf "$archive_path" >"$archive_listing"; then
  printf '%s\n' 'source archiveの内容を確認できません' >&2
  exit 1
fi
if grep -Eq '(^|/)\.git(/|$)|(^|/)\.gitmodules$' "$archive_listing"; then
  printf '%s\n' 'source archiveにGit metadataが含まれています' >&2
  exit 1
fi

if [[ -L "$github_output_path" ]]; then
  printf '%s\n' 'GitHub output pathにsymlinkを指定できません' >&2
  exit 1
fi
printf 'owner=%s\nrepo=%s\nsource_sha=%s\ncommit_timestamp=%s\n' \
  "$owner" "$repo" "$source_sha" "$commit_timestamp" >>"$github_output_path"
