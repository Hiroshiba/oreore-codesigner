import { parseGitTag, parseSemVer, type ReleaseConfig } from "./schema.js";

function prereleaseIdentifiers(version: string): string[] {
  const withoutBuild = version.split("+")[0];
  if (withoutBuild === undefined) {
    throw new Error("versionのcoreがありません");
  }
  const parts = withoutBuild.split("-");
  if (parts.length === 1) {
    return [];
  }
  const identifierPart = parts.slice(1).join("-");
  return identifierPart.split(".");
}

function validateChannel(release: ReleaseConfig, version: string): void {
  const prerelease = prereleaseIdentifiers(version);
  if (release.channel === "latest" && prerelease.length > 0) {
    throw new Error("latest channelにはprerelease versionを指定できません");
  }
  if (release.channel === "beta" && (prerelease.length === 0 || prerelease[0] !== "beta")) {
    throw new Error("beta channelのprerelease先頭識別子はbetaでなければなりません");
  }
}

/** prepare段階でtagがrelease policyに沿うことを検証します。 */
export function validateTagForPrepare(release: ReleaseConfig, tag: string): void {
  parseGitTag(tag);
  if (release.tagStrategy.type === "rolling") {
    if (tag !== release.tagStrategy.tag) {
      throw new Error(`rolling tagは固定値でなければなりません: ${release.tagStrategy.tag}`);
    }
    return;
  }
  if (!tag.startsWith(release.tagStrategy.prefix)) {
    throw new Error("versioned tagのprefixが一致しません");
  }
  const version = tag.slice(release.tagStrategy.prefix.length);
  if (version.length === 0) {
    throw new Error("versioned tagにversionがありません");
  }
  parseSemVer(version);
}

/** sourceのpackage versionとtag、channelの一致を検証します。 */
export function validateReleaseTag(release: ReleaseConfig, tag: string, version: string): void {
  parseGitTag(tag);
  const parsedVersion = parseSemVer(version);
  if (release.tagStrategy.type === "rolling") {
    if (tag !== release.tagStrategy.tag) {
      throw new Error(`rolling tagは固定値でなければなりません: ${release.tagStrategy.tag}`);
    }
  } else if (tag !== `${release.tagStrategy.prefix}${parsedVersion}`) {
    throw new Error("versioned tagはprefixとpackage versionの完全一致でなければなりません");
  }
  validateChannel(release, parsedVersion);
}
