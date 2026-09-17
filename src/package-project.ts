import {
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  realpathSync,
  renameSync,
  rmSync,
  writeFileSync
} from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
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
type MacEntitlements = {
  entitlements: string;
  entitlementsInherit: string;
  entitlementsFile: CentralFile;
  entitlementsInheritFile: CentralFile;
};
type ExpectedProjectFile = { name: string; contents: Buffer };
type DirectoryIdentity = { device: number; inode: number };
type PrivateDirectory = {
  path: string;
  identity: DirectoryIdentity;
  parentPath: string;
  parentIdentity: DirectoryIdentity;
};
type OutputState = { kind: "absent" } | { kind: "empty-directory"; device: number; inode: number };
type OutputTarget = {
  requestedPath: string;
  parentRealPath: string;
  parentIdentity: DirectoryIdentity;
  outputPath: string;
  state: OutputState;
};
type BackupState =
  | { kind: "prepared"; directory: PrivateDirectory; outputPath: string }
  | { kind: "moved"; directory: PrivateDirectory; outputPath: string };

function isErrnoException(error: unknown): error is NodeJS.ErrnoException {
  return error instanceof Error && "code" in error && typeof error.code === "string";
}

function inspectOutputDirectory(path: string): OutputState {
  let information;
  try {
    information = lstatSync(path);
  } catch (error) {
    if (isErrnoException(error) && error.code === "ENOENT") {
      return { kind: "absent" };
    }
    throw new Error(`output-directoryを確認できません: ${path}`, { cause: error });
  }
  if (information.isSymbolicLink() || !information.isDirectory()) {
    throw new Error(`output-directoryが空のディレクトリではありません: ${path}`);
  }
  let entries: string[];
  try {
    entries = readdirSync(path);
  } catch (error) {
    throw new Error(`output-directoryを読み込めません: ${path}`, { cause: error });
  }
  if (entries.length > 0) {
    throw new Error(`output-directoryは空でなければなりません: ${path}`);
  }
  return { kind: "empty-directory", device: information.dev, inode: information.ino };
}

