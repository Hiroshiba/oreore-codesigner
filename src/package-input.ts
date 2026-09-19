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
  parseExecutableName,
  parsePackageManager,
  parseSemVer,
  parseRelativePath,
  parseWindowsIconFile,
  type WindowsIconFile
} from "./schema.js";
import {
  assertNoSymlinkAncestors,
  assertNoSymlinkPath,
  assertRealPathWithin
} from "./path-safety.js";

type PackageInputPlatform = "macos" | "windows";

const sourceAuthorSchema = z.union([
  z.string(),
  z
    .object({
      name: z.string().optional(),
      email: z.string().optional(),
      url: z.string().optional()
    })
    .strict()
]);
const sourcePackageSchema = z
  .object({
    name: z.string(),
    version: z.string(),
    packageManager: z.string(),
    description: z.string().optional(),
    author: sourceAuthorSchema.optional()
  })
  .passthrough();

const targetSchema = z.union([
  z.string(),
  z
    .object({
      target: z.string().optional(),
      arch: z.union([z.string(), z.array(z.string())]).optional()
    })
    .strict()
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
    icon: z.string().optional(),
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
    guid: z.string().optional(),
    publish: z.unknown().optional()
  })
  .strict();
const sourceBuilderSchema = z
  .object({
    appId: z.string().optional(),
    productName: z.string().optional(),
    artifactName: z.string().optional(),
    copyright: z.string().optional(),
    mac: sourceMacSchema.optional(),
    win: sourceWinSchema.optional(),
    nsis: sourceNsisSchema.optional(),
    nsisWeb: sourceNsisSchema.optional()
  })
  .passthrough();

type SourceNsis = z.infer<typeof sourceNsisSchema>;
type SourceMac = z.infer<typeof sourceMacSchema>;
type SourceWin = z.infer<typeof sourceWinSchema>;
type SourcePackage = {
  name: string;
  version: string;
  description?: string;
  author?: z.infer<typeof sourceAuthorSchema>;
};
type WindowsPackageInput = Extract<PackageInput, { platform: "windows" }>;
type MacosPackageInput = Extract<PackageInput, { platform: "macos" }>;
type PackageNsisOptions = NonNullable<WindowsPackageInput["windows"]["nsis"]>;

const sourceProductNameSchema = z
  .string()
  .min(1)
  .refine((value) => value.trim() === value)
  .refine(
    (value) =>
      !value.includes("/") &&
      !value.includes("\\") &&
      [...value].every((character) => {
        const code = character.codePointAt(0);
        return (
          code != undefined && code >= 0x20 && code !== 0x7f && !(code >= 0x80 && code <= 0x9f)
        );
      })
  );
const sourceFileNameSchema = z
  .string()
  .min(1)
  .refine(
    (value) =>
      value !== "." &&
      value !== ".." &&
      !value.includes("/") &&
      !value.includes("\\") &&
      !value.includes(":") &&
      !value.includes("\u0000") &&
      [...value].every((character) => {
        const code = character.codePointAt(0);
        return (
          code != undefined && code >= 0x20 && code !== 0x7f && !(code >= 0x80 && code <= 0x9f)
        );
      })
  );
const sourceGuidSchema = z
  .string()
  .regex(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/);

type ParsedSourceBuilder = {
  appId: string;
  productName: string;
  artifactName?: string;
  copyright?: string;
  mac?: SourceMac;
  win?: SourceWin;
  nsis?: SourceNsis;
  nsisWeb?: SourceNsis;
};

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
  const information = lstatSync(path);
  if (!information.isDirectory() || information.isSymbolicLink()) {
    throw new Error(`${message}: ${path}`);
  }
}

function assertRegularFile(path: string, message: string): void {
  assertNoSymlinkPath(path, message);
  const information = lstatSync(path);
  if (!information.isFile() || information.isSymbolicLink()) {
    throw new Error(`${message}: ${path}`);
  }
}

function readRegularFile(path: string, message: string): Buffer {
  assertRegularFile(path, message);
  return readFileSync(path);
}

function readJson(path: string): unknown {
  const source = readRegularFile(path, "JSONファイルがありません").toString("utf8");
  return JSON.parse(source);
}

function readYaml(path: string): unknown {
  const source = readRegularFile(path, "electron-builder設定がありません").toString("utf8");
  return parseYaml(source);
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
        throw error;
      }
    }
  }
  if (existing.length !== 1) {
    throw new Error(
      "source rootにはelectron-builder.ymlまたはelectron-builder.yamlを一つだけ置いてください"
    );
  }
  const path = existing[0];
  if (path == undefined) {
    throw new Error("electron-builder設定がありません");
  }
  assertRegularFile(path, "electron-builder設定がregular fileではありません");
  return path;
}

