import { lstatSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { parse as parseYaml } from "yaml";
import { z } from "zod";
import { parseSemVer } from "./schema.js";

const exactPnpmPattern =
  /^pnpm@(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(\+[A-Za-z0-9._-]+)?$/;
const targetSettingsSchema = z
  .object({
    publish: z.never().optional()
  })
  .passthrough();
const targetSchema = z.union([
  z.string(),
  z.null(),
  targetSettingsSchema,
  z.array(z.union([z.string(), targetSettingsSchema]))
]);
const noPublishSchema = z
  .object({
    publish: z.never().optional(),
    target: targetSchema.optional()
  })
  .passthrough();
const builderConfigSchema = z
  .object({
    extends: z.never().optional(),
    publish: z.never().optional(),
    target: targetSchema.optional(),
    mac: noPublishSchema.optional(),
    win: noPublishSchema.optional(),
    nsis: noPublishSchema.optional(),
    nsisWeb: noPublishSchema.optional()
  })
  .passthrough();
const packageJsonSchema = z
  .object({
    version: z.string(),
    packageManager: z.string(),
    scripts: z
      .object({
        build: z.string().min(1, "build scriptを空にできません")
      })
      .passthrough(),
    dependencies: z.record(z.string()).optional(),
    optionalDependencies: z.record(z.string()).optional(),
    peerDependencies: z.record(z.string()).optional(),
    devDependencies: z.record(z.string()).optional(),
    build: z.never().optional()
  })
  .passthrough();

type PackageJson = z.infer<typeof packageJsonSchema>;

export type SourceContract = {
  version: string;
  channel: string;
  builderConfig: string;
};

function assertDirectory(path: string): void {
  const information = lstatSync(path);
  if (!information.isDirectory() || information.isSymbolicLink()) {
    throw new Error(`source directoryが通常directoryではありません: ${path}`);
  }
}

function assertRegularFile(path: string, description: string): void {
  const information = lstatSync(path);
  if (!information.isFile() || information.isSymbolicLink()) {
    throw new Error(`${description}が通常fileではありません: ${path}`);
  }
}

function readPackageJson(sourceDirectory: string): PackageJson {
  const path = join(sourceDirectory, "package.json");
  assertRegularFile(path, "source package.json");
  return packageJsonSchema.parse(JSON.parse(readFileSync(path, "utf8")));
}

function assertElectronBuilder(packageJson: PackageJson): void {
  const productionDependencySections = [
    packageJson.dependencies,
    packageJson.optionalDependencies,
    packageJson.peerDependencies
  ];
  if (
    productionDependencySections.some(
      (dependencies) => dependencies?.["electron-builder"] != undefined
    )
  ) {
    throw new Error("electron-builderはdevDependenciesにだけ配置してください");
  }
  if (packageJson.devDependencies?.["electron-builder"] !== "26.16.1") {
    throw new Error("electron-builder依存は26.16.1に固定してください");
  }
}

function channelFromVersion(version: string): string {
  const prerelease = /^\d+\.\d+\.\d+-([0-9A-Za-z-]+)/.exec(version);
  return prerelease?.[1] ?? "latest";
}

function findBuilderConfig(sourceDirectory: string): string {
  const candidates = readdirSync(sourceDirectory, { withFileTypes: true }).filter(
    (entry) => entry.name === "electron-builder.yml" || entry.name === "electron-builder.yaml"
  );
  if (candidates.length !== 1) {
    throw new Error("electron-builder.ymlまたはelectron-builder.yamlを一つだけ配置してください");
  }
  const candidate = candidates[0];
  if (candidate == undefined) {
    throw new Error("electron-builder設定がありません");
  }
  const path = join(sourceDirectory, candidate.name);
  assertRegularFile(path, "electron-builder設定");
  builderConfigSchema.parse(parseYaml(readFileSync(path, "utf8")));
  return candidate.name;
}

/** ソースの最小契約を検証して中央が使う値を返します。 */
export function validateSourceContract(sourceDirectory: string): SourceContract {
  assertDirectory(sourceDirectory);
  const packageJson = readPackageJson(sourceDirectory);
  const version = parseSemVer(packageJson.version);
  if (!exactPnpmPattern.test(packageJson.packageManager)) {
    throw new Error("source packageManagerはpnpmのexact specで指定してください");
  }
  assertElectronBuilder(packageJson);
  const builderConfig = findBuilderConfig(sourceDirectory);
  return { version, channel: channelFromVersion(version), builderConfig };
}