function prepareOutputTarget(path: string): OutputTarget {
  const requestedPath = resolve(path);
  const parentPath = dirname(requestedPath);
  assertNoSymlinkAncestors(requestedPath, "output-directoryの親pathにsymlinkを指定できません");
  if (!existsSync(parentPath)) {
    try {
      mkdirSync(parentPath, { recursive: true, mode: 0o700 });
    } catch (error) {
      throw new Error(`output-directoryの親を作成できません: ${parentPath}`, { cause: error });
    }
  }
  assertNoSymlinkPath(parentPath, "output-directoryの親pathにsymlinkを指定できません");
  let parentRealPath: string;
  try {
    parentRealPath = realpathSync(parentPath);
  } catch (error) {
    throw new Error(`output-directoryの親pathを解決できません: ${parentPath}`, { cause: error });
  }
  assertNoSymlinkPath(parentRealPath, "output-directoryの物理親pathが不正です");
  const parentInformation = lstatSync(parentRealPath);
  if (!parentInformation.isDirectory()) {
    throw new Error(`output-directoryの物理親pathがディレクトリではありません: ${parentRealPath}`);
  }
  const outputPath = join(parentRealPath, basename(requestedPath));
  return {
    requestedPath,
    parentRealPath,
    parentIdentity: { device: parentInformation.dev, inode: parentInformation.ino },
    outputPath,
    state: inspectOutputDirectory(outputPath)
  };
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

function assertDirectoryIdentity(path: string, identity: DirectoryIdentity, message: string): void {
  assertNoSymlinkPath(path, message);
  let information;
  try {
    information = lstatSync(path);
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

function assertPrivateDirectory(directory: PrivateDirectory): void {
  assertDirectoryIdentity(
    directory.parentPath,
    directory.parentIdentity,
    "staging directoryの親pathが途中で差し替えられました"
  );
  assertNoSymlinkPath(directory.path, "staging directoryにsymlinkを指定できません");
  let information;
  try {
    information = lstatSync(directory.path);
  } catch (error) {
    throw new Error(`staging directoryを確認できません: ${directory.path}`, { cause: error });
  }
  if (
    !information.isDirectory() ||
    information.dev !== directory.identity.device ||
    information.ino !== directory.identity.inode ||
    (information.mode & 0o777) !== 0o700
  ) {
    throw new Error(`staging directoryの権限または種類が不正です: ${directory.path}`);
  }
}

function cleanupCreatedPrivateDirectory(error: unknown, directory: PrivateDirectory): never {
  try {
    removePrivateDirectory(directory);
  } catch (cleanupError) {
    throw new AggregateError(
      [error, cleanupError],
      "staging directoryの検証に失敗しcleanupも完了できません"
    );
  }
  throw error;
}

function createPrivateDirectory(
  parentRealPath: string,
  parentIdentity: DirectoryIdentity,
  prefix: string
): PrivateDirectory {
  assertNoSymlinkPath(parentRealPath, "staging directoryの親pathが不正です");
  assertDirectoryIdentity(parentRealPath, parentIdentity, "staging directoryの親pathが不正です");
  let directory: string;
  try {
    directory = mkdtempSync(join(parentRealPath, prefix));
  } catch (error) {
    throw new Error(`staging directoryを作成できません: ${parentRealPath}`, { cause: error });
  }
  let information;
  try {
    information = lstatSync(directory);
  } catch (error) {
    throw new Error(`staging directoryを確認できません: ${directory}`, { cause: error });
  }
  const privateDirectory: PrivateDirectory = {
    path: resolve(directory),
    identity: { device: information.dev, inode: information.ino },
    parentPath: parentRealPath,
    parentIdentity
  };
  try {
    assertPrivateDirectory(privateDirectory);
    assertRealPathWithin(parentRealPath, directory, "staging directoryが親path外です");
    return privateDirectory;
  } catch (error) {
    cleanupCreatedPrivateDirectory(error, privateDirectory);
  }
}

function writeExclusiveFile(directory: PrivateDirectory, name: string, contents: Buffer): void {
  assertPrivateDirectory(directory);
  const path = join(directory.path, name);
  try {
    writeFileSync(path, contents, { flag: "wx", mode: 0o600 });
  } catch (error) {
    throw new Error(`staging fileを書き込めません: ${path}`, { cause: error });
  }
  assertRegularFile(path, "staging fileがregular fileではありません");
  const writtenContents = readFileContents(path, "staging fileを読み込めません");
  if (!writtenContents.equals(contents)) {
    throw new Error(`staging fileのbytesが一致しません: ${path}`);
  }
  assertPrivateDirectory(directory);
}

function verifyProjectFiles(directory: string, expectedFiles: ExpectedProjectFile[]): void {
  assertNoSymlinkPath(directory, "staging directoryにsymlinkを指定できません");
  let information;
  try {
    information = lstatSync(directory);
  } catch (error) {
    throw new Error(`staging directoryを確認できません: ${directory}`, { cause: error });
  }
  if (!information.isDirectory() || (information.mode & 0o777) !== 0o700) {
    throw new Error(`staging directoryの権限または種類が不正です: ${directory}`);
  }
  const expectedNames = new Set(expectedFiles.map((file) => file.name));
  if (expectedNames.size !== expectedFiles.length) {
    throw new Error("staging file名が重複しています");
  }
  let entries: string[];
  try {
    entries = readdirSync(directory);
  } catch (error) {
    throw new Error(`staging directoryを読み込めません: ${directory}`, { cause: error });
  }
  if (entries.length !== expectedFiles.length) {
    throw new Error(`staging fileの件数が一致しません: ${directory}`);
  }
  for (const entry of entries) {
    if (!expectedNames.has(entry)) {
      throw new Error(`想定外のstaging fileです: ${entry}`);
    }
  }
  for (const expectedFile of expectedFiles) {
    const path = join(directory, expectedFile.name);
    assertRegularFile(path, "staging fileがregular fileではありません");
    const contents = readFileContents(path, "staging fileを読み込めません");
    if (!contents.equals(expectedFile.contents)) {
      throw new Error(`staging fileのbytesが一致しません: ${path}`);
    }
  }
  assertNoSymlinkPath(directory, "staging directoryにsymlinkを指定できません");
  let finalInformation;
  try {
    finalInformation = lstatSync(directory);
  } catch (error) {
    throw new Error(`staging directoryを確認できません: ${directory}`, { cause: error });
  }
  if (!finalInformation.isDirectory() || (finalInformation.mode & 0o777) !== 0o700) {
    throw new Error(`staging directoryの権限または種類が不正です: ${directory}`);
  }
}

function assertOutputStateUnchanged(target: OutputTarget): void {
  const current = inspectOutputDirectory(target.outputPath);
  if (target.state.kind === "absent") {
    if (current.kind !== "absent") {
      throw new Error(`output-directoryが途中で作成されました: ${target.outputPath}`);
    }
    return;
  }
  if (
    current.kind === "absent" ||
    current.device !== target.state.device ||
    current.inode !== target.state.inode
  ) {
    throw new Error(`output-directoryが途中で差し替えられました: ${target.outputPath}`);
  }
}

function assertOutputAbsent(path: string): void {
  const state = inspectOutputDirectory(path);
  if (state.kind !== "absent") {
    throw new Error(`output-directoryが既に存在します: ${path}`);
  }
}

function assertStableOutputParent(target: OutputTarget): void {
  assertNoSymlinkAncestors(
    target.requestedPath,
    "output-directoryの親pathにsymlinkを指定できません"
  );
  assertDirectoryIdentity(
    target.parentRealPath,
    target.parentIdentity,
    "output-directoryの物理親pathが途中で差し替えられました"
  );
  let requestedParentRealPath: string;
  try {
    requestedParentRealPath = realpathSync(dirname(target.requestedPath));
  } catch (error) {
    throw new Error(`output-directoryの親pathを解決できません: ${target.requestedPath}`, {
      cause: error
    });
  }
  if (resolve(requestedParentRealPath) !== resolve(target.parentRealPath)) {
    throw new Error(`output-directoryの親pathが途中で差し替えられました: ${target.requestedPath}`);
  }
}

function renameDirectory(sourcePath: string, destinationPath: string, message: string): void {
  try {
    renameSync(sourcePath, destinationPath);
  } catch (error) {
    throw new Error(`${message}: ${destinationPath}`, { cause: error });
  }
}

function createBackupDirectory(target: OutputTarget): BackupState {
  const directory = createPrivateDirectory(
    target.parentRealPath,
    target.parentIdentity,
    ".personal-signing-output-backup-"
  );
  return {
    kind: "prepared",
    directory,
    outputPath: join(directory.path, "output")
  };
}

function assertPublishedOutput(
  target: OutputTarget,
  stagingDirectory: PrivateDirectory,
  expectedFiles: ExpectedProjectFile[]
): void {
  assertStableOutputParent(target);
  assertNoSymlinkPath(target.outputPath, "公開済みoutputにsymlinkを指定できません");
  assertRealPathWithin(
    target.parentRealPath,
    target.outputPath,
    "公開済みoutputが物理親path外です"
  );
  let information;
  try {
    information = lstatSync(target.outputPath);
  } catch (error) {
    throw new Error(`公開済みoutputを確認できません: ${target.outputPath}`, { cause: error });
  }
  if (
    !information.isDirectory() ||
    information.dev !== stagingDirectory.identity.device ||
    information.ino !== stagingDirectory.identity.inode
  ) {
    throw new Error(`公開済みoutputのinodeが一致しません: ${target.outputPath}`);
  }
  let requestedRealPath: string;
  let outputRealPath: string;
  try {
    requestedRealPath = realpathSync(target.requestedPath);
    outputRealPath = realpathSync(target.outputPath);
  } catch (error) {
    throw new Error(`公開済みoutputのrealpathを確認できません: ${target.outputPath}`, {
      cause: error
    });
  }
  if (resolve(requestedRealPath) !== resolve(outputRealPath)) {
    throw new Error(`公開済みoutputのrealpathが一致しません: ${target.requestedPath}`);
  }
  verifyProjectFiles(target.outputPath, expectedFiles);
}

function removePrivateDirectory(directory: PrivateDirectory): void {
  try {
    assertDirectoryIdentity(
      directory.parentPath,
      directory.parentIdentity,
      "staging directoryの親pathが途中で差し替えられました"
    );
  } catch (error) {
    throw new Error(`staging directoryの親pathを確認できません: ${directory.parentPath}`, {
      cause: error
    });
  }
  let information;
  try {
    information = lstatSync(directory.path);
  } catch (error) {
    if (isErrnoException(error) && error.code === "ENOENT") {
      return;
    }
    throw new Error(`staging directoryを確認できません: ${directory.path}`, { cause: error });
  }
  if (
    information.isSymbolicLink() ||
    !information.isDirectory() ||
    information.dev !== directory.identity.device ||
    information.ino !== directory.identity.inode
  ) {
    throw new Error(`staging directoryが予期せず変更されました: ${directory.path}`);
  }
  try {
    rmSync(directory.path, { recursive: true });
  } catch (error) {
    throw new Error(`staging directoryを削除できません: ${directory.path}`, { cause: error });
  }
}

function removePublishedOutput(
  target: OutputTarget,
  stagingDirectory: PrivateDirectory,
  expectedFiles: ExpectedProjectFile[]
): void {
  assertStableOutputParent(target);
  assertNoSymlinkPath(target.outputPath, "公開済みoutputにsymlinkを指定できません");
  assertRealPathWithin(
    target.parentRealPath,
    target.outputPath,
    "公開済みoutputが物理親path外です"
  );
  let information;
  try {
    information = lstatSync(target.outputPath);
  } catch (error) {
    throw new Error(`公開済みoutputを確認できません: ${target.outputPath}`, { cause: error });
  }
  if (
    !information.isDirectory() ||
    information.dev !== stagingDirectory.identity.device ||
    information.ino !== stagingDirectory.identity.inode
  ) {
    throw new Error(`公開済みoutputのinodeが一致しません: ${target.outputPath}`);
  }
  verifyProjectFiles(target.outputPath, expectedFiles);
  try {
    rmSync(target.outputPath, { recursive: true });
  } catch (error) {
    throw new Error(`公開済みoutputを削除できません: ${target.outputPath}`, { cause: error });
  }
  assertOutputAbsent(target.outputPath);
}

function cleanupPublishFailure(
  error: unknown,
  stagingDirectory: PrivateDirectory,
  backup: BackupState | undefined,
  published: boolean,
  target: OutputTarget,
  expectedFiles: ExpectedProjectFile[]
): never {
  const cleanupErrors: unknown[] = [];
  try {
    removePrivateDirectory(stagingDirectory);
  } catch (cleanupError) {
    cleanupErrors.push(cleanupError);
  }
  let outputRemoved = !published;
  if (published) {
    try {
      removePublishedOutput(target, stagingDirectory, expectedFiles);
      outputRemoved = true;
    } catch (cleanupError) {
      cleanupErrors.push(cleanupError);
    }
  }
  if (backup !== undefined) {
    let backupRestored = false;
    if (backup.kind === "moved" && !published) {
      try {
        assertStableOutputParent(target);
        assertOutputAbsent(target.outputPath);
        renameDirectory(backup.outputPath, target.outputPath, "元のoutputを復元できません");
        backupRestored = true;
      } catch (cleanupError) {
        cleanupErrors.push(cleanupError);
      }
    }
    if (backup.kind === "moved" && published && outputRemoved) {
      try {
        assertStableOutputParent(target);
        assertOutputAbsent(target.outputPath);
        renameDirectory(backup.outputPath, target.outputPath, "元のoutputを復元できません");
        backupRestored = true;
      } catch (cleanupError) {
        cleanupErrors.push(cleanupError);
      }
    }
    if (backup.kind === "prepared" || backupRestored) {
      try {
        removePrivateDirectory(backup.directory);
      } catch (cleanupError) {
        cleanupErrors.push(cleanupError);
      }
    }
  }
  if (cleanupErrors.length > 0) {
    throw new AggregateError(
      [error, ...cleanupErrors],
      "package project生成に失敗しcleanupも完了できません"
    );
  }
  throw error;
}

function publishStaging(
  target: OutputTarget,
  stagingDirectory: PrivateDirectory,
  expectedFiles: ExpectedProjectFile[]
): void {
  let backup: BackupState | undefined;
  let published = false;
  try {
    assertPrivateDirectory(stagingDirectory);
    assertOutputStateUnchanged(target);
    if (target.state.kind === "empty-directory") {
      backup = createBackupDirectory(target);
      assertStableOutputParent(target);
      assertOutputStateUnchanged(target);
      assertOutputAbsent(backup.outputPath);
      renameDirectory(target.outputPath, backup.outputPath, "既存outputを退避できません");
      backup = { kind: "moved", directory: backup.directory, outputPath: backup.outputPath };
    }
    assertStableOutputParent(target);
    assertOutputAbsent(target.outputPath);
    renameDirectory(stagingDirectory.path, target.outputPath, "stagingをoutputへ公開できません");
    published = true;
    assertPublishedOutput(target, stagingDirectory, expectedFiles);
    if (backup !== undefined) {
      removePrivateDirectory(backup.directory);
      backup = undefined;
    }
  } catch (error) {
    cleanupPublishFailure(error, stagingDirectory, backup, published, target, expectedFiles);
  }
}

function cleanupBuildFailure(error: unknown, stagingDirectory: PrivateDirectory): never {
  try {
    removePrivateDirectory(stagingDirectory);
  } catch (cleanupError) {
    throw new AggregateError(
      [error, cleanupError],
      "package project生成に失敗しstagingも削除できません"
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

function readMacEntitlements(rootDirectory: string, contract: ReleaseContract): MacEntitlements {
  const entitlements = readCentralFile(rootDirectory, contract.application.macos.entitlements);
  const entitlementsInherit = readCentralFile(
    rootDirectory,
    contract.application.macos.entitlementsInherit
  );
  return {
    entitlements: MAC_ENTITLEMENTS_FILE,
    entitlementsInherit: MAC_ENTITLEMENTS_INHERIT_FILE,
    entitlementsFile: entitlements,
    entitlementsInheritFile: entitlementsInherit
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

function buildStagingProject(
  rootDirectory: string,
  contract: ReleaseContract,
  target: PackageProjectTarget,
  stagingDirectory: PrivateDirectory
): ExpectedProjectFile[] {
  const packageContents = JSON.stringify(packageJson(contract), null, 2);
  if (packageContents === undefined) {
    throw new Error("package.jsonを生成できません");
  }
  const packageFile = { name: "package.json", contents: Buffer.from(`${packageContents}\n`) };
  if (target === "macos") {
    const macEntitlements = readMacEntitlements(rootDirectory, contract);
    const builderContents = stringifyYaml(macBuilderConfig(contract, macEntitlements));
    const expectedFiles: ExpectedProjectFile[] = [
      packageFile,
      { name: "electron-builder.yml", contents: Buffer.from(builderContents) },
      {
        name: macEntitlements.entitlements,
        contents: macEntitlements.entitlementsFile.contents
      },
      {
        name: macEntitlements.entitlementsInherit,
        contents: macEntitlements.entitlementsInheritFile.contents
      }
    ];
    writeNewFile(stagingDirectory, packageFile.name, `${packageContents}\n`);
    writeNewFile(stagingDirectory, "electron-builder.yml", builderContents);
    writeExclusiveFile(
      stagingDirectory,
      macEntitlements.entitlements,
      macEntitlements.entitlementsFile.contents
    );
    writeExclusiveFile(
      stagingDirectory,
      macEntitlements.entitlementsInherit,
      macEntitlements.entitlementsInheritFile.contents
    );
    assertCentralFileUnchanged(macEntitlements.entitlementsFile);
    assertCentralFileUnchanged(macEntitlements.entitlementsInheritFile);
    assertPrivateDirectory(stagingDirectory);
    verifyProjectFiles(stagingDirectory.path, expectedFiles);
    assertPrivateDirectory(stagingDirectory);
    return expectedFiles;
  }
  const builderContents = stringifyYaml(windowsBuilderConfig(contract, target));
  const expectedFiles: ExpectedProjectFile[] = [
    packageFile,
    { name: "electron-builder.yml", contents: Buffer.from(builderContents) }
  ];
  writeNewFile(stagingDirectory, packageFile.name, `${packageContents}\n`);
  writeNewFile(stagingDirectory, "electron-builder.yml", builderContents);
  assertPrivateDirectory(stagingDirectory);
  verifyProjectFiles(stagingDirectory.path, expectedFiles);
  assertPrivateDirectory(stagingDirectory);
  return expectedFiles;
}

function writeNewFile(directory: PrivateDirectory, name: string, contents: string): void {
  writeExclusiveFile(directory, name, Buffer.from(contents));
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
  const stagingDirectory = createPrivateDirectory(
    outputTarget.parentRealPath,
    outputTarget.parentIdentity,
    ".personal-signing-project-"
  );
  let publishingStarted = false;
  try {
    const expectedFiles = buildStagingProject(
      rootDirectory,
      parsedContract,
      targetValue,
      stagingDirectory
    );
    publishingStarted = true;
    publishStaging(outputTarget, stagingDirectory, expectedFiles);
  } catch (error) {
    if (!publishingStarted) {
      cleanupBuildFailure(error, stagingDirectory);
    }
    throw error;
  }
}
