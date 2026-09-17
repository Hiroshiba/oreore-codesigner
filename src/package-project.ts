import { existsSync, lstatSync, mkdirSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { assertReleaseContractCurrent } from "./source-validation.js";
import type { ReleaseContract } from "./schema.js";
import { parseReleaseContract } from "./schema.js";
import { stringify as stringifyYaml } from "yaml";
import { assertNoSymlinkAncestors } from "./path-safety.js";

export type PackageProjectTarget = "macos" | "windows-nsis" | "windows-nsis-web";

function assertEmptyDirectory(path: string): void {
  assertNoSymlinkAncestors(path, "output-directoryの親pathにsymlinkを指定できません");
  if (!existsSync(path)) {
    mkdirSync(path, { recursive: true });
    return;
  }
  const information = lstatSync(path);
  if (information.isSymbolicLink() || !information.isDirectory()) {
    throw new Error(`output-directoryが空のディレクトリではありません: ${path}`);
  }
  if (readdirSync(path).length > 0) {
    throw new Error(`output-directoryは空でなければなりません: ${path}`);
  }
}

function packageJson(contract: ReleaseContract): Record<string, unknown> {
  return {
    name: contract.application.packageName,
    version: contract.version,
    private: true,
    repository: {
      type: "git",
      url: `https://github.com/${contract.repository}.git`
    }
  };
}

function repositoryParts(contract: ReleaseContract): { owner: string; repo: string } {
  const parts = contract.repository.split("/");
  const owner = parts[0];
  const repo = parts[1];
  if (parts.length !== 2 || owner === undefined || repo === undefined) {
    throw new Error("repositoryはowner/name形式でなければなりません");
  }
  return { owner, repo };
}

function commonBuilderConfig(contract: ReleaseContract): Record<string, unknown> {
  const { owner, repo } = repositoryParts(contract);
  return {
    appId: contract.application.identity.appId,
    productName: contract.application.identity.productName,
    publish: {
      provider: "github",
      owner,
      repo,
      channel: contract.application.release.channel
    }
  };
}

function builderConfig(
  contract: ReleaseContract,
  target: PackageProjectTarget
): Record<string, unknown> {
  const common = commonBuilderConfig(contract);
  const artifactName = contract.application.identity.artifactName;
  if (target === "macos") {
    return {
      ...common,
      mac: {
        target: [
          {
            target: "zip",
            arch: [contract.application.macos.architecture]
          },
          {
            target: "dmg",
            arch: [contract.application.macos.architecture]
          }
        ],
        artifactName: `${artifactName}-\${version}-\${arch}.\${ext}`,
        entitlements: contract.application.macos.entitlements,
        entitlementsInherit: contract.application.macos.entitlementsInherit,
        hardenedRuntime: true,
        gatekeeperAssess: false
      }
    };
  }
  const windows = {
    target: [
      {
        target: target === "windows-nsis" ? "nsis" : "nsis-web",
        arch: [contract.application.windows.architecture]
      }
    ],
    executableName: contract.application.windows.executableName,
    publisherName: contract.application.windows.publisherName
  };
  if (target === "windows-nsis") {
    return {
      ...common,
      win: windows,
      nsis: {
        guid: contract.application.windows.guid,
        artifactName: `${artifactName}-Setup-\${version}.\${ext}`
      }
    };
  }
  return {
    ...common,
    win: windows,
    nsisWeb: {
      guid: contract.application.windows.guid,
      artifactName: `${artifactName}-WebSetup-\${version}.\${ext}`
    }
  };
}

function writeNewFile(path: string, contents: string): void {
  writeFileSync(path, contents, { encoding: "utf8", flag: "wx" });
}

function isPackageProjectTarget(value: string): value is PackageProjectTarget {
  return value === "macos" || value === "windows-nsis" || value === "windows-nsis-web";
}

/** prepackaged用の一target package projectを生成します。 */
export function createPackageProject(
  rootDirectory: string,
  releaseContractValue: unknown,
  target: PackageProjectTarget,
  outputDirectory: string
): void;
export function createPackageProject(
  releaseContractValue: unknown,
  target: PackageProjectTarget,
  outputDirectory: string
): void;
export function createPackageProject(
  first: unknown,
  second: unknown,
  third: string,
  fourth?: string
): void {
  let rootDirectory: string;
  let releaseContractValue: unknown;
  let targetValue: unknown;
  let outputDirectory: string;
  if (fourth === undefined) {
    rootDirectory = process.cwd();
    releaseContractValue = first;
    targetValue = second;
    outputDirectory = third;
  } else {
    if (typeof first !== "string") {
      throw new Error("root directoryが不正です");
    }
    rootDirectory = first;
    releaseContractValue = second;
    targetValue = third;
    outputDirectory = fourth;
  }
  if (typeof targetValue !== "string" || !isPackageProjectTarget(targetValue)) {
    throw new Error("targetはmacos、windows-nsis、windows-nsis-webのいずれかです");
  }
  const releaseContract = assertReleaseContractCurrent(rootDirectory, releaseContractValue);
  const parsedContract = parseReleaseContract(releaseContract);
  assertEmptyDirectory(outputDirectory);
  const packageContents = JSON.stringify(packageJson(parsedContract), null, 2);
  if (packageContents === undefined) {
    throw new Error("package.jsonを生成できません");
  }
  const builderContents = stringifyYaml(builderConfig(parsedContract, targetValue));
  writeNewFile(join(outputDirectory, "package.json"), `${packageContents}\n`);
  writeNewFile(join(outputDirectory, "electron-builder.yml"), builderContents);
}