function parseSourcePackage(path: string): SourcePackage {
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
  return {
    name,
    version,
    ...(value.description == undefined ? {} : { description: value.description }),
    ...(value.author == undefined ? {} : { author: value.author })
  };
}

function parseSourceBuilder(path: string): ParsedSourceBuilder {
  const value = sourceBuilderSchema.parse(readYaml(path));
  if (value.appId == undefined || value.productName == undefined) {
    throw new Error("electron-builder設定のappIdとproductNameが必要です");
  }
  return {
    appId: parseAppId(value.appId),
    productName: sourceProductNameSchema.parse(value.productName),
    ...(value.artifactName == undefined ? {} : { artifactName: value.artifactName }),
    ...(value.copyright == undefined ? {} : { copyright: value.copyright }),
    ...(value.mac == undefined ? {} : { mac: value.mac }),
    ...(value.win == undefined ? {} : { win: value.win }),
    ...(value.nsis == undefined ? {} : { nsis: value.nsis }),
    ...(value.nsisWeb == undefined ? {} : { nsisWeb: value.nsisWeb })
  };
}

function targetArchitectures(value: z.infer<typeof targetListSchema> | undefined): string[] {
  if (value == undefined) {
    return [];
  }
  const targets = Array.isArray(value) ? value : [value];
  const architectures: string[] = [];
  for (const target of targets) {
    if (typeof target === "string") {
      continue;
    }
    if (target.arch == undefined) {
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

function copyInputFile(
  sourceRoot: string,
  sourceRelativePath: string,
  outputPath: string,
  label: string
): void {
  const sourcePath = resolve(sourceRoot, sourceRelativePath);
  assertRealPathWithin(sourceRoot, sourcePath, `${label}がsource root外を参照しています`);
  const contents = readRegularFile(sourcePath, `${label}がregular fileではありません`);
  writeFileSync(outputPath, contents, { flag: "wx", mode: 0o600 });
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
      throw error;
    }
    mkdirSync(outputPath, { mode: 0o700 });
    return outputPath;
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
    if (key == undefined || value == undefined) {
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
  if (app == undefined || !app.isDirectory() || app.isSymbolicLink()) {
    throw new Error("prepackagedの.appがdirectoryではありません");
  }
  const infoPath = join(prepackagedRoot, app.name, "Contents", "Info.plist");
  const values = readInfoPlist(infoPath);
  assertPlistValue(values, "CFBundleIdentifier", appId);
  const bundleNames = [values.get("CFBundleName"), values.get("CFBundleDisplayName")].filter(
    (value): value is string => value != undefined
  );
  if (bundleNames.length === 0 || bundleNames.some((value) => value !== productName)) {
    throw new Error("Info.plistのproductNameがpackage inputと一致しません");
  }
  const shortVersion = values.get("CFBundleShortVersionString");
  const bundleVersion = values.get("CFBundleVersion");
  if (shortVersion != undefined && shortVersion !== version) {
    throw new Error("Info.plistのCFBundleShortVersionStringがpackage inputと一致しません");
  }
  if (bundleVersion != undefined && bundleVersion !== version) {
    throw new Error("Info.plistのCFBundleVersionがpackage inputと一致しません");
  }
  if (shortVersion == undefined && bundleVersion == undefined) {
    throw new Error("Info.plistにversionがありません");
  }
}

function resolveWindowsExecutableName(
  prepackagedRoot: string,
  configuredName: string | undefined
): string {
  if (configuredName != undefined) {
    const executableName = parseExecutableName(configuredName);
    const executablePath = join(prepackagedRoot, `${executableName}.exe`);
    assertRegularFile(executablePath, "設定済みexecutableNameの主exeがregular fileではありません");
    return executableName;
  }
  const entries = readdirSync(prepackagedRoot, { withFileTypes: true });
  const executables = entries.filter(
    (entry) =>
      entry.isFile() && !entry.isSymbolicLink() && entry.name.toLowerCase().endsWith(".exe")
  );
  if (executables.length !== 1) {
    throw new Error("prepackaged directory直下のexeを一件に確定できません");
  }
  const executable = executables[0];
  if (executable == undefined) {
    throw new Error("prepackaged directory直下のexeを確定できません");
  }
  const executableName = parseExecutableName(executable.name.slice(0, -4));
  assertRegularFile(join(prepackagedRoot, executable.name), "主exeがregular fileではありません");
  return executableName;
}

function windowsIconFile(sourcePath: string): WindowsIconFile {
  const extension = extname(parseRelativePath(sourcePath)).toLowerCase();
  if (
    extension !== ".ico" &&
    extension !== ".png" &&
    extension !== ".svg" &&
    extension !== ".icns"
  ) {
    throw new Error("win.iconはico、png、svg、icnsのいずれかの拡張子が必要です");
  }
  return parseWindowsIconFile(`icon${extension}`);
}

function nsisOptions(value: SourceNsis | undefined): PackageNsisOptions | undefined {
  if (value == undefined) {
    return undefined;
  }
  const parsed: PackageNsisOptions = {};
  if (value.oneClick != undefined) {
    parsed.oneClick = value.oneClick;
  }
  if (value.perMachine != undefined) {
    parsed.perMachine = value.perMachine;
  }
  if (value.allowToChangeInstallationDirectory != undefined) {
    parsed.allowToChangeInstallationDirectory = value.allowToChangeInstallationDirectory;
  }
  if (value.allowElevation != undefined) {
    parsed.allowElevation = value.allowElevation;
  }
  if (value.createDesktopShortcut != undefined) {
    parsed.createDesktopShortcut = value.createDesktopShortcut;
  }
  if (value.createStartMenuShortcut != undefined) {
    parsed.createStartMenuShortcut = value.createStartMenuShortcut;
  }
  if (value.createQuickLaunchShortcut != undefined) {
    parsed.createQuickLaunchShortcut = value.createQuickLaunchShortcut;
  }
  if (value.shortcutName != undefined) {
    parsed.shortcutName = sourceFileNameSchema.parse(value.shortcutName);
  }
  if (value.menuCategory != undefined) {
    parsed.menuCategory = sourceFileNameSchema.parse(value.menuCategory);
  }
  if (value.uninstallDisplayName != undefined) {
    parsed.uninstallDisplayName = sourceProductNameSchema.parse(value.uninstallDisplayName);
  }
  if (value.deleteAppDataOnUninstall != undefined) {
    parsed.deleteAppDataOnUninstall = value.deleteAppDataOnUninstall;
  }
  if (value.runAfterFinish != undefined) {
    parsed.runAfterFinish = value.runAfterFinish;
  }
  if (value.artifactName != undefined) {
    parsed.artifactName = parseArtifactName(value.artifactName);
  }
  if (value.guid != undefined) {
    parsed.guid = sourceGuidSchema.parse(value.guid);
  }
  return parsed;
}

function parseOptionalArtifactName(value: string | undefined): string | undefined {
  if (value == undefined) {
    return undefined;
  }
  return parseArtifactName(value);
}

function buildMacInput(
  sourceRoot: string,
  sourcePackage: SourcePackage,
  builder: ParsedSourceBuilder,
  prepackagedRoot: string,
  outputRoot: string
): PackageInput {
  const mac = builder.mac;
  const architecture = resolveArchitecture(mac?.target, "macos");
  if (architecture !== "x64") {
    throw new Error("macOS architectureはx64でなければなりません");
  }
  const appId = builder.appId;
  const productName = builder.productName;
  validateMacPrepackaged(prepackagedRoot, appId, productName, sourcePackage.version);
  const entitlements = mac?.entitlements;
  const entitlementsInherit = mac?.entitlementsInherit;
  if (entitlements != undefined) {
    copyInputFile(
      sourceRoot,
      parseRelativePath(entitlements),
      join(outputRoot, "entitlements.plist"),
      "entitlements"
    );
  }
  if (entitlementsInherit != undefined) {
    copyInputFile(
      sourceRoot,
      parseRelativePath(entitlementsInherit),
      join(outputRoot, "entitlements-inherit.plist"),
      "entitlementsInherit"
    );
  }
  const artifactName = parseOptionalArtifactName(mac?.artifactName ?? builder.artifactName);
  const macosOptions: MacosPackageInput["macos"] = {
    architecture,
    ...(artifactName == undefined ? {} : { artifactName }),
    ...(entitlements == undefined ? {} : { entitlements: "entitlements.plist" }),
    ...(entitlementsInherit == undefined
      ? {}
      : { entitlementsInherit: "entitlements-inherit.plist" }),
    ...(mac?.hardenedRuntime == undefined ? {} : { hardenedRuntime: mac.hardenedRuntime }),
    ...(mac?.gatekeeperAssess == undefined ? {} : { gatekeeperAssess: mac.gatekeeperAssess })
  };
  const macInput: MacosPackageInput = {
    platform: "macos",
    name: sourcePackage.name,
    version: sourcePackage.version,
    ...(sourcePackage.description == undefined ? {} : { description: sourcePackage.description }),
    ...(sourcePackage.author == undefined ? {} : { author: sourcePackage.author }),
    ...(builder.copyright == undefined ? {} : { copyright: builder.copyright }),
    appId,
    productName,
    macos: macosOptions
  };
  return macInput;
}

function buildWindowsInput(
  sourceRoot: string,
  sourcePackage: SourcePackage,
  builder: ParsedSourceBuilder,
  prepackagedRoot: string,
  outputRoot: string
): PackageInput {
  const win = builder.win;
  const appId = builder.appId;
  const productName = builder.productName;
  const architecture = resolveArchitecture(win?.target, "windows");
  if (architecture !== "x64") {
    throw new Error("Windows architectureはx64でなければなりません");
  }
  const executableName = resolveWindowsExecutableName(prepackagedRoot, win?.executableName);
  const icon = win?.icon;
  const iconFile = icon == undefined ? undefined : windowsIconFile(icon);
  if (iconFile != undefined && icon != undefined) {
    copyInputFile(sourceRoot, icon, join(outputRoot, iconFile), "win.icon");
  }
  const nsis = nsisOptions(builder.nsis);
  const nsisWeb = nsisOptions(builder.nsisWeb);
  const nsisGuid =
    builder.nsis?.guid == undefined ? undefined : sourceGuidSchema.parse(builder.nsis.guid);
  const nsisWebGuid =
    builder.nsisWeb?.guid == undefined ? undefined : sourceGuidSchema.parse(builder.nsisWeb.guid);
  if (nsisGuid != undefined && nsisWebGuid != undefined && nsisGuid !== nsisWebGuid) {
    throw new Error("NSISとNSIS WebのGUIDが一致しません");
  }
  const sourceGuid = nsisGuid ?? nsisWebGuid;
  const artifactName = parseOptionalArtifactName(win?.artifactName ?? builder.artifactName);
  const sourcePublisherName =
    win?.publisherName == undefined ? undefined : sourceProductNameSchema.parse(win.publisherName);
  const configuredPublisherNameValue = globalPublisherName();
  const configuredPublisherName =
    configuredPublisherNameValue == undefined
      ? undefined
      : sourceProductNameSchema.parse(configuredPublisherNameValue);
  if (sourcePublisherName != undefined && configuredPublisherName == undefined) {
    throw new Error("source publisherNameを照合するglobal signing displayNameがありません");
  }
  if (
    sourcePublisherName != undefined &&
    configuredPublisherName != undefined &&
    sourcePublisherName !== configuredPublisherName
  ) {
    throw new Error("source publisherNameとglobal signing displayNameが一致しません");
  }
  const windowsInput: WindowsPackageInput["windows"] = {
    architecture,
    executableName,
    ...(iconFile == undefined ? {} : { icon: iconFile }),
    ...(configuredPublisherName == undefined ? {} : { publisherName: configuredPublisherName }),
    ...(artifactName == undefined ? {} : { artifactName }),
    ...(sourceGuid == undefined
      ? {}
      : {
          guid: sourceGuid
        }),
    ...(nsis == undefined ? {} : { nsis }),
    ...(nsisWeb == undefined ? {} : { nsisWeb })
  };
  const packageInput: WindowsPackageInput = {
    platform: "windows",
    name: sourcePackage.name,
    version: sourcePackage.version,
    ...(sourcePackage.description == undefined ? {} : { description: sourcePackage.description }),
    ...(sourcePackage.author == undefined ? {} : { author: sourcePackage.author }),
    ...(builder.copyright == undefined ? {} : { copyright: builder.copyright }),
    appId,
    productName,
    windows: windowsInput
  };
  return packageInput;
}

/** sourceのpackage.jsonとbuilder設定、prepackaged本体から一時package inputを作成します。 */
export function createPackageInput(
  sourceDirectory: string,
  prepackagedDirectory: string,
  platform: PackageInputPlatform,
  outputDirectory: string
): PackageInput {
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
        : buildWindowsInput(sourceRoot, sourcePackage, builder, prepackagedRoot, outputRoot);
    const json = JSON.stringify(packageInput, null, 2);
    writeFileSync(join(outputRoot, "package-input.json"), `${json}\n`, {
      flag: "wx",
      encoding: "utf8",
      mode: 0o600
    });
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
