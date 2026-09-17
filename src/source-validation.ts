import { existsSync, statSync } from "node:fs";
import { join, resolve } from "node:path";
import { getApplication, loadConfiguration, loadJsonFile } from "./config.js";
import {
  type ApplicationConfig,
  type PreparedContract,
  type ReleaseContract,
  parsePreparedContract,
  parsePnpmVersion,
  parseReleaseContract
} from "./schema.js";
import { validateReleaseTag, validateTagForPrepare } from "./release-policy.js";
import { z } from "zod";

const sourcePackageSchema = z
  .object({
    name: z.string().min(1),
    version: z.string().min(1),
    packageManager: z.string().optional(),
    scripts: z.record(z.string(), z.string()).optional(),
    dependencies: z.record(z.string(), z.string()).optional(),
    devDependencies: z.record(z.string(), z.string()).optional()
  })
  .passthrough();

function readSourcePackage(path: string): z.infer<typeof sourcePackageSchema> {
  return sourcePackageSchema.parse(loadJsonFile(path));
}

function assertRegularSourceFile(path: string, message: string): void {
  if (!existsSync(path)) {
    throw new Error(`${message}: ${path}`);
  }
  const information = statSync(path);
  if (!information.isFile()) {
    throw new Error(`${message}: ${path}`);
  }
}

function assertExactDependency(
  packageJson: z.infer<typeof sourcePackageSchema>,
  dependencyName: string,
  expectedVersion: string,
  devDependenciesAllowed: boolean
): void {
  const dependencyVersion = packageJson.dependencies?.[dependencyName];
  const devDependencyVersion = packageJson.devDependencies?.[dependencyName];
  const dependencyMatches = dependencyVersion === expectedVersion;
  const devDependencyMatches = devDependenciesAllowed && devDependencyVersion === expectedVersion;
  if (!dependencyMatches && !devDependencyMatches) {
    throw new Error(`${dependencyName}は${expectedVersion}のexact dependencyが必要です`);
  }
}

function assertBuildScripts(
  packageJson: z.infer<typeof sourcePackageSchema>,
  application: ApplicationConfig
): void {
  const scripts = packageJson.scripts;
  if (scripts === undefined) {
    throw new Error("package.jsonにbuild scriptsがありません");
  }
  const requiredScripts = [application.buildScripts.macos, application.buildScripts.windows];
  for (const scriptName of requiredScripts) {
    if (scripts[scriptName] === undefined) {
      throw new Error(`package.jsonにbuild scriptがありません: ${scriptName}`);
    }
  }
}

/** dispatch入力から準備済みcontractを生成します。 */
export function prepareContract(
  rootDirectory: string,
  appId: string,
  tag: string,
  replaceExistingAssets: boolean
): PreparedContract {
  const configuration = loadConfiguration(rootDirectory);
  const application = getApplication(configuration.applications, appId);
  validateTagForPrepare(application.release, tag);
  if (replaceExistingAssets && application.release.assetPolicy !== "replaceable") {
    throw new Error("append-only releaseではreplace-existing-assets=trueを指定できません");
  }
  return {
    schemaVersion: 1,
    appId,
    repository: application.repository,
    tag,
    replaceExistingAssets,
    configDigest: configuration.digest,
    application
  };
}

/** source repositoryを検証し、versionを加えたrelease contractを生成します。 */
export function validateSource(
  preparedContractValue: unknown,
  sourceDirectory: string
): ReleaseContract {
  const preparedContract = parsePreparedContract(preparedContractValue);
  const sourceRoot = resolve(sourceDirectory);
  const rootPackagePath = join(sourceRoot, "package.json");
  const lockfilePath = join(sourceRoot, "pnpm-lock.yaml");
  assertRegularSourceFile(rootPackagePath, "source rootのpackage.jsonがありません");
  assertRegularSourceFile(lockfilePath, "source rootのpnpm-lock.yamlがありません");
  const rootPackage = readSourcePackage(rootPackagePath);
  const expectedPackageManager = `pnpm@${preparedContract.application.pnpmVersion}`;
  if (rootPackage.packageManager !== expectedPackageManager) {
    throw new Error(`root packageManagerは${expectedPackageManager}でなければなりません`);
  }

  const targetPackagePath = join(
    sourceRoot,
    preparedContract.application.workingDirectory,
    "package.json"
  );
  assertRegularSourceFile(targetPackagePath, "workingDirectoryのpackage.jsonがありません");
  const targetPackage = readSourcePackage(targetPackagePath);
  if (targetPackage.name !== preparedContract.application.packageName) {
    throw new Error("package.jsonのpackage nameが設定と一致しません");
  }
  parsePnpmVersion(preparedContract.application.pnpmVersion);
  assertBuildScripts(targetPackage, preparedContract.application);
  assertExactDependency(targetPackage, "electron-builder", "26.16.1", true);
  assertExactDependency(targetPackage, "electron-updater", "6.8.9", false);
  validateReleaseTag(
    preparedContract.application.release,
    preparedContract.tag,
    targetPackage.version
  );
  return parseReleaseContract({
    ...preparedContract,
    version: targetPackage.version
  });
}
