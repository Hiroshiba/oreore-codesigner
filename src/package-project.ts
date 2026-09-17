import {
  lstatSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  writeFileSync
} from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { stringify as stringifyYaml } from "yaml";
import { assertReleaseContractCurrent } from "./source-validation.js";
import type { ReleaseContract } from "./schema.js";
import { parseReleaseContract } from "./schema.js";
import {
  assertNoSymlinkAncestors,
  assertNoSymlinkPath,
  assertRealPathWithin
} from "./path-safety.js";

export type PackageProjectTarget = "macos" | "windows-nsis" | "windows-nsis-web";

const MAC_ENTITLEMENTS_FILE = "entitlements.plist";
const MAC_ENTITLEMENTS_INHERIT_FILE = "entitlements-inherit.plist";

type CentralFile = { sourcePath: string; contents: Buffer };
type MacEntitlements = {
  entitlementsPath: string;
  entitlementsInheritPath: string;
  entitlementsFile: CentralFile;
  entitlementsInheritFile: CentralFile;
};
type ExpectedProjectFile = { name: string; contents: Buffer };
type DirectoryIdentity = { device: bigint; inode: bigint };
type OutputTarget = {
  requestedPath: string;
  parentRealPath: string;
  parentIdentity: DirectoryIdentity;
  outputPath: string;
};
type CreatedOutput = { target: OutputTarget; identity: DirectoryIdentity };

function isErrnoException(error: unknown): error is NodeJS.ErrnoException {
  return error instanceof Error && "code" in error && typeof error.code === "string";
}

function assertDirectoryIdentity(path: string, identity: DirectoryIdentity, message: string): void {
  assertNoSymlinkPath(path, message);
  let information;
  try {
    information = lstatSync(path, { bigint: true });
  } catch (error) {
    throw new Error(`${message}: ${path}`, { cause: error });
  }
  if (
    !information.isDirectory() ||
    information.dev !== identity.device ||
    information.ino !== identity.inode
  ) {
    throw new Error(`${message}: ${path}`);
  }
}

function assertOutputAbsent(path: string): void {
  try {
    lstatSync(path, { bigint: true });
  } catch (error) {
    if (isErrnoException(error) && error.code === "ENOENT") {
      return;
    }
    throw new Error(`output-directoryを確認できません: ${path}`, { cause: error });
  }
  throw new Error(`output-directoryは開始時に存在してはいけません: ${path}`);
}

function prepareOutputTarget(path: string): OutputTarget {
  const requestedPath = resolve(path);
  const parentPath = dirname(requestedPath);
  assertNoSymlinkAncestors(requestedPath, "output-directoryの親pathにsymlinkを指定できません");
  assertNoSymlinkPath(parentPath, "output-directoryの親pathにsymlinkを指定できません");
  let parentRealPath: string;
  try {
    parentRealPath = realpathSync(parentPath);
  } catch (error) {
    throw new Error(`output-directoryの親pathを解決できません: ${parentPath}`, { cause: error });
  }
  assertNoSymlinkPath(parentRealPath, "output-directoryの物理親pathが不正です");
  let parentInformation;
  try {
    parentInformation = lstatSync(parentRealPath, { bigint: true });
  } catch (error) {
    throw new Error(`output-directoryの親pathを確認できません: ${parentRealPath}`, {
      cause: error
    });
  }
  if (!parentInformation.isDirectory()) {
    throw new Error(`output-directoryの親pathがディレクトリではありません: ${parentRealPath}`);
  }
  const outputPath = join(parentRealPath, basename(requestedPath));
  assertOutputAbsent(outputPath);
  return {
    requestedPath,
    parentRealPath,
    parentIdentity: { device: parentInformation.dev, inode: parentInformation.ino },
    outputPath
  };
}

function assertCreatedOutput(output: CreatedOutput): void {
  assertDirectoryIdentity(
    output.target.parentRealPath,
    output.target.parentIdentity,
    "output-directoryの親pathが途中で差し替えられました"
  );
  assertNoSymlinkPath(output.target.outputPath, "output-directoryにsymlinkを指定できません");
  let information;
  try {
    information = lstatSync(output.target.outputPath, { bigint: true });
  } catch (error) {
    throw new Error(`output-directoryを確認できません: ${output.target.outputPath}`, {
      cause: error
    });
  }
  if (
    !information.isDirectory() ||
    information.dev !== output.identity.device ||
    information.ino !== output.identity.inode
  ) {
    throw new Error(`output-directoryが途中で差し替えられました: ${output.target.outputPath}`);
  }
  if (process.platform !== "win32" && (information.mode & 0o777n) !== 0o700n) {
    throw new Error(`output-directoryの権限が不正です: ${output.target.outputPath}`);
  }
}

