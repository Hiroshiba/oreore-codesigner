import { lstatSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { stringify as stringifyYaml } from "yaml";
import { loadSigningConfig } from "./config.js";
import { parsePackageInput, type PackageInput } from "./schema.js";
import { assertNoSymlinkAncestors, assertNoSymlinkPath } from "./path-safety.js";

type MacosPackageProjectRequest = {
  packageInputDirectory: string;
  target: "macos";
  repository: string;
  tag: string;
  outputDirectory: string;
};
type WindowsPackageProjectRequest = {
  packageInputDirectory: string;
  target: "windows-nsis" | "windows-nsis-web";
  repository: string;
  tag: string;
  outputDirectory: string;
  timestampUrl: string;
};
type PackageProjectRequest = MacosPackageProjectRequest | WindowsPackageProjectRequest;

type ValidatedPackageProject =
  | (MacosPackageProjectRequest & {
      input: Extract<PackageInput, { platform: "macos" }>;
    })
  | (WindowsPackageProjectRequest & {
      input: Extract<PackageInput, { platform: "windows" }>;
    });

const MAC_ENTITLEMENTS_FILE = "entitlements.plist";
const MAC_ENTITLEMENTS_INHERIT_FILE = "entitlements-inherit.plist";

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

function readJson(path: string): unknown {
  assertRegularFile(path, "package-input.jsonがありません");
  const source = readFileSync(path, "utf8");
  try {
    return JSON.parse(source);
  } catch (error) {
    throw new Error(`package-input.jsonを解析できません: ${path}`, { cause: error });
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
      throw error;
    }
    mkdirSync(outputPath, { mode: 0o700 });
    return outputPath;
  }
  throw new Error(`output directoryは開始時に存在してはいけません: ${outputPath}`);
}

function writeExclusive(path: string, contents: Buffer | string): void {
  writeFileSync(path, contents, { flag: "wx", mode: 0o600 });
  assertRegularFile(path, "package projectのfileがregular fileではありません");
}

function packageJson(input: PackageInput): string {
  const value = {
    name: input.name,
    version: input.version,
    private: true,
    ...(input.description == undefined ? {} : { description: input.description }),
    ...(input.author == undefined ? {} : { author: input.author })
  };
  const contents = JSON.stringify(value, null, 2);
  return `${contents}\n`;
}

function githubUrl(repository: string, tag: string): string {
  return `https://github.com/${repository}/releases/download/${encodeURIComponent(tag)}`;
}

function genericPublish(
  repository: string,
  tag: string,
  publishAutoUpdate: boolean
): Record<string, unknown> {
  return {
    provider: "generic",
    url: githubUrl(repository, tag),
    publishAutoUpdate
  };
}

function copyInputFile(
  inputRoot: string,
  relativePath: string,
  outputPath: string,
  label: string
): void {
  const sourcePath = resolve(inputRoot, relativePath);
  assertRegularFile(sourcePath, `package inputの${label}がregular fileではありません`);
  const contents = readFileSync(sourcePath);
  writeExclusive(outputPath, contents);
}

function validateInputPlatform(
  input: PackageInput,
  request: PackageProjectRequest
): ValidatedPackageProject {
  if (request.target === "macos") {
    if (input.platform !== "macos") {
      throw new Error("macos targetにはmacos package inputが必要です");
    }
    return { ...request, input };
  }
  if (input.platform !== "windows") {
    throw new Error("Windows targetにはwindows package inputが必要です");
  }
  return { ...request, input };
}

function commonBuilder(input: PackageInput): Record<string, unknown> {
  return {
    appId: input.appId,
    productName: input.productName,
    ...(input.copyright == undefined ? {} : { copyright: input.copyright })
  };
}

function macBuilder(input: Extract<PackageInput, { platform: "macos" }>): Record<string, unknown> {
  const mac = input.macos;
  const config: Record<string, unknown> = {
    target: [{ target: "zip", arch: [mac.architecture] }]
  };
  if (mac.artifactName != undefined) {
    config.artifactName = mac.artifactName;
  }
  if (mac.entitlements != undefined) {
    config.entitlements = mac.entitlements;
  }
  if (mac.entitlementsInherit != undefined) {
    config.entitlementsInherit = mac.entitlementsInherit;
  }
  if (mac.hardenedRuntime != undefined) {
    config.hardenedRuntime = mac.hardenedRuntime;
  }
  if (mac.gatekeeperAssess != undefined) {
    config.gatekeeperAssess = mac.gatekeeperAssess;
  }
  return config;
}

