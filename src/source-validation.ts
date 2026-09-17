import { lstatSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { canonicalJson } from "./canonical-json.js";
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

const rootSourcePackageSchema = z
  .object({
    packageManager: z.string().min(1)
  })
  .passthrough();

const targetSourcePackageSchema = z
  .object({
    name: z.string().min(1),
    version: z.string().min(1),
    scripts: z.record(z.string(), z.string()).optional(),
    dependencies: z.record(z.string(), z.string()).optional(),
    devDependencies: z.record(z.string(), z.string()).optional()
  })
  .passthrough();

type TargetSourcePackage = z.infer<typeof targetSourcePackageSchema>;

function assertRegularSourceFile(path: string, message: string, rejectEmpty: boolean): void {
  let information;
  try {
    information = lstatSync(path);
  } catch (error) {
    throw new Error(`${message}: ${path}`, { cause: error });
  }
  if (information.isSymbolicLink() || !information.isFile()) {
    throw new Error(`${message}: ${path}`);
  }
  if (rejectEmpty && information.size === 0) {
    throw new Error(`空のファイルは許可されません: ${path}`);
  }
}

function readSourcePackage<T extends z.ZodType<unknown>>(path: string, schema: T): z.output<T> {
  const result = schema.safeParse(loadJsonFile(path));
  if (!result.success) {
    throw result.error;
  }
  return result.data;
}

function assertExactDependency(
  packageJson: TargetSourcePackage,
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
  packageJson: TargetSourcePackage,
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

function assertSigningConfigured(
  application: ApplicationConfig,
  signing: ReturnType<typeof loadConfiguration>["signing"]
): void {
  if (signing.macos.configured !== true) {
    throw new Error("macOS signingが未設定です");
  }
  if (signing.windows.configured !== true) {
    throw new Error("Windows signingが未設定です");
  }
  if (application.windows.publisherName !== signing.windows.displayName) {
    throw new Error("Windows publisherNameとsigning.windows.displayNameが一致しません");
  }
}

function assertContractCanonicalMatch(expected: unknown, actual: unknown, message: string): void {
  if (canonicalJson(expected) !== canonicalJson(actual)) {
    throw new Error(message);
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
  assertSigningConfigured(application, configuration.signing);
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

/** 現在の中央設定からprepared contractを再構築して一致を検証します。 */
export function assertPreparedContractCurrent(
  rootDirectory: string,
  contractValue: unknown
): PreparedContract {
  const contract = parsePreparedContract(contractValue);
  const expected = prepareContract(
    rootDirectory,
    contract.appId,
    contract.tag,
    contract.replaceExistingAssets
  );
  assertContractCanonicalMatch(
    expected,
    contract,
    "prepared contractが現在の中央設定と一致しません"
  );
  return contract;
}

/** 現在の中央設定からrelease contractを再構築して一致を検証します。 */
export function assertReleaseContractCurrent(
  rootDirectory: string,
  contractValue: unknown
): ReleaseContract {
  const contract = parseReleaseContract(contractValue);
  const prepared = prepareContract(
    rootDirectory,
    contract.appId,
    contract.tag,
    contract.replaceExistingAssets
  );
  const expected = parseReleaseContract({ ...prepared, version: contract.version });
  assertContractCanonicalMatch(
    expected,
    contract,
    "release contractが現在の中央設定と一致しません"
  );
  return contract;
}

function validateSourceWithRoot(
  rootDirectory: string,
  preparedContractValue: unknown,
  sourceDirectory: string
): ReleaseContract {
  const preparedContract = assertPreparedContractCurrent(rootDirectory, preparedContractValue);
  const sourceRoot = resolve(sourceDirectory);
  const rootPackagePath = join(sourceRoot, "package.json");
  const lockfilePath = join(sourceRoot, "pnpm-lock.yaml");
  assertRegularSourceFile(rootPackagePath, "source rootのpackage.jsonがありません", false);
  assertRegularSourceFile(lockfilePath, "source rootのpnpm-lock.yamlがありません", true);
  if (readFileSync(lockfilePath, "utf8").trim().length === 0) {
    throw new Error(`空のファイルは許可されません: ${lockfilePath}`);
  }
  const rootPackage = readSourcePackage(rootPackagePath, rootSourcePackageSchema);
  const expectedPackageManager = `pnpm@${preparedContract.application.pnpmVersion}`;
  if (rootPackage.packageManager !== expectedPackageManager) {
    throw new Error(`root packageManagerは${expectedPackageManager}でなければなりません`);
  }

  const targetPackagePath = join(
    sourceRoot,
    preparedContract.application.workingDirectory,
    "package.json"
  );
  assertRegularSourceFile(targetPackagePath, "workingDirectoryのpackage.jsonがありません", false);
  const targetPackage = readSourcePackage(targetPackagePath, targetSourcePackageSchema);
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

/** source repositoryを検証し、versionを加えたrelease contractを生成します。 */
export function validateSource(
  rootDirectory: string,
  preparedContractValue: unknown,
  sourceDirectory: string
): ReleaseContract;
export function validateSource(
  preparedContractValue: unknown,
  sourceDirectory: string
): ReleaseContract;
export function validateSource(first: unknown, second: unknown, third?: string): ReleaseContract {
  if (third === undefined) {
    if (typeof second !== "string") {
      throw new Error("source-directoryが不正です");
    }
    return validateSourceWithRoot(process.cwd(), first, second);
  }
  if (typeof first !== "string") {
    throw new Error("root directoryが不正です");
  }
  return validateSourceWithRoot(first, second, third);
}
