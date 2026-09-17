import { createHash } from "node:crypto";
import { lstatSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import type { ReleaseContract, ReleaseManifest, ReleaseAsset } from "./schema.js";
import { parseReleaseContract, parseReleaseManifest } from "./schema.js";

type AssetRole =
  | "macos-zip"
  | "macos-dmg"
  | "macos-metadata"
  | "windows-nsis"
  | "windows-nsis-blockmap"
  | "windows-web-setup"
  | "windows-web-package"
  | "windows-metadata";

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

function classifyAsset(name: string, contract: ReleaseContract): AssetRole {
  const productName = contract.application.identity.productName;
  const version = contract.version;
  const normalSetup = `${productName} Setup ${version}.exe`;
  const webSetup = `${productName} Web Setup ${version}.exe`;
  if (name === "latest-mac.yml") {
    return "macos-metadata";
  }
  if (name === "latest.yml") {
    return "windows-metadata";
  }
  if (name === normalSetup) {
    return "windows-nsis";
  }
  if (name === `${normalSetup}.blockmap`) {
    return "windows-nsis-blockmap";
  }
  if (name === webSetup) {
    return "windows-web-setup";
  }
  if (name === webSetup.replace(/\.exe$/, ".7z")) {
    return "windows-web-package";
  }
  if (name === `${webSetup.replace(/\.exe$/, "")}.nsis.7z`) {
    return "windows-web-package";
  }
  if (name.endsWith(".exe")) {
    if (/web[- _]?setup\.exe$/i.test(name)) {
      return "windows-web-setup";
    }
    if (/setup\.exe$/i.test(name)) {
      return "windows-nsis";
    }
  }
  if (name.endsWith(".blockmap") && /setup\.exe\.blockmap$/i.test(name)) {
    return "windows-nsis-blockmap";
  }
  if (name.endsWith(".7z") && /web[- _]?setup(?:\.nsis)?\.7z$/i.test(name)) {
    return "windows-web-package";
  }
  if (name.endsWith(".zip")) {
    return "macos-zip";
  }
  if (name.endsWith(".dmg")) {
    return "macos-dmg";
  }
  throw new Error(`未知のrelease asset filenameです: ${name}`);
}

function digestFile(path: string): string {
  const information = lstatSync(path);
  if (!information.isFile()) {
    throw new Error(`regular fileではありません: ${path}`);
  }
  if (information.size === 0) {
    throw new Error(`空のassetは許可されません: ${path}`);
  }
  const digest = createHash("sha256").update(readFileSync(path)).digest("hex");
  return `sha256:${digest}`;
}

/** assets directoryからrelease manifestを生成します。 */
export function createReleaseManifest(
  releaseContractValue: unknown,
  assetsDirectory: string
): ReleaseManifest {
  const contract = parseReleaseContract(releaseContractValue);
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
  const roles = new Set<string>();
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
    const path = join(assetsDirectory, entry.name);
    const information = lstatSync(path);
    assets.push({
      name: entry.name,
      size: information.size,
      digest: digestFile(path),
      role
    });
  }
  return parseReleaseManifest({
    schemaVersion: 1,
    appId: contract.appId,
    repository: contract.repository,
    tag: contract.tag,
    version: contract.version,
    assets
  });
}

/** release setの必須roleがすべて揃っていることを検証します。 */
export function assertReleaseSetComplete(manifestValue: unknown): void {
  const manifest = parseReleaseManifest(manifestValue);
  const roles = new Set(manifest.assets.map((asset) => asset.role));
  const missing = requiredRoles.filter((role) => !roles.has(role));
  if (missing.length > 0) {
    throw new Error(`release setの必須asset roleが不足しています: ${missing.join(", ")}`);
  }
}
