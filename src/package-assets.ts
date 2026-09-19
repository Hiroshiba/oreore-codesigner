import { lstatSync, readFileSync, readdirSync } from "node:fs";
import { basename, extname, join, relative, sep } from "node:path";
import { parse as parseYaml } from "yaml";
import { z } from "zod";
import { parseSemVer, parseUpdateMetadata, type UpdateMetadata } from "./schema.js";

const fileNameSchema = z
  .string()
  .min(1, "filenameを空にできません")
  .refine(
    (value) =>
      value !== "." &&
      value !== ".." &&
      !value.includes("/") &&
      !value.includes("\\") &&
      !value.includes(":") &&
      !value.includes("\u0000"),
    "basenameを指定してください"
  );
const sha512Schema = z.string().regex(/^[A-Za-z0-9+/]{86}==$/, "metadata sha512が不正です");
const metadataFileSchema = z
  .object({
    url: fileNameSchema,
    size: z.number().int().nonnegative(),
    sha512: sha512Schema,
    blockMapSize: z.number().int().nonnegative().optional()
  })
  .strict();
const webPackageSchema = z
  .object({
    size: z.number().int().nonnegative(),
    sha512: sha512Schema,
    path: fileNameSchema,
    file: fileNameSchema
  })
  .passthrough();
const webMetadataSchema = z
  .object({
    version: z.string(),
    files: z.array(metadataFileSchema).min(1),
    path: fileNameSchema,
    sha512: sha512Schema,
    packages: z
      .object({
        x64: webPackageSchema
      })
      .passthrough()
  })
  .passthrough();

type RelativeFile = {
  absolutePath: string;
  relativePath: string;
};

export type MacosPackagedOutput = {
  platform: "macos";
  metadata: string;
  artifact: string;
  blockmap: string;
};

export type WindowsPackagedOutput = {
  platform: "windows";
  metadata: string;
  artifact: string;
  blockmap: string;
  webInstaller: string;
  webPackage: string;
};

export type PackagedOutput = MacosPackagedOutput | WindowsPackagedOutput;

function assertDirectory(path: string): void {
  const information = lstatSync(path);
  if (!information.isDirectory() || information.isSymbolicLink()) {
    throw new Error(`builder outputが通常directoryではありません: ${path}`);
  }
}

function assertRegularFile(path: string, description: string): void {
  const information = lstatSync(path);
  if (!information.isFile() || information.isSymbolicLink()) {
    throw new Error(`${description}が通常fileではありません: ${path}`);
  }
}

function listFiles(root: string, directory: string): RelativeFile[] {
  const files: RelativeFile[] = [];
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isSymbolicLink()) {
      continue;
    }
    if (entry.isDirectory()) {
      files.push(...listFiles(root, path));
      continue;
    }
    if (entry.isFile()) {
      files.push({
        absolutePath: path,
        relativePath: relative(root, path).split(sep).join("/")
      });
    }
  }
  return files;
}

function findUniqueFile(root: string, fileName: string): RelativeFile {
  const matches = listFiles(root, root).filter(
    (file) => basename(file.absolutePath).toLowerCase() === fileName.toLowerCase()
  );
  if (matches.length !== 1) {
    throw new Error(`metadataが参照するassetの一意な実fileがありません: ${fileName}`);
  }
  const match = matches[0];
  if (match == undefined) {
    throw new Error(`metadataが参照するassetがありません: ${fileName}`);
  }
  return match;
}

function parseMetadataFile(path: string, expectedVersion: string): UpdateMetadata {
  const metadata = parseUpdateMetadata(parseYaml(readFileSync(path, "utf8")));
  if (metadata.version !== expectedVersion) {
    throw new Error(`metadata versionがexpected-versionと一致しません: ${path}`);
  }
  if (!metadata.files.some((file) => file.url === metadata.path)) {
    throw new Error(`metadata pathがfilesにありません: ${path}`);
  }
  return metadata;
}

function assertMetadataPath(metadata: UpdateMetadata, extension: string): void {
  if (extname(metadata.path).toLowerCase() !== extension) {
    throw new Error(`metadata pathの形式が不正です: ${metadata.path}`);
  }
}