function createOutputDirectory(target: OutputTarget): CreatedOutput {
  try {
    mkdirSync(target.outputPath, { mode: 0o700 });
  } catch (error) {
    throw new Error(`output-directoryを作成できません: ${target.outputPath}`, { cause: error });
  }
  let information;
  try {
    information = lstatSync(target.outputPath, { bigint: true });
  } catch (error) {
    throw new Error(`作成したoutput-directoryを確認できません: ${target.outputPath}`, {
      cause: error
    });
  }
  const output: CreatedOutput = {
    target,
    identity: { device: information.dev, inode: information.ino }
  };
  try {
    assertCreatedOutput(output);
    assertRealPathWithin(
      target.parentRealPath,
      target.outputPath,
      "output-directoryが親pathの外を参照しています"
    );
    return output;
  } catch (error) {
    cleanupCreatedOutput(error, output);
  }
}

function assertRegularFile(path: string, message: string): void {
  assertNoSymlinkPath(path, message);
  let information;
  try {
    information = lstatSync(path, { bigint: true });
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

function writeExclusiveFile(output: CreatedOutput, name: string, contents: Buffer): void {
  assertCreatedOutput(output);
  const path = join(output.target.outputPath, name);
  try {
    writeFileSync(path, contents, { flag: "wx", mode: 0o600 });
  } catch (error) {
    throw new Error(`package projectのfileを書き込めません: ${path}`, { cause: error });
  }
  assertRegularFile(path, "package projectのfileがregular fileではありません");
  const writtenContents = readFileContents(path, "package projectのfileを読み込めません");
  if (!writtenContents.equals(contents)) {
    throw new Error(`package projectのfileのbytesが一致しません: ${path}`);
  }
  assertCreatedOutput(output);
}

function verifyProjectFiles(output: CreatedOutput, expectedFiles: ExpectedProjectFile[]): void {
  assertCreatedOutput(output);
  const expectedNames = new Set(expectedFiles.map((file) => file.name));
  if (expectedNames.size !== expectedFiles.length) {
    throw new Error("package projectのfile名が重複しています");
  }
  let entries: string[];
  try {
    entries = readdirSync(output.target.outputPath);
  } catch (error) {
    throw new Error(`package projectのdirectoryを読み込めません: ${output.target.outputPath}`, {
      cause: error
    });
  }
  if (entries.length !== expectedFiles.length) {
    throw new Error(`package projectのfile件数が一致しません: ${output.target.outputPath}`);
  }
  for (const entry of entries) {
    if (!expectedNames.has(entry)) {
      throw new Error(`想定外のpackage project fileです: ${entry}`);
    }
  }
  for (const expectedFile of expectedFiles) {
    const path = join(output.target.outputPath, expectedFile.name);
    assertRegularFile(path, "package projectのfileがregular fileではありません");
    const contents = readFileContents(path, "package projectのfileを読み込めません");
    if (!contents.equals(expectedFile.contents)) {
      throw new Error(`package projectのfileのbytesが一致しません: ${path}`);
    }
  }
  assertCreatedOutput(output);
}

function removeCreatedOutput(output: CreatedOutput): void {
  assertCreatedOutput(output);
  try {
    rmSync(output.target.outputPath, { recursive: true });
  } catch (error) {
    throw new Error(`作成したoutput-directoryを削除できません: ${output.target.outputPath}`, {
      cause: error
    });
  }
  assertOutputAbsent(output.target.outputPath);
}

function cleanupCreatedOutput(error: unknown, output: CreatedOutput): never {
  try {
    removeCreatedOutput(output);
  } catch (cleanupError) {
    throw new AggregateError(
      [error, cleanupError],
      "package project生成に失敗し作成したoutput-directoryも削除できません"
    );
  }
  throw error;
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

function readMacEntitlements(
  rootDirectory: string,
  contract: ReleaseContract,
  outputPath: string
): MacEntitlements {
  const entitlementsFile = readCentralFile(rootDirectory, contract.application.macos.entitlements);
  const entitlementsInheritFile = readCentralFile(
    rootDirectory,
    contract.application.macos.entitlementsInherit
  );
  return {
    entitlementsPath: resolve(outputPath, MAC_ENTITLEMENTS_FILE),
    entitlementsInheritPath: resolve(outputPath, MAC_ENTITLEMENTS_INHERIT_FILE),
    entitlementsFile,
    entitlementsInheritFile
  };
}

function assertCentralFileUnchanged(file: CentralFile): void {
  assertRegularFile(file.sourcePath, "中央entitlementsがregular fileではありません");
  const currentContents = readFileContents(file.sourcePath, "中央entitlementsを読み込めません");
  if (!currentContents.equals(file.contents)) {
    throw new Error(`中央entitlementsがコピー中に変更されました: ${file.sourcePath}`);
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
      entitlements: macEntitlements.entitlementsPath,
      entitlementsInherit: macEntitlements.entitlementsInheritPath,
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

function writeNewFile(output: CreatedOutput, name: string, contents: string): void {
  writeExclusiveFile(output, name, Buffer.from(contents));
}

function buildProject(
  rootDirectory: string,
  contract: ReleaseContract,
  target: PackageProjectTarget,
  output: CreatedOutput
): ExpectedProjectFile[] {
  const packageContents = JSON.stringify(packageJson(contract), null, 2);
  if (packageContents === undefined) {
    throw new Error("package.jsonを生成できません");
  }
  const packageFile = { name: "package.json", contents: Buffer.from(`${packageContents}\n`) };
  if (target === "macos") {
    const macEntitlements = readMacEntitlements(rootDirectory, contract, output.target.outputPath);
    const builderContents = stringifyYaml(macBuilderConfig(contract, macEntitlements));
    const expectedFiles: ExpectedProjectFile[] = [
      packageFile,
      { name: "electron-builder.yml", contents: Buffer.from(builderContents) },
      {
        name: MAC_ENTITLEMENTS_FILE,
        contents: macEntitlements.entitlementsFile.contents
      },
      {
        name: MAC_ENTITLEMENTS_INHERIT_FILE,
        contents: macEntitlements.entitlementsInheritFile.contents
      }
    ];
    writeNewFile(output, packageFile.name, `${packageContents}\n`);
    writeNewFile(output, "electron-builder.yml", builderContents);
    writeExclusiveFile(output, MAC_ENTITLEMENTS_FILE, macEntitlements.entitlementsFile.contents);
    writeExclusiveFile(
      output,
      MAC_ENTITLEMENTS_INHERIT_FILE,
      macEntitlements.entitlementsInheritFile.contents
    );
    assertCentralFileUnchanged(macEntitlements.entitlementsFile);
    assertCentralFileUnchanged(macEntitlements.entitlementsInheritFile);
    verifyProjectFiles(output, expectedFiles);
    return expectedFiles;
  }
  const builderContents = stringifyYaml(windowsBuilderConfig(contract, target));
  const expectedFiles: ExpectedProjectFile[] = [
    packageFile,
    { name: "electron-builder.yml", contents: Buffer.from(builderContents) }
  ];
  writeNewFile(output, packageFile.name, `${packageContents}\n`);
  writeNewFile(output, "electron-builder.yml", builderContents);
  verifyProjectFiles(output, expectedFiles);
  return expectedFiles;
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
  const outputTarget = prepareOutputTarget(outputDirectory);
  const output = createOutputDirectory(outputTarget);
  try {
    const expectedFiles = buildProject(rootDirectory, parsedContract, targetValue, output);
    assertCreatedOutput(output);
    assertRealPathWithin(
      output.target.parentRealPath,
      output.target.outputPath,
      "公開済みoutputが物理親path外です"
    );
    let requestedRealPath: string;
    let outputRealPath: string;
    try {
      requestedRealPath = realpathSync(output.target.requestedPath);
      outputRealPath = realpathSync(output.target.outputPath);
    } catch (error) {
      throw new Error(`公開済みoutputのrealpathを確認できません: ${output.target.outputPath}`, {
        cause: error
      });
    }
    if (resolve(requestedRealPath) !== resolve(outputRealPath)) {
      throw new Error(`公開済みoutputのrealpathが一致しません: ${output.target.requestedPath}`);
    }
    verifyProjectFiles(output, expectedFiles);
  } catch (error) {
    cleanupCreatedOutput(error, output);
  }
}
