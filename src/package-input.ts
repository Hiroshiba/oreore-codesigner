import { lstatSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, extname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parse as parseYaml } from "yaml";
import { z } from "zod";
import { loadSigningConfig } from "./config.js";
import {
  type PackageInput,
  parseAppId,
  parseArtifactName,
  parsePackageInput,
  parsePackageManager,
  parseSemVer,
  parseRelativePath
} from "./schema.js";
import {
  assertNoSymlinkAncestors,
  assertNoSymlinkPath,
  assertRealPathWithin
} from "./path-safety.js";

export type PackageInputPlatform = "macos" | "windows";

const sourcePackageSchema = z
  .object({
    name: z.string(),
    version: z.string(),
    packageManager: z.string()
  })
  .passthrough();

const targetSchema = z.union([
  z.string(),
  z
    .object({
      target: z.string().optional(),
      arch: z.union([z.string(), z.array(z.string())]).optional()
    })
    .passthrough()
]);
const targetListSchema = z.union([targetSchema, z.array(targetSchema)]);
const sourceMacSchema = z
  .object({
    target: targetListSchema.optional(),
    entitlements: z.string().optional(),
    entitlementsInherit: z.string().optional(),
    hardenedRuntime: z.boolean().optional(),
    gatekeeperAssess: z.boolean().optional(),
    artifactName: z.string().optional()
  })
  .passthrough();
const sourceWinSchema = z
  .object({
    target: targetListSchema.optional(),
    executableName: z.string().optional(),
    publisherName: z.string().optional(),
    artifactName: z.string().optional()
  })
  .passthrough();
const sourceNsisSchema = z
  .object({
    oneClick: z.boolean().optional(),
    perMachine: z.boolean().optional(),
    allowToChangeInstallationDirectory: z.boolean().optional(),
    allowElevation: z.boolean().optional(),
    createDesktopShortcut: z
      .union([z.boolean(), z.enum(["always", "never", "onLogin"])])
      .optional(),
    createStartMenuShortcut: z
      .union([z.boolean(), z.enum(["always", "never", "onLogin"])])
      .optional(),
    createQuickLaunchShortcut: z
      .union([z.boolean(), z.enum(["always", "never", "onLogin"])])
      .optional(),
    shortcutName: z.string().optional(),
    menuCategory: z.string().optional(),
    uninstallDisplayName: z.string().optional(),
    deleteAppDataOnUninstall: z.boolean().optional(),
    runAfterFinish: z.boolean().optional(),
    artifactName: z.string().optional(),
    guid: z.string().optional()
  })
  .passthrough();
const sourceBuilderSchema = z
  .object({
    appId: z.string().optional(),
    productName: z.string().optional(),
    artifactName: z.string().optional(),
    mac: sourceMacSchema.optional(),
    win: sourceWinSchema.optional(),
    nsis: sourceNsisSchema.optional(),
    nsisWeb: sourceNsisSchema.optional()
  })
  .passthrough();

type SourceBuilder = z.infer<typeof sourceBuilderSchema>;
type SourceNsis = z.infer<typeof sourceNsisSchema>;

function globalPublisherName(): string | undefined {
  const centralRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
  const signing = loadSigningConfig(centralRoot);
  return signing.windows.configured === true ? signing.windows.displayName : undefined;
}

function isErrnoException(error: unknown): error is NodeJS.ErrnoException {
  return error instanceof Error && "code" in error && typeof error.code === "string";
}

