import { createHash } from "node:crypto";
import { lstatSync, readFileSync, readdirSync } from "node:fs";
import { basename, extname, join } from "node:path";
import { parse as parseYaml } from "yaml";
import { parseSemVer, parseUpdateMetadata, type UpdateMetadata } from "./schema.js";

type AssetContent = {
  length: number;
  sha512: string;
};
type AssetInfo = {
  name: string;
  size: number;
  content: AssetContent | undefined;
};

function assertAssetsDirectory(path: string): void {
  const information = lstatSync(path);
  if (!information.isDirectory() || information.isSymbolicLink()) {
    throw new Error(`assets directoryがディレクトリではありません: ${path}`);
  }
}

function assertRegularAsset(path: string, name: string): number {
  const information = lstatSync(path);
  if (!information.isFile() || information.isSymbolicLink()) {
    throw new Error(`assetはregular fileでなければなりません: ${name}`);
  }
  return information.size;
}

function readAsset(path: string, name: string): Buffer {
  assertRegularAsset(path, name);
  return readFileSync(path);
}

function readAssetContent(assetsDirectory: string, asset: AssetInfo): AssetContent {
  if (asset.content != undefined) {
    return asset.content;
  }
  const contents = readAsset(join(assetsDirectory, asset.name), asset.name);
  const content = { length: contents.length, sha512: sha512(contents) };
  asset.content = content;
  return content;
}

function sha512(contents: Buffer): string {
  return createHash("sha512").update(contents).digest("base64");
}

function parseMetadata(path: string, name: string): UpdateMetadata {
  const source = readAsset(path, name).toString("utf8");
  return parseUpdateMetadata(parseYaml(source));
}

function assertMetadataFile(
  metadataName: string,
  metadata: UpdateMetadata,
  expectedVersion: string,
  assets: Map<string, AssetInfo>,
  assetsDirectory: string
): string {
  if (metadata.version !== expectedVersion) {
    throw new Error(`metadata versionがexpected-versionと一致しません: ${metadataName}`);
  }
  const metadataKind = extname(metadata.path).toLowerCase();
  if (metadataKind !== ".zip" && metadataKind !== ".exe") {
    throw new Error(`metadata pathの形式が不正です: ${metadata.path}`);
  }
  const metadataPathKey = metadata.path.toLowerCase();
  const metadataPathAsset = assets.get(metadataPathKey);
  if (metadataPathAsset == undefined) {
    throw new Error(`metadata pathがassets directoryにありません: ${metadata.path}`);
  }
  if (metadata.path !== metadataPathAsset.name) {
    throw new Error(`metadata pathのbasenameが実fileと一致しません: ${metadata.path}`);
  }
  const pathContent = readAssetContent(assetsDirectory, metadataPathAsset);
  if (pathContent.sha512 !== metadata.sha512) {
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
    const fileAsset = assets.get(key);
    if (fileAsset == undefined) {
      throw new Error(`metadata filesのurlがassets directoryにありません: ${file.url}`);
    }
    if (file.url !== fileAsset.name) {
      throw new Error(`metadata filesのbasenameが実fileと一致しません: ${file.url}`);
    }
    const fileContent = readAssetContent(assetsDirectory, fileAsset);
    if (fileContent.length !== file.size) {
      throw new Error(`metadata filesのsizeが実fileと一致しません: ${file.url}`);
    }
    if (fileContent.sha512 !== file.sha512) {
      throw new Error(`metadata filesのsha512が実fileと一致しません: ${file.url}`);
    }
    if (file.url === metadata.path || file.blockMapSize != undefined) {
      const blockMapName = `${file.url}.blockmap`;
      const blockMapAsset = assets.get(blockMapName.toLowerCase());
      if (blockMapAsset == undefined) {
        throw new Error(`metadata blockmapがassets directoryにありません: ${blockMapName}`);
      }
      if (blockMapAsset.name !== blockMapName) {
        throw new Error(`metadata blockmapのbasenameが実fileと一致しません: ${blockMapName}`);
      }
      if (file.blockMapSize != undefined && blockMapAsset.size !== file.blockMapSize) {
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
  return metadataKind;
}

/** assets directoryの実fileと更新metadataの整合性を検証します。 */
export function validateReleaseAssets(assetsDirectory: string, expectedVersion: string): void {
  const parsedExpectedVersion = parseSemVer(expectedVersion);
  assertAssetsDirectory(assetsDirectory);
  const entries = readdirSync(assetsDirectory, { withFileTypes: true });
  const assets = new Map<string, AssetInfo>();
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
    if (assets.has(key)) {
      throw new Error(`asset basenameが大文字小文字を無視して重複しています: ${entry.name}`);
    }
    const path = join(assetsDirectory, entry.name);
    const size = assertRegularAsset(path, entry.name);
    assets.set(key, { name: entry.name, size, content: undefined });
    const extension = extname(entry.name).toLowerCase();
    if (extension === ".yml" || extension === ".yaml") {
      metadata.push({ name: entry.name, path });
    }
  }
  const metadataKinds = new Set<string>();
  for (const item of metadata) {
    const metadataKind = assertMetadataFile(
      item.name,
      parseMetadata(item.path, item.name),
      parsedExpectedVersion,
      assets,
      assetsDirectory
    );
    if (metadataKinds.has(metadataKind)) {
      throw new Error(`同じplatformのmetadataが複数あります: ${metadataKind}`);
    }
    metadataKinds.add(metadataKind);
  }
  if (!metadataKinds.has(".zip") || !metadataKinds.has(".exe")) {
    throw new Error("macOSとWindowsのmetadataが必要です");
  }
}
