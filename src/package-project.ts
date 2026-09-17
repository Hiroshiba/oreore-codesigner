import {
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  writeFileSync
} from "node:fs";
import { join, resolve } from "node:path";
import { assertReleaseContractCurrent } from "./source-validation.js";
import type { ReleaseContract } from "./schema.js";
import { parseReleaseContract } from "./schema.js";
import { stringify as stringifyYaml } from "yaml";
import {
  assertNoSymlinkAncestors,
  assertNoSymlinkPath,
  assertRealPathWithin
} from "./path-safety.js";

export type PackageProjectTarget = "macos" | "windows-nsis" | "windows-nsis-web";

const MAC_ENTITLEMENTS_FILE = "entitlements.plist";
const MAC_ENTITLEMENTS_INHERIT_FILE = "entitlements-inherit.plist";

type CentralFile = { sourcePath: string; contents: Buffer };
type MacEntitlements = { entitlements: string; entitlementsInherit: string };

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

function assertRegularFile(path: string, message: string): void {
  assertNoSymlinkPath(path, message);
  let information;
  try {
    information = lstatSync(path);
  } catch (error) {
    throw new Error(`${message}: ${path}`, { cause: error });
  }
  if (information.isSymbolicLink() || !information.isFile()) {
    throw new Error(`${message}: ${path}`);
  }
}

function readFileContents(path: string, message: string): Buffer {
  try {
    return readFileSync(path);
  } catch (error) {
    throw new Error(`${message}: ${path}`, { cause: error });
  }
}

function readCentralFile(rootDirectory: string, centralPath: string): CentralFile {
  const sourcePath = resolve(rootDirectory, centralPath);
  assertRegularFile(sourcePath, "中央entitlementsがregular fileではありません");
  assertRealPathWithin(
    resolve(rootDirectory),
    sourcePath,
    "中央entitlementsが中央rootの外を参照しています"
  );
  return {
    sourcePath,
    contents: readFileContents(sourcePath, "中央entitlementsを読み込めません")
  };
}

function writeVerifiedCopy(file: CentralFile, outputDirectory: string, outputName: string): void {
  const outputPath = join(outputDirectory, outputName);
  try {
    writeFileSync(outputPath, file.contents, { flag: "wx" });
  } catch (error) {
    throw new Error(`entitlementsのコピー先を書き込めません: ${outputPath}`, { cause: error });
  }
  assertRegularFile(outputPath, "entitlementsのコピー先がregular fileではありません");
  const copiedContents = readFileContents(outputPath, "entitlementsのコピー先を読み込めません");
  if (!copiedContents.equals(file.contents)) {
    throw new Error(`entitlementsのコピー結果が一致しません: ${outputPath}`);
  }
  assertRegularFile(file.sourcePath, "中央entitlementsがregular fileではありません");
  const currentContents = readFileContents(file.sourcePath, "中央entitlementsを読み込めません");
  if (!currentContents.equals(file.contents)) {
    throw new Error(`中央entitlementsがコピー中に変更されました: ${file.sourcePath}`);
  }
}

function copyMacEntitlements(
  rootDirectory: string,
  contract: ReleaseContract,
  outputDirectory: string
): MacEntitlements {
  const entitlements = readCentralFile(rootDirectory, contract.application.macos.entitlements);
  const entitlementsInherit = readCentralFile(
    rootDirectory,
    contract.application.macos.entitlementsInherit
  );
  writeVerifiedCopy(entitlements, outputDirectory, MAC_ENTITLEMENTS_FILE);
  writeVerifiedCopy(entitlementsInherit, outputDirectory, MAC_ENTITLEMENTS_INHERIT_FILE);
  return {
    entitlements: MAC_ENTITLEMENTS_FILE,
    entitlementsInherit: MAC_ENTITLEMENTS_INHERIT_FILE
  };
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

function githubPublishConfiguration(contract: ReleaseContract): Record<string, unknown> {
  const { owner, repo } = repositoryParts(contract);
  return {
    provider: "github",
    owner,
    repo,
    channel: contract.application.release.channel
  };
}

function commonBuilderConfig(contract: ReleaseContract): Record<string, unknown> {
  return {
    appId: contract.application.identity.appId,
    productName: contract.application.identity.productName,
    publish: githubPublishConfiguration(contract)
  };
}

function macBuilderConfig(
  contract: ReleaseContract,
  macEntitlements: MacEntitlements
): Record<string, unknown> {
  const common = commonBuilderConfig(contract);
  const artifactName = contract.application.identity.artifactName;
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
      entitlements: macEntitlements.entitlements,
      entitlementsInherit: macEntitlements.entitlementsInherit,
      hardenedRuntime: true,
      gatekeeperAssess: false
    }
  };
}

function windowsBuilderConfig(
  contract: ReleaseContract,
  target: "windows-nsis" | "windows-nsis-web"
): Record<string, unknown> {
  const common = commonBuilderConfig(contract);
  const artifactName = contract.application.identity.artifactName;
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
      artifactName: `${artifactName}-WebSetup-\${version}.\${ext}`,
      publish: {
        ...githubPublishConfiguration(contract),
        publishAutoUpdate: false
      }
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
  let builderContents: string;
  if (targetValue === "macos") {
    const macEntitlements = copyMacEntitlements(rootDirectory, parsedContract, outputDirectory);
    builderContents = stringifyYaml(macBuilderConfig(parsedContract, macEntitlements));
  } else {
    builderContents = stringifyYaml(windowsBuilderConfig(parsedContract, targetValue));
  }
  const packageContents = JSON.stringify(packageJson(parsedContract), null, 2);
  if (packageContents === undefined) {
    throw new Error("package.jsonを生成できません");
  }
  writeNewFile(join(outputDirectory, "package.json"), `${packageContents}\n`);
  writeNewFile(join(outputDirectory, "electron-builder.yml"), builderContents);
}