function assertDirectory(path: string, message: string): void {
  assertNoSymlinkPath(path, message);
  let information;
  try {
    information = lstatSync(path);
  } catch (error) {
    throw new Error(`${message}: ${path}`, { cause: error });
  }
  if (!information.isDirectory() || information.isSymbolicLink()) {
    throw new Error(`${message}: ${path}`);
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
  if (!information.isFile() || information.isSymbolicLink()) {
    throw new Error(`${message}: ${path}`);
  }
}

function readRegularFile(path: string, message: string): Buffer {
  assertRegularFile(path, message);
  try {
    return readFileSync(path);
  } catch (error) {
    throw new Error(`${message}: ${path}`, { cause: error });
  }
}

function readJson(path: string): unknown {
  const source = readRegularFile(path, "JSONファイルがありません").toString("utf8");
  try {
    return JSON.parse(source);
  } catch (error) {
    throw new Error(`JSONを解析できません: ${path}`, { cause: error });
  }
}

function readYaml(path: string): unknown {
  const source = readRegularFile(path, "electron-builder設定がありません").toString("utf8");
  try {
    return parseYaml(source);
  } catch (error) {
    throw new Error(`electron-builder設定を解析できません: ${path}`, { cause: error });
  }
}

function findBuilderPath(sourceRoot: string): string {
  const candidates = ["electron-builder.yml", "electron-builder.yaml"];
  const existing: string[] = [];
  for (const name of candidates) {
    const path = join(sourceRoot, name);
    try {
      lstatSync(path);
      existing.push(path);
    } catch (error) {
      if (!isErrnoException(error) || error.code !== "ENOENT") {
        throw new Error(`electron-builder設定を確認できません: ${path}`, { cause: error });
      }
    }
  }
  if (existing.length !== 1) {
    throw new Error(
      "source rootにはelectron-builder.ymlまたはelectron-builder.yamlを一つだけ置いてください"
    );
  }
  const path = existing[0];
  if (path === undefined) {
    throw new Error("electron-builder設定がありません");
  }
  assertRegularFile(path, "electron-builder設定がregular fileではありません");
  return path;
}

function parseSourcePackage(path: string): { name: string; version: string } {
  const value = sourcePackageSchema.parse(readJson(path));
  if (Object.hasOwn(value, "build")) {
    throw new Error("package.json.buildとの二重定義は許可されません");
  }
  const name = z
    .string()
    .regex(/^(?:@[A-Za-z0-9._-]+\/)?[A-Za-z0-9._-]+$/)
    .parse(value.name);
  const version = parseSemVer(value.version);
  parsePackageManager(value.packageManager);
  return { name, version };
}

function parseSourceBuilder(path: string): SourceBuilder {
  const value = sourceBuilderSchema.parse(readYaml(path));
  if (value.appId === undefined || value.productName === undefined) {
    throw new Error("electron-builder設定のappIdとproductNameが必要です");
  }
  parseAppId(value.appId);
  z.string().min(1).parse(value.productName);
  return value;
}

function targetArchitectures(value: z.infer<typeof targetListSchema> | undefined): string[] {
  if (value === undefined) {
    return [];
  }
  const targets = Array.isArray(value) ? value : [value];
  const architectures: string[] = [];
  for (const target of targets) {
    if (typeof target === "string") {
      continue;
    }
    if (target.arch === undefined) {
      continue;
    }
    const targetArchitectures = Array.isArray(target.arch) ? target.arch : [target.arch];
    architectures.push(...targetArchitectures);
  }
  return architectures;
}

function resolveArchitecture(
  value: z.infer<typeof targetListSchema> | undefined,
  platform: PackageInputPlatform
): "x64" | "arm64" {
  const architectures = [...new Set(targetArchitectures(value))];
  if (architectures.length === 0) {
    return "x64";
  }
  if (architectures.length !== 1) {
    throw new Error(`${platform}のarchitectureを一意に決定できません`);
  }
  const architecture = architectures[0];
  if (architecture !== "x64" && architecture !== "arm64") {
    throw new Error(`${platform}のarchitectureが不正です: ${architecture}`);
  }
  return architecture;
}

function copyInputFile(sourceRoot: string, sourceRelativePath: string, outputPath: string): void {
  const sourcePath = resolve(sourceRoot, sourceRelativePath);
  assertRealPathWithin(sourceRoot, sourcePath, "entitlementsがsource root外を参照しています");
  const contents = readRegularFile(sourcePath, "entitlementsがregular fileではありません");
  try {
    writeFileSync(outputPath, contents, { flag: "wx", mode: 0o600 });
  } catch (error) {
    throw new Error(`entitlementsを書き込めません: ${outputPath}`, { cause: error });
  }
}

function createOutputDirectory(path: string): string {
  const outputPath = resolve(path);
  assertNoSymlinkAncestors(outputPath, "output directoryの親pathにsymlinkを指定できません");
  const parentPath = dirname(outputPath);
  assertDirectory(parentPath, "output directoryの親pathがディレクトリではありません");
  try {
    lstatSync(outputPath);
  } catch (error) {
    if (!isErrnoException(error) || error.code !== "ENOENT") {
      throw new Error(`output directoryを確認できません: ${outputPath}`, { cause: error });
    }
    try {
      mkdirSync(outputPath, { mode: 0o700 });
      return outputPath;
    } catch (mkdirError) {
      throw new Error(`output directoryを作成できません: ${outputPath}`, { cause: mkdirError });
    }
  }
  throw new Error(`output directoryは開始時に存在してはいけません: ${outputPath}`);
}

function assertPlistValue(values: Map<string, string>, key: string, expected: string): void {
  const actual = values.get(key);
  if (actual !== expected) {
    throw new Error(`Info.plistの${key}がpackage inputと一致しません`);
  }
}

function decodeXmlText(value: string): string {
  return value
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">")
    .replaceAll("&quot;", '"')
    .replaceAll("&apos;", "'")
    .replaceAll("&amp;", "&");
}

