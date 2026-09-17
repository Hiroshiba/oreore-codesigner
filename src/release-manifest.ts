import { createHash } from "node:crypto";
import { lstatSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { parse as parseYaml } from "yaml";
import type { ReleaseContract, ReleaseManifest, ReleaseAsset } from "./schema.js";
import { parseReleaseContract, parseReleaseManifest } from "./schema.js";
import { assertReleaseContractCurrent } from "./source-validation.js";
import { z } from "zod";

type AssetRole = ReleaseAsset["role"];
type MetadataRole = "macos-metadata" | "windows-metadata" | "windows-web-metadata";

const requiredRoles: AssetRole[] = [
  "macos-zip",
  "macos-dmg",
  "macos-metadata",
  "windows-nsis",
  "windows-nsis-blockmap",
  "windows-web-setup",
  "windows-web-package",
  "windows-metadata"
];

const metadataUrlSchema = z
  .string()
  .min(1, "metadata URLが空です")
  .refine(
    (value) => !value.startsWith("/") && !value.includes("\\") && !value.includes(":"),
    "metadata URLが不正です"
  )
  .refine((value) => !value.includes("://") && !value.includes(".."), "metadata URLが不正です");
const metadataSha512Schema = z
  .string()
  .regex(/^(?:[0-9A-Fa-f]{128}|[A-Za-z0-9+/]{86}==)$/, "metadata sha512が不正です");
const metadataFileSchema = z
  .object({
    url: metadataUrlSchema,
    size: z.number().int().nonnegative().optional(),
    sha512: metadataSha512Schema,
    blockMapSize: z.number().int().nonnegative().optional()
  })
  .strict();
const metadataPackageSchema = z
  .object({
    file: metadataUrlSchema,
    path: metadataUrlSchema,
    size: z.number().int().nonnegative(),
    sha512: metadataSha512Schema
  })
  .strict();
const updateMetadataSchema = z
  .object({
    version: z.string().min(1),
    files: z.array(metadataFileSchema).min(1),
    path: metadataUrlSchema,
    sha512: metadataSha512Schema,
    packages: z.record(metadataPackageSchema).optional(),
    releaseDate: z.string().optional(),
    stagingPercentage: z.number().optional(),
    minimumSystemVersion: z.string().optional(),
    sha2: z.string().optional(),
    isAdminRightsRequired: z.boolean().optional()
  })
  .strict();

type UpdateMetadata = z.infer<typeof updateMetadataSchema>;

function channelMetadataName(contract: ReleaseContract, suffix: string): string {
  return `${contract.application.release.channel}${suffix}.yml`;
}

function sanitizedPackageName(contract: ReleaseContract): string {
  return contract.application.packageName.replace(/[\\/:*?"<>|]/gu, "");
}

function expectedNames(contract: ReleaseContract): {
  macosZip: string;
  macosDmg: string;
  macosMetadata: string;
  windowsNsis: string;
  windowsNsisBlockmap: string;
  windowsWebSetup: string;
  windowsWebPackage: string;
  windowsMetadata: string;
  windowsWebMetadata: string;
} {
  const productName = contract.application.identity.productName;
  const version = contract.version;
  const architecture = contract.application.macos.architecture;
  const windowsArchitecture = contract.application.windows.architecture;
  const windowsNsis = `${productName} Setup ${version}.exe`;
  const windowsWebSetup = `${productName} Web Setup ${version}.exe`;
  return {
    macosZip: `${productName}-${version}-${architecture}.zip`,
    macosDmg: `${productName}-${version}-${architecture}.dmg`,
    macosMetadata: channelMetadataName(contract, "-mac"),
    windowsNsis,
    windowsNsisBlockmap: `${windowsNsis}.blockmap`,
    windowsWebSetup,
    windowsWebPackage: `${sanitizedPackageName(contract)}-${version}-${windowsArchitecture}.nsis.7z`,
    windowsMetadata: channelMetadataName(contract, ""),
    windowsWebMetadata: channelMetadataName(contract, "-web")
  };
}

/** manifestのasset filenameが中央設定から導出した名前と一致することを検証します。 */
export function assertManifestAssetNames(contractValue: unknown, manifestValue: unknown): void {
  const contract = parseReleaseContract(contractValue);
  const manifest = parseReleaseManifest(manifestValue);
  const names = expectedNames(contract);
  const expectedByRole: Record<AssetRole, string> = {
    "macos-zip": names.macosZip,
    "macos-dmg": names.macosDmg,
    "macos-metadata": names.macosMetadata,
    "windows-nsis": names.windowsNsis,
    "windows-nsis-blockmap": names.windowsNsisBlockmap,
    "windows-web-setup": names.windowsWebSetup,
    "windows-web-package": names.windowsWebPackage,
    "windows-metadata": names.windowsMetadata,
    "windows-web-metadata": names.windowsWebMetadata
  };
  const roles = new Set<AssetRole>();
  const namesSeen = new Set<string>();
  for (const asset of manifest.assets) {
    if (roles.has(asset.role)) {
      throw new Error(`manifestのasset roleが重複しています: ${asset.role}`);
    }
    roles.add(asset.role);
    const nameKey = asset.name.toLowerCase();
    if (namesSeen.has(nameKey)) {
      throw new Error(`manifestのasset filenameが重複しています: ${asset.name}`);
    }
    namesSeen.add(nameKey);
    if (asset.name !== expectedByRole[asset.role]) {
      throw new Error(`manifestのasset filenameが中央設定と一致しません: ${asset.name}`);
    }
  }
  if (manifest.metadata !== undefined) {
    const metadataRoles = new Set<MetadataRole>();
    for (const metadata of manifest.metadata) {
      if (metadataRoles.has(metadata.role)) {
        throw new Error(`manifestのmetadata roleが重複しています: ${metadata.role}`);
      }
      metadataRoles.add(metadata.role);
      if (metadata.name !== expectedByRole[metadata.role]) {
        throw new Error(`manifestのmetadata filenameが中央設定と一致しません: ${metadata.name}`);
      }
    }
  }
}

function classifyAsset(name: string, contract: ReleaseContract): AssetRole {
  const names = expectedNames(contract);
  if (name === names.macosZip) {
    return "macos-zip";
  }
  if (name === names.macosDmg) {
    return "macos-dmg";
  }
  if (name === names.macosMetadata) {
    return "macos-metadata";
  }
  if (name === names.windowsNsis) {
    return "windows-nsis";
  }
  if (name === names.windowsNsisBlockmap) {
    return "windows-nsis-blockmap";
  }
  if (name === names.windowsWebSetup) {
    return "windows-web-setup";
  }
  if (name === names.windowsWebPackage) {
    return "windows-web-package";
  }
  if (name === names.windowsMetadata) {
    return "windows-metadata";
  }
  if (name === names.windowsWebMetadata) {
    return "windows-web-metadata";
  }
  throw new Error(`中央設定から導出できないrelease asset filenameです: ${name}`);
}

function hashFile(path: string): { digest: string; sha512: string; size: number } {
  const information = lstatSync(path);
  if (information.isSymbolicLink() || !information.isFile()) {
    throw new Error(`regular fileではありません: ${path}`);
  }
  if (information.size === 0) {
    throw new Error(`空のassetは許可されません: ${path}`);
  }
  const contents = readFileSync(path);
  return {
    digest: `sha256:${createHash("sha256").update(contents).digest("hex")}`,
    sha512: createHash("sha512").update(contents).digest("base64"),
    size: information.size
  };
}

function assertAssetsDirectory(path: string): void {
  const information = lstatSync(path);
  if (information.isSymbolicLink() || !information.isDirectory()) {
    throw new Error(`assets-directoryがディレクトリではありません: ${path}`);
  }
}

function assertSha512Matches(actual: string, expected: string, assetName: string): void {
  if (actual === expected) {
    return;
  }
  if (/^[0-9A-Fa-f]{128}$/u.test(actual) && actual.toLowerCase() === expected.toLowerCase()) {
    return;
  }
  if (/^[0-9A-Fa-f]{128}$/u.test(expected)) {
    const expectedBase64 = Buffer.from(expected, "hex").toString("base64");
    if (expectedBase64 === actual) {
      return;
    }
  }
  if (/^[A-Za-z0-9+/]{86}==$/u.test(actual) && /^[A-Za-z0-9+/]{86}==$/u.test(expected)) {
    if (Buffer.from(actual, "base64").equals(Buffer.from(expected, "base64"))) {
      return;
    }
  }
  throw new Error(`metadata sha512がassetと一致しません: ${assetName}`);
}

function metadataAssetMap(assets: ReleaseAsset[]): Map<string, ReleaseAsset> {
  return new Map(assets.map((asset) => [asset.name, asset]));
}

function assertMetadataAsset(
  assetMap: Map<string, ReleaseAsset>,
  name: string,
  size: number | undefined,
  sha512: string
): ReleaseAsset {
  const asset = assetMap.get(name);
  if (asset === undefined) {
    throw new Error(`metadataがmanifestにないassetを参照しています: ${name}`);
  }
  if (size !== undefined && asset.size !== size) {
    throw new Error(`metadata sizeがassetと一致しません: ${name}`);
  }
  if (asset.sha512 === undefined) {
    throw new Error(`manifestにsha512がありません: ${name}`);
  }
  assertSha512Matches(asset.sha512, sha512, name);
  return asset;
}

function parseMetadata(path: string): UpdateMetadata {
  const source = readFileSync(path, "utf8");
  return updateMetadataSchema.parse(parseYaml(source));
}

function assertMetadataReferences(
  metadataRole: MetadataRole,
  metadata: UpdateMetadata,
  contract: ReleaseContract,
  assets: ReleaseAsset[]
): { path: string; files: string[] } {
  const names = expectedNames(contract);
  const assetMap = metadataAssetMap(assets);
  const fileNames: string[] = [];
  const fileNamesSeen = new Set<string>();
  for (const file of metadata.files) {
    if (fileNamesSeen.has(file.url)) {
      throw new Error(`metadataのfiles URLが重複しています: ${file.url}`);
    }
    fileNamesSeen.add(file.url);
    assertMetadataAsset(assetMap, file.url, file.size, file.sha512);
    fileNames.push(file.url);
  }
  assertMetadataAsset(
    assetMap,
    metadata.path,
    assetMap.get(metadata.path)?.size ?? 0,
    metadata.sha512
  );
  if (metadata.version !== contract.version) {
    throw new Error(`metadata versionがcontractと一致しません: ${metadata.version}`);
  }
  if (metadataRole === "macos-metadata") {
    if (!fileNames.includes(names.macosZip)) {
      throw new Error("macOS metadataがZIPを参照していません");
    }
    for (const name of fileNames) {
      const role = assetMap.get(name)?.role;
      if (role !== "macos-zip" && role !== "macos-dmg") {
        throw new Error("macOS metadataがmacOS以外のassetを参照しています");
      }
    }
    if (metadata.path !== names.macosZip) {
      throw new Error("macOS metadataのpathはZIPでなければなりません");
    }
  }
  if (metadataRole === "windows-metadata") {
    if (metadata.path !== names.windowsNsis || !fileNames.includes(names.windowsNsis)) {
      throw new Error("Windows metadataは通常NSISだけを参照しなければなりません");
    }
    for (const name of fileNames) {
      if (assetMap.get(name)?.role !== "windows-nsis") {
        throw new Error("Windows metadataが通常NSIS以外を参照しています");
      }
    }
    if (metadata.packages !== undefined) {
      throw new Error("通常NSIS metadataにpackagesは指定できません");
    }
  }
  if (metadataRole === "windows-web-metadata") {
    if (metadata.path !== names.windowsWebSetup || !fileNames.includes(names.windowsWebSetup)) {
      throw new Error("Windows Web metadataはWebSetupを参照しなければなりません");
    }
    for (const name of fileNames) {
      if (assetMap.get(name)?.role !== "windows-web-setup") {
        throw new Error("Windows Web metadataがWebSetup以外のinstallerを参照しています");
      }
    }
    const packages = metadata.packages;
    if (packages === undefined) {
      throw new Error("Windows Web metadataにpackagesがありません");
    }
    const packageNames = Object.entries(packages);
    if (packageNames.length === 0) {
      throw new Error("Windows Web metadataのpackagesが空です");
    }
    for (const [architecture, packageInfo] of packageNames) {
      if (architecture !== contract.application.windows.architecture) {
        throw new Error(`Windows Web metadataのarchitectureが不正です: ${architecture}`);
      }
      if (packageInfo.file !== packageInfo.path || packageInfo.file !== names.windowsWebPackage) {
        throw new Error("Windows Web metadataのpackage filenameが不正です");
      }
      assertMetadataAsset(assetMap, packageInfo.file, packageInfo.size, packageInfo.sha512);
      if (assetMap.get(packageInfo.file)?.role !== "windows-web-package") {
        throw new Error("Windows Web metadataがWeb package以外を参照しています");
      }
    }
  }
  const packageNames =
    metadata.packages === undefined
      ? []
      : Object.values(metadata.packages).map((packageInfo) => packageInfo.file);
  return { path: metadata.path, files: [...fileNames, ...packageNames] };
}

function assertBlockmapPair(manifest: ReleaseManifest): void {
  const installer = manifest.assets.find((asset) => asset.role === "windows-nsis");
  const blockmap = manifest.assets.find((asset) => asset.role === "windows-nsis-blockmap");
  if (installer === undefined || blockmap === undefined) {
    return;
  }
  if (blockmap.name !== `${installer.name}.blockmap`) {
    throw new Error("通常NSIS blockmapがinstallerと対応していません");
  }
}

/** assets directoryからrelease manifestを生成します。 */
export function createReleaseManifest(
  rootDirectory: string,
  releaseContractValue: unknown,
  assetsDirectory: string
): ReleaseManifest;
export function createReleaseManifest(
  releaseContractValue: unknown,
  assetsDirectory: string
): ReleaseManifest;
export function createReleaseManifest(
  first: unknown,
  second: unknown,
  third?: string
): ReleaseManifest {
  let rootDirectory: string;
  let releaseContractValue: unknown;
  let assetsDirectory: string;
  if (third === undefined) {
    rootDirectory = process.cwd();
    releaseContractValue = first;
    if (typeof second !== "string") {
      throw new Error("assets-directoryが不正です");
    }
    assetsDirectory = second;
  } else {
    if (typeof first !== "string" || typeof third !== "string") {
      throw new Error("引数が不正です");
    }
    rootDirectory = first;
    releaseContractValue = second;
    assetsDirectory = third;
  }
  const contract = assertReleaseContractCurrent(rootDirectory, releaseContractValue);
  assertAssetsDirectory(assetsDirectory);
  const entries = readdirSync(assetsDirectory, { withFileTypes: true });
  entries.sort((left, right) => {
    if (left.name < right.name) {
      return -1;
    }
    if (left.name > right.name) {
      return 1;
    }
    return 0;
  });
  const names = new Set<string>();
  const roles = new Set<AssetRole>();
  const assets: ReleaseAsset[] = [];
  for (const entry of entries) {
    if (entry.isSymbolicLink() || !entry.isFile()) {
      throw new Error(`regular file以外のassetは許可されません: ${entry.name}`);
    }
    const nameKey = entry.name.toLowerCase();
    if (names.has(nameKey)) {
      throw new Error(`asset filenameが重複しています: ${entry.name}`);
    }
    names.add(nameKey);
    const role = classifyAsset(entry.name, contract);
    if (roles.has(role)) {
      throw new Error(`asset roleが重複しています: ${role}`);
    }
    roles.add(role);
    const filePath = join(assetsDirectory, entry.name);
    const hashes = hashFile(filePath);
    assets.push({
      name: entry.name,
      size: hashes.size,
      digest: hashes.digest,
      role,
      sha512: hashes.sha512
    });
  }
  const metadata = assets
    .filter(
      (asset): asset is ReleaseAsset & { role: MetadataRole } =>
        asset.role === "macos-metadata" ||
        asset.role === "windows-metadata" ||
        asset.role === "windows-web-metadata"
    )
    .map((asset) => {
      const parsed = parseMetadata(join(assetsDirectory, asset.name));
      const references = assertMetadataReferences(asset.role, parsed, contract, assets);
      return { role: asset.role, name: asset.name, ...references };
    });
  const manifest = parseReleaseManifest({
    schemaVersion: 1,
    appId: contract.appId,
    repository: contract.repository,
    tag: contract.tag,
    version: contract.version,
    assets,
    metadata
  });
  assertBlockmapPair(manifest);
  return manifest;
}

type RequiredMetadataNames = {
  macosZip: string;
  windowsNsis: string;
  windowsWebSetup: string;
  windowsWebPackage: string;
};

function assertMetadataSummary(
  manifest: ReleaseManifest,
  contractNames: RequiredMetadataNames
): void {
  if (manifest.metadata === undefined) {
    throw new Error("manifestにmetadata参照がありません");
  }
  const byRole = new Map(manifest.metadata.map((metadata) => [metadata.role, metadata]));
  const macosMetadata = byRole.get("macos-metadata");
  const windowsMetadata = byRole.get("windows-metadata");
  if (macosMetadata === undefined || windowsMetadata === undefined) {
    throw new Error("manifestのmetadata roleが不足しています");
  }
  if (
    macosMetadata.path !== contractNames.macosZip ||
    !macosMetadata.files.includes(contractNames.macosZip) ||
    macosMetadata.files.some(
      (name) =>
        name !== contractNames.macosZip &&
        name !== manifest.assets.find((asset) => asset.role === "macos-dmg")?.name
    )
  ) {
    throw new Error("manifestのmacOS metadata参照が不正です");
  }
  if (
    windowsMetadata.path !== contractNames.windowsNsis ||
    !windowsMetadata.files.includes(contractNames.windowsNsis) ||
    windowsMetadata.files.some(
      (name) =>
        name !== contractNames.windowsNsis ||
        name === contractNames.windowsWebSetup ||
        name === contractNames.windowsWebPackage
    )
  ) {
    throw new Error("manifestのWindows metadata参照が不正です");
  }
  const windowsWebMetadata = byRole.get("windows-web-metadata");
  if (windowsWebMetadata !== undefined) {
    if (
      windowsWebMetadata.path !== contractNames.windowsWebSetup ||
      !windowsWebMetadata.files.includes(contractNames.windowsWebSetup) ||
      !windowsWebMetadata.files.includes(contractNames.windowsWebPackage) ||
      windowsWebMetadata.files.some(
        (name) => name !== contractNames.windowsWebSetup && name !== contractNames.windowsWebPackage
      )
    ) {
      throw new Error("manifestのWindows Web metadata参照が不正です");
    }
  }
}

/** release setの必須roleとmetadata参照がすべて揃っていることを検証します。 */
export function assertReleaseSetComplete(manifestValue: unknown): void {
  const manifest = parseReleaseManifest(manifestValue);
  const roles = new Set(manifest.assets.map((asset) => asset.role));
  const missing = requiredRoles.filter((role) => !roles.has(role));
  if (missing.length > 0) {
    throw new Error(`release setの必須asset roleが不足しています: ${missing.join(", ")}`);
  }
  assertBlockmapPair(manifest);
  const contractNames = {
    macosZip: manifest.assets.find((asset) => asset.role === "macos-zip")?.name,
    windowsNsis: manifest.assets.find((asset) => asset.role === "windows-nsis")?.name,
    windowsWebSetup: manifest.assets.find((asset) => asset.role === "windows-web-setup")?.name,
    windowsWebPackage: manifest.assets.find((asset) => asset.role === "windows-web-package")?.name
  };
  if (
    contractNames.macosZip === undefined ||
    contractNames.windowsNsis === undefined ||
    contractNames.windowsWebSetup === undefined ||
    contractNames.windowsWebPackage === undefined
  ) {
    throw new Error("release setの必須assetが不足しています");
  }
  const requiredNames: RequiredMetadataNames = {
    macosZip: contractNames.macosZip,
    windowsNsis: contractNames.windowsNsis,
    windowsWebSetup: contractNames.windowsWebSetup,
    windowsWebPackage: contractNames.windowsWebPackage
  };
  assertMetadataSummary(manifest, requiredNames);
}