function nsisConfig(options: Record<string, unknown> | undefined): Record<string, unknown> {
  if (options == undefined) {
    return {};
  }
  const result: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(options)) {
    if (key !== "guid" && key !== "artifactName") {
      result[key] = value;
    }
  }
  return result;
}

function windowsBuilder(
  input: Extract<PackageInput, { platform: "windows" }>,
  target: "windows-nsis" | "windows-nsis-web",
  repository: string,
  tag: string,
  timestampUrl: string
): Record<string, unknown> {
  const windows = input.windows;
  const win: Record<string, unknown> = {
    target: [
      {
        target: target === "windows-nsis" ? "nsis" : "nsis-web",
        arch: [windows.architecture]
      }
    ],
    executableName: windows.executableName,
    signtoolOptions: {
      timeStampServer: timestampUrl,
      rfc3161TimeStampServer: timestampUrl
    }
  };
  if (windows.icon != undefined) {
    win.icon = windows.icon;
  }
  const publisherName = globalPublisherName();
  if (publisherName != undefined) {
    if (windows.publisherName != undefined && windows.publisherName !== publisherName) {
      throw new Error("package inputのpublisherNameとglobal signing displayNameが一致しません");
    }
    win.publisherName = publisherName;
  } else if (windows.publisherName != undefined) {
    throw new Error("package projectのpublisherNameにglobal signing displayNameがありません");
  }
  const sourceOptions = target === "windows-nsis" ? windows.nsis : windows.nsisWeb;
  const selectedOptions = nsisConfig(sourceOptions);
  const guid = windows.guid ?? sourceOptions?.guid;
  if (guid != undefined) {
    selectedOptions.guid = guid;
  }
  const artifactName = sourceOptions?.artifactName ?? windows.artifactName;
  if (artifactName != undefined) {
    selectedOptions.artifactName = artifactName;
  }
  const result: Record<string, unknown> = { ...commonBuilder(input), win };
  if (target === "windows-nsis") {
    result.nsis = selectedOptions;
  } else {
    result.nsisWeb = {
      ...selectedOptions
    };
  }
  result.publish = genericPublish(repository, tag, target === "windows-nsis");
  return result;
}

function buildProject(
  inputRoot: string,
  outputRoot: string,
  project: ValidatedPackageProject
): void {
  writeExclusive(join(outputRoot, "package.json"), packageJson(project.input));
  let config: Record<string, unknown>;
  if (project.target === "macos") {
    const input = project.input;
    config = {
      ...commonBuilder(input),
      publish: genericPublish(project.repository, project.tag, true),
      mac: macBuilder(input)
    };
  } else {
    const input = project.input;
    config = windowsBuilder(
      input,
      project.target,
      project.repository,
      project.tag,
      project.timestampUrl
    );
  }
  const builderContents = stringifyYaml(config);
  writeExclusive(join(outputRoot, "electron-builder.yml"), builderContents);
  if (project.target === "macos") {
    const input = project.input;
    if (input.macos.entitlements != undefined) {
      copyInputFile(
        inputRoot,
        input.macos.entitlements,
        join(outputRoot, MAC_ENTITLEMENTS_FILE),
        "entitlements"
      );
    }
    if (input.macos.entitlementsInherit != undefined) {
      copyInputFile(
        inputRoot,
        input.macos.entitlementsInherit,
        join(outputRoot, MAC_ENTITLEMENTS_INHERIT_FILE),
        "entitlementsInherit"
      );
    }
  } else {
    const input = project.input;
    if (input.windows.icon != undefined) {
      copyInputFile(
        inputRoot,
        input.windows.icon,
        join(outputRoot, input.windows.icon),
        "win.icon"
      );
    }
  }
}

/** package-inputから署名用の一時package projectを生成します。 */
export function createPackageProject(request: PackageProjectRequest): void {
  const inputRoot = resolve(request.packageInputDirectory);
  assertDirectory(inputRoot, "package-input directoryがディレクトリではありません");
  const input = parsePackageInput(readJson(join(inputRoot, "package-input.json")));
  const project = validateInputPlatform(input, request);
  const outputRoot = createOutputDirectory(request.outputDirectory);
  try {
    buildProject(inputRoot, outputRoot, project);
  } catch (error) {
    try {
      rmSync(outputRoot, { recursive: true });
    } catch (cleanupError) {
      throw new AggregateError([error, cleanupError], "package project生成とcleanupに失敗しました");
    }
    throw error;
  }
}