function readInfoPlist(path: string): Map<string, string> {
  const source = readRegularFile(path, "Info.plistがregular fileではありません").toString("utf8");
  const values = new Map<string, string>();
  const pattern = /<key>([^<]+)<\/key>\s*<string>([^<]*)<\/string>/gu;
  for (const match of source.matchAll(pattern)) {
    const key = match[1];
    const value = match[2];
    if (key === undefined || value === undefined) {
      throw new Error("Info.plistのentryを解析できません");
    }
    if (values.has(key)) {
      throw new Error(`Info.plistのkeyが重複しています: ${key}`);
    }
    values.set(decodeXmlText(key), decodeXmlText(value));
  }
  return values;
}

function validateMacPrepackaged(
  prepackagedRoot: string,
  appId: string,
  productName: string,
  version: string
): void {
  const entries = readdirSync(prepackagedRoot, { withFileTypes: true });
  const apps = entries.filter((entry) => entry.name.toLowerCase().endsWith(".app"));
  if (apps.length !== 1) {
    throw new Error("prepackaged directoryの.appを一意に決定できません");
  }
  const app = apps[0];
  if (app === undefined || !app.isDirectory() || app.isSymbolicLink()) {
    throw new Error("prepackagedの.appがdirectoryではありません");
  }
  const infoPath = join(prepackagedRoot, app.name, "Contents", "Info.plist");
  const values = readInfoPlist(infoPath);
  assertPlistValue(values, "CFBundleIdentifier", appId);
  const bundleNames = [values.get("CFBundleName"), values.get("CFBundleDisplayName")].filter(
    (value): value is string => value !== undefined
  );
  if (bundleNames.length === 0 || bundleNames.some((value) => value !== productName)) {
    throw new Error("Info.plistのproductNameがpackage inputと一致しません");
  }
  const shortVersion = values.get("CFBundleShortVersionString");
  const bundleVersion = values.get("CFBundleVersion");
  if (shortVersion !== undefined && shortVersion !== version) {
    throw new Error("Info.plistのCFBundleShortVersionStringがpackage inputと一致しません");
  }
  if (bundleVersion !== undefined && bundleVersion !== version) {
    throw new Error("Info.plistのCFBundleVersionがpackage inputと一致しません");
  }
  if (shortVersion === undefined && bundleVersion === undefined) {
    throw new Error("Info.plistにversionがありません");
  }
}

function isPeFile(contents: Buffer): boolean {
  if (contents.length < 0x40 || contents.readUInt16LE(0) !== 0x5a4d) {
    return false;
  }
  const peOffset = contents.readUInt32LE(0x3c);
  return (
    peOffset + 4 <= contents.length &&
    contents.subarray(peOffset, peOffset + 4).equals(Buffer.from("PE\u0000\u0000"))
  );
}

function readUtf16Strings(contents: Buffer): string[] {
  const result: string[] = [];
  for (let index = 0; index + 2 < contents.length; index += 2) {
    let end = index;
    while (end + 1 < contents.length && contents.readUInt16LE(end) !== 0) {
      end += 2;
    }
    if (end === index || end - index < 4) {
      continue;
    }
    const text = contents.subarray(index, end).toString("utf16le");
    if (/^[\u0020-\u007e]{2,255}$/u.test(text)) {
      result.push(text);
    }
    index = end;
  }
  return result;
}

function versionInfoValue(strings: string[], key: string): string | undefined {
  const index = strings.indexOf(key);
  return index < 0 ? undefined : strings[index + 1];
}

