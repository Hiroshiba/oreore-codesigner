import { createHash } from "node:crypto";
import { lstatSync, readFileSync, readdirSync } from "node:fs";
import { basename, extname, join } from "node:path";
import { parse as parseYaml } from "yaml";
import { parseSemVer, parseUpdateMetadata, type UpdateMetadata } from "./schema.js";
import { assertNoSymlinkPath } from "./path-safety.js";

function assertAssetsDirectory(path: string): void {
  assertNoSymlinkPath(path, "assets directoryにsymlinkを指定できません");
  let information;
  try {
    information = lstatSync(path);
  } catch (error) {
    throw new Error(`assets directoryを確認できません: ${path}`, { cause: error });
  }
  if (!information.isDirectory() || information.isSymbolicLink()) {
    throw new Error(`assets directoryがディレクトリではありません: ${path}`);
  }
}

function assertRegularAsset(path: string, name: string): number {
  assertNoSymlinkPath(path, "asset pathにsymlinkを指定できません");
  let information;
  try {
    information = lstatSync(path);
  } catch (error) {
    throw new Error(`assetを確認できません: ${name}`, { cause: error });
  }
  if (!information.isFile() || information.isSymbolicLink()) {
    throw new Error(`assetはregular fileでなければなりません: ${name}`);
  }
  return information.size;
}

function readAsset(path: string, name: string): Buffer {
  assertRegularAsset(path, name);
  try {
    return readFileSync(path);
  } catch (error) {
    throw new Error(`assetを読み込めません: ${name}`, { cause: error });
  }
}

function sha512(contents: Buffer): string {
  return createHash("sha512").update(contents).digest("base64");
}

function equalSha512(actualBase64: string, expected: string): boolean {
  if (expected === actualBase64) {
    return true;
  }
  if (/^[0-9A-Fa-f]{128}$/u.test(expected)) {
    return expected.toLowerCase() === Buffer.from(actualBase64, "base64").toString("hex");
  }
  if (/^[A-Za-z0-9+/]{86}==$/u.test(expected)) {
    return Buffer.from(actualBase64, "base64").equals(Buffer.from(expected, "base64"));
  }
  return false;
}

function parseMetadata(path: string, name: string): UpdateMetadata {
  const source = readAsset(path, name).toString("utf8");
  let value: unknown;
  try {
    value = parseYaml(source);
  } catch (error) {
    throw new Error(`metadata YAMLを解析できません: ${name}`, { cause: error });
  }
  return parseUpdateMetadata(value);
}

