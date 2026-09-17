#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 1 ]]; then
  printf '%s\n' '使い方: emit-contract-outputs.sh prepared-contract.json' >&2
  exit 2
fi

contract_path=$1
outputs_path=${GITHUB_OUTPUT:?GITHUB_OUTPUTが必要です}

jq -e '
  .schemaVersion == 1 and
  (.appId | type == "string") and
  (.repository | type == "string") and
  (.tag | type == "string") and
  (.configDigest | type == "string") and
  (.application.repository == .repository) and
  (.application.workingDirectory | type == "string") and
  (.application.packageName | type == "string") and
  (.application.pnpmVersion | type == "string") and
  (.application.buildScripts.macos | type == "string") and
  (.application.buildScripts.windows | type == "string") and
  (.application.macos.runner | type == "string") and
  (.application.macos.architecture | type == "string") and
  (.application.windows.runner | type == "string") and
  (.application.windows.architecture | type == "string") and
  all(.. | strings; (contains("\n") | not) and (contains("\r") | not))
' "$contract_path" >/dev/null

repository=$(jq -er '.repository' "$contract_path")
owner=${repository%%/*}
repo=${repository#*/}
if [[ "$owner" == "$repository" || -z "$owner" || -z "$repo" ]]; then
  printf 'repositoryがowner/name形式ではありません: %s\n' "$repository" >&2
  exit 1
fi

{
  printf 'app_id=%s\n' "$(jq -er '.appId' "$contract_path")"
  printf 'tag=%s\n' "$(jq -er '.tag' "$contract_path")"
  printf 'repository=%s\n' "$repository"
  printf 'owner=%s\n' "$owner"
  printf 'repo=%s\n' "$repo"
  printf 'config_digest=%s\n' "$(jq -er '.configDigest' "$contract_path")"
  printf 'working_directory=%s\n' "$(jq -er '.application.workingDirectory' "$contract_path")"
  printf 'package_name=%s\n' "$(jq -er '.application.packageName' "$contract_path")"
  printf 'pnpm_version=%s\n' "$(jq -er '.application.pnpmVersion' "$contract_path")"
  printf 'macos_runner=%s\n' "$(jq -er '.application.macos.runner' "$contract_path")"
  printf 'macos_architecture=%s\n' "$(jq -er '.application.macos.architecture' "$contract_path")"
  printf 'macos_build_script=%s\n' "$(jq -er '.application.buildScripts.macos' "$contract_path")"
  printf 'macos_entitlements=%s\n' "$(jq -er '.application.macos.entitlements' "$contract_path")"
  printf 'macos_entitlements_inherit=%s\n' "$(jq -er '.application.macos.entitlementsInherit' "$contract_path")"
  printf 'windows_runner=%s\n' "$(jq -er '.application.windows.runner' "$contract_path")"
  printf 'windows_architecture=%s\n' "$(jq -er '.application.windows.architecture' "$contract_path")"
  printf 'windows_build_script=%s\n' "$(jq -er '.application.buildScripts.windows' "$contract_path")"
} >>"$outputs_path"