function validateWindowsPrepackaged(
  prepackagedRoot: string,
  executableName: string | undefined,
  productName: string
): void {
  const entries = readdirSync(prepackagedRoot, { withFileTypes: true });
  const executableEntries = entries.filter(
    (entry) =>
      entry.isFile() && !entry.isSymbolicLink() && extname(entry.name).toLowerCase() === ".exe"
  );
  if (executableEntries.length === 0) {
    throw new Error("prepackaged directoryにexeがありません");
  }
  const peEntries = executableEntries.filter((entry) =>
    isPeFile(readRegularFile(join(prepackagedRoot, entry.name), "exeを読み込めません"))
  );
  const matchingEntries =
    executableName === undefined
      ? peEntries
      : executableEntries.filter(
          (entry) => entry.name.toLowerCase() === executableName.toLowerCase()
        );
  const mainEntry = matchingEntries.length === 1 ? matchingEntries[0] : undefined;
  if (mainEntry === undefined) {
    throw new Error("prepackagedの主exeを一意に決定できません");
  }
  const contents = readRegularFile(join(prepackagedRoot, mainEntry.name), "主exeを読み込めません");
  if (!isPeFile(contents)) {
    throw new Error("主exeがPE fileではありません");
  }
  const strings = readUtf16Strings(contents);
  const versionInfoProductName = versionInfoValue(strings, "ProductName");
  if (versionInfoProductName !== undefined && versionInfoProductName !== productName) {
    throw new Error("主exeのVersionInfo ProductNameがpackage inputと一致しません");
  }
  if (executableName !== undefined) {
    const originalFilename = versionInfoValue(strings, "OriginalFilename");
    if (
      originalFilename !== undefined &&
      originalFilename.toLowerCase() !== executableName.toLowerCase()
    ) {
      throw new Error("主exeのVersionInfo OriginalFilenameがsource executableNameと一致しません");
    }
  }
}

function nsisOptions(value: SourceNsis | undefined): Record<string, unknown> | undefined {
  if (value === undefined) {
    return undefined;
  }
  const parsed: Record<string, unknown> = {};
  const allowedKeys = new Set([
    "oneClick",
    "perMachine",
    "allowToChangeInstallationDirectory",
    "allowElevation",
    "createDesktopShortcut",
    "createStartMenuShortcut",
    "createQuickLaunchShortcut",
    "shortcutName",
    "menuCategory",
    "uninstallDisplayName",
    "deleteAppDataOnUninstall",
    "runAfterFinish",
    "artifactName",
    "guid"
  ]);
  for (const [key, item] of Object.entries(value)) {
    if (allowedKeys.has(key) && item !== undefined) {
      parsed[key] = item;
    }
  }
  return parsed;
}

function parseOptionalArtifactName(value: string | undefined): string | undefined {
  if (value === undefined) {
    return undefined;
  }
  return parseArtifactName(value);
}

function buildMacInput(
  sourceRoot: string,
  sourcePackage: { name: string; version: string },
  builder: SourceBuilder,
  prepackagedRoot: string,
  outputRoot: string
): PackageInput {
  const mac = builder.mac;
  const architecture = resolveArchitecture(mac?.target, "macos");
  const appId = parseAppId(builder.appId ?? "");
  const productName = z.string().min(1).parse(builder.productName);
  validateMacPrepackaged(prepackagedRoot, appId, productName, sourcePackage.version);
  const entitlements = mac?.entitlements;
  const entitlementsInherit = mac?.entitlementsInherit;
  if (entitlements !== undefined) {
    const sourcePath = resolve(sourceRoot, parseRelativePath(entitlements));
    assertRealPathWithin(sourceRoot, sourcePath, "entitlementsがsource root外を参照しています");
    copyInputFile(sourceRoot, entitlements, join(outputRoot, "entitlements.plist"));
  }
  if (entitlementsInherit !== undefined) {
    const sourcePath = resolve(sourceRoot, parseRelativePath(entitlementsInherit));
    assertRealPathWithin(
      sourceRoot,
      sourcePath,
      "entitlementsInheritがsource root外を参照しています"
    );
    copyInputFile(sourceRoot, entitlementsInherit, join(outputRoot, "entitlements-inherit.plist"));
  }
  const artifactName = parseOptionalArtifactName(mac?.artifactName ?? builder.artifactName);
  const macInput = {
    architecture,
    ...(artifactName === undefined ? {} : { artifactName }),
    ...(entitlements === undefined ? {} : { entitlements: "entitlements.plist" }),
    ...(entitlementsInherit === undefined
      ? {}
      : { entitlementsInherit: "entitlements-inherit.plist" }),
    ...(mac?.hardenedRuntime === undefined ? {} : { hardenedRuntime: mac.hardenedRuntime }),
    ...(mac?.gatekeeperAssess === undefined ? {} : { gatekeeperAssess: mac.gatekeeperAssess })
  };
  return parsePackageInput({
    platform: "macos",
    name: sourcePackage.name,
    version: sourcePackage.version,
    appId,
    productName,
    macos: macInput
  });
}