function selectExternalBlockmap(root: string, artifactName: string): RelativeFile {
  return findUniqueFile(root, `${artifactName}.blockmap`);
}

function selectMacosOutput(
  builderOutput: string,
  channel: string,
  expectedVersion: string
): MacosPackagedOutput {
  const metadataName = `${channel}-mac.yml`;
  const metadataPath = join(builderOutput, metadataName);
  assertRegularFile(metadataPath, `macOS metadata ${metadataName}`);
  const metadata = parseMetadataFile(metadataPath, expectedVersion);
  assertMetadataPath(metadata, ".zip");
  const artifact = findUniqueFile(builderOutput, metadata.path);
  const blockmap = selectExternalBlockmap(builderOutput, metadata.path);
  return {
    platform: "macos",
    metadata: metadataName,
    artifact: artifact.relativePath,
    blockmap: blockmap.relativePath
  };
}

function selectWindowsOutput(
  builderOutput: string,
  channel: string,
  expectedVersion: string
): WindowsPackagedOutput {
  const metadataName = `${channel}.yml`;
  const metadataPath = join(builderOutput, metadataName);
  assertRegularFile(metadataPath, `Windows metadata ${metadataName}`);
  const metadata = parseMetadataFile(metadataPath, expectedVersion);
  assertMetadataPath(metadata, ".exe");
  const artifact = findUniqueFile(builderOutput, metadata.path);
  const blockmap = selectExternalBlockmap(builderOutput, metadata.path);

  const webDirectory = join(builderOutput, "nsis-web");
  assertDirectory(webDirectory);
  const webMetadataName = `${channel}.yml`;
  const webMetadataPath = join(webDirectory, webMetadataName);
  assertRegularFile(webMetadataPath, `NSIS Web metadata ${webMetadataName}`);
  const webMetadata = webMetadataSchema.parse(parseYaml(readFileSync(webMetadataPath, "utf8")));
  const webVersion = parseSemVer(webMetadata.version);
  if (webVersion !== expectedVersion) {
    throw new Error(
      `NSIS Web metadata versionがexpected-versionと一致しません: ${webMetadataPath}`
    );
  }
  if (!webMetadata.files.some((file) => file.url === webMetadata.path)) {
    throw new Error(`NSIS Web metadata pathがfilesにありません: ${webMetadataPath}`);
  }
  if (extname(webMetadata.path).toLowerCase() !== ".exe") {
    throw new Error(`NSIS Web metadata pathの形式が不正です: ${webMetadata.path}`);
  }
  const webPackage = webMetadata.packages.x64;
  if (webPackage.file !== webPackage.path || !webPackage.file.toLowerCase().endsWith(".nsis.7z")) {
    throw new Error(`NSIS Web metadataのx64 packageがnsis.7zではありません: ${webPackage.file}`);
  }
  const webInstallerFile = findUniqueFile(webDirectory, webMetadata.path);
  const webPackageFile = findUniqueFile(webDirectory, webPackage.file);
  return {
    platform: "windows",
    metadata: metadataName,
    artifact: artifact.relativePath,
    blockmap: blockmap.relativePath,
    webInstaller: `nsis-web/${webInstallerFile.relativePath}`,
    webPackage: `nsis-web/${webPackageFile.relativePath}`
  };
}

/** electron-builderの出力から現在channelの公開対象を検証して選びます。 */
export function validatePackagedOutput(
  builderOutput: string,
  platform: "macos" | "windows",
  channel: string,
  expectedVersion: string
): PackagedOutput {
  assertDirectory(builderOutput);
  parseSemVer(expectedVersion);
  if (channel.length === 0 || !/^[0-9A-Za-z-]+$/.test(channel)) {
    throw new Error(`channelが不正です: ${channel}`);
  }
  if (platform === "macos") {
    return selectMacosOutput(builderOutput, channel, expectedVersion);
  }
  return selectWindowsOutput(builderOutput, channel, expectedVersion);
}