function assertMetadataFile(
  metadataName: string,
  metadata: UpdateMetadata,
  expectedVersion: string,
  assetNames: Set<string>,
  assetSizes: Map<string, number>,
  actualNames: Map<string, string>,
  assetsDirectory: string
): void {
  if (metadata.version !== expectedVersion) {
    throw new Error(`metadata versionがexpected-versionと一致しません: ${metadataName}`);
  }
  const metadataKind = extname(metadata.path).toLowerCase();
  if (metadataKind !== ".zip" && metadataKind !== ".exe") {
    throw new Error(`metadata pathの形式が不正です: ${metadata.path}`);
  }
  const metadataPathKey = metadata.path.toLowerCase();
  if (!assetNames.has(metadataPathKey)) {
    throw new Error(`metadata pathがassets directoryにありません: ${metadata.path}`);
  }
  const metadataPathSize = assetSizes.get(metadataPathKey);
  if (metadataPathSize == undefined) {
    throw new Error(`metadata pathのasset sizeを確認できません: ${metadata.path}`);
  }
  const actualPathName = actualNames.get(metadataPathKey);
  if (actualPathName == undefined) {
    throw new Error(`metadata pathの実file名を確認できません: ${metadata.path}`);
  }
  if (metadata.path !== actualPathName) {
    throw new Error(`metadata pathのbasenameが実fileと一致しません: ${metadata.path}`);
  }
  const pathContents = readAsset(join(assetsDirectory, actualPathName), metadata.path);
  if (!equalSha512(sha512(pathContents), metadata.sha512)) {
    throw new Error(`metadata top-level sha512が実assetと一致しません: ${metadata.path}`);
  }
  if (!metadata.files.some((file) => file.url === metadata.path)) {
    throw new Error(`metadata pathがfilesにありません: ${metadataName}`);
  }
  const fileNames = new Set<string>();
  for (const file of metadata.files) {
    const key = file.url.toLowerCase();
    if (fileNames.has(key)) {
      throw new Error(`metadata filesのurlが重複しています: ${file.url}`);
    }
    fileNames.add(key);
    if (!assetNames.has(key)) {
      throw new Error(`metadata filesのurlがassets directoryにありません: ${file.url}`);
    }
    const actualFileName = actualNames.get(key);
    if (actualFileName == undefined) {
      throw new Error(`metadata filesの実file名を確認できません: ${file.url}`);
    }
    if (file.url !== actualFileName) {
      throw new Error(`metadata filesのbasenameが実fileと一致しません: ${file.url}`);
    }
    const contents = readAsset(join(assetsDirectory, actualFileName), file.url);
    if (contents.length !== file.size) {
      throw new Error(`metadata filesのsizeが実assetと一致しません: ${file.url}`);
    }
    if (!equalSha512(sha512(contents), file.sha512)) {
      throw new Error(`metadata filesのsha512が実assetと一致しません: ${file.url}`);
    }
    if (metadataKind === ".exe" && file.url === metadata.path && file.blockMapSize == undefined) {
      throw new Error(`Windows metadataの通常NSIS blockmapがありません: ${file.url}`);
    }
    if (file.blockMapSize != undefined) {
      const blockMapName = `${file.url}.blockmap`;
      const actualBlockMapName = actualNames.get(blockMapName.toLowerCase());
      if (actualBlockMapName == undefined) {
        throw new Error(`metadata blockmapがassets directoryにありません: ${blockMapName}`);
      }
      if (actualBlockMapName !== blockMapName) {
        throw new Error(`metadata blockmapのbasenameが実fileと一致しません: ${blockMapName}`);
      }
      const blockMapSize = assetSizes.get(blockMapName.toLowerCase());
      if (blockMapSize == undefined || blockMapSize !== file.blockMapSize) {
        throw new Error(`metadata blockMapSizeが実fileと一致しません: ${file.url}`);
      }
    }
    const fileExtension = extname(file.url).toLowerCase();
    if (metadataKind === ".zip" && fileExtension !== ".zip") {
      throw new Error(`mac metadataがZIP以外を参照しています: ${file.url}`);
    }
    if (metadataKind === ".exe" && fileExtension !== ".exe") {
      throw new Error(`Windows metadataが通常NSIS以外を参照しています: ${file.url}`);
    }
  }
  if (pathContents.length !== metadataPathSize) {
    throw new Error(`metadata pathのsizeを確認できません: ${metadata.path}`);
  }
}

/** assets directoryの実fileと更新metadataの整合性を検証します。 */
export function validateReleaseAssets(assetsDirectory: string, expectedVersion: string): void {
  const parsedExpectedVersion = parseSemVer(expectedVersion);
  assertAssetsDirectory(assetsDirectory);
  const entries = readdirSync(assetsDirectory, { withFileTypes: true });
  const names = new Set<string>();
  const actualNames = new Map<string, string>();
  const sizes = new Map<string, number>();
  const metadata: Array<{ name: string; path: string }> = [];
  for (const entry of entries) {
    if (!entry.isFile() || entry.isSymbolicLink()) {
      throw new Error(`assetはregular fileでなければなりません: ${entry.name}`);
    }
    if (basename(entry.name) !== entry.name) {
      throw new Error(`asset basenameが不正です: ${entry.name}`);
    }
    if (
      [...entry.name].some((character) => {
        const code = character.codePointAt(0);
        return code == undefined || code <= 0x1f || code === 0x7f;
      })
    ) {
      throw new Error(`asset basenameに制御文字を指定できません: ${entry.name}`);
    }
    const key = entry.name.toLowerCase();
    if (names.has(key)) {
      throw new Error(`asset basenameが大文字小文字を無視して重複しています: ${entry.name}`);
    }
    names.add(key);
    actualNames.set(key, entry.name);
    const path = join(assetsDirectory, entry.name);
    const size = assertRegularAsset(path, entry.name);
    sizes.set(key, size);
    const extension = extname(entry.name).toLowerCase();
    if (extension === ".yml" || extension === ".yaml") {
      metadata.push({ name: entry.name, path });
    }
  }
  for (const item of metadata) {
    const parsed = parseMetadata(item.path, item.name);
    assertMetadataFile(
      item.name,
      parsed,
      parsedExpectedVersion,
      names,
      sizes,
      actualNames,
      assetsDirectory
    );
  }
}