function buildWindowsInput(
  sourcePackage: { name: string; version: string },
  builder: SourceBuilder,
  prepackagedRoot: string
): PackageInput {
  const win = builder.win;
  const appId = parseAppId(builder.appId ?? "");
  const productName = z.string().min(1).parse(builder.productName);
  const architecture = resolveArchitecture(win?.target, "windows");
  if (architecture !== "x64") {
    throw new Error("Windows architectureはx64でなければなりません");
  }
  const executableName = win?.executableName;
  validateWindowsPrepackaged(prepackagedRoot, executableName, productName);
  const nsis = nsisOptions(builder.nsis);
  const nsisWeb = nsisOptions(builder.nsisWeb);
  const sourceGuid = builder.nsis?.guid ?? builder.nsisWeb?.guid;
  if (
    builder.nsis?.guid !== undefined &&
    builder.nsisWeb?.guid !== undefined &&
    builder.nsis.guid !== builder.nsisWeb.guid
  ) {
    throw new Error("NSISとNSIS WebのGUIDが一致しません");
  }
  const artifactName = parseOptionalArtifactName(win?.artifactName ?? builder.artifactName);
  const sourcePublisherName = win?.publisherName;
  const configuredPublisherName = globalPublisherName();
  if (sourcePublisherName !== undefined && configuredPublisherName === undefined) {
    throw new Error("source publisherNameを照合するglobal signing displayNameがありません");
  }
  if (
    sourcePublisherName !== undefined &&
    configuredPublisherName !== undefined &&
    sourcePublisherName !== configuredPublisherName
  ) {
    throw new Error("source publisherNameとglobal signing displayNameが一致しません");
  }
  const windowsInput = {
    architecture,
    ...(executableName === undefined ? {} : { executableName }),
    ...(configuredPublisherName === undefined ? {} : { publisherName: configuredPublisherName }),
    ...(artifactName === undefined ? {} : { artifactName }),
    ...(sourceGuid === undefined
      ? {}
      : {
          guid: z
            .string()
            .regex(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/)
            .parse(sourceGuid)
        }),
    ...(nsis === undefined ? {} : { nsis }),
    ...(nsisWeb === undefined ? {} : { nsisWeb })
  };
  return parsePackageInput({
    platform: "windows",
    name: sourcePackage.name,
    version: sourcePackage.version,
    appId,
    productName,
    windows: windowsInput
  });
}

/** sourceのpackage.jsonとbuilder設定、prepackaged本体から一時package inputを作成します。 */
export function createPackageInput(
  sourceDirectory: string,
  prepackagedDirectory: string,
  platform: PackageInputPlatform,
  outputDirectory: string
): PackageInput {
  if (typeof sourceDirectory !== "string" || sourceDirectory.length === 0) {
    throw new Error("source-directoryが不正です");
  }
  if (typeof prepackagedDirectory !== "string" || prepackagedDirectory.length === 0) {
    throw new Error("prepackaged-directoryが不正です");
  }
  if (platform !== "macos" && platform !== "windows") {
    throw new Error("platformはmacosまたはwindowsで指定してください");
  }
  if (typeof outputDirectory !== "string" || outputDirectory.length === 0) {
    throw new Error("output-directoryが不正です");
  }
  const sourceRoot = resolve(sourceDirectory);
  const prepackagedRoot = resolve(prepackagedDirectory);
  assertDirectory(sourceRoot, "source directoryがディレクトリではありません");
  assertDirectory(prepackagedRoot, "prepackaged directoryがディレクトリではありません");
  const sourcePackage = parseSourcePackage(join(sourceRoot, "package.json"));
  const builder = parseSourceBuilder(findBuilderPath(sourceRoot));
  const outputRoot = createOutputDirectory(outputDirectory);
  try {
    const packageInput =
      platform === "macos"
        ? buildMacInput(sourceRoot, sourcePackage, builder, prepackagedRoot, outputRoot)
        : buildWindowsInput(sourcePackage, builder, prepackagedRoot);
    const json = JSON.stringify(packageInput, null, 2);
    if (json === undefined) {
      throw new Error("package inputを生成できません");
    }
    try {
      writeFileSync(join(outputRoot, "package-input.json"), `${json}\n`, {
        flag: "wx",
        encoding: "utf8",
        mode: 0o600
      });
    } catch (error) {
      throw new Error(`package-input.jsonを書き込めません: ${outputRoot}`, { cause: error });
    }
    return packageInput;
  } catch (error) {
    try {
      rmSync(outputRoot, { recursive: true });
    } catch (cleanupError) {
      throw new AggregateError([error, cleanupError], "package input生成とcleanupに失敗しました");
    }
    throw error;
  }
}
