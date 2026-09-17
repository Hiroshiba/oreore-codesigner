import { readFileSync, statSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { canonicalDigest } from "./canonical-json.js";
import {
  type ApplicationConfig,
  type ApplicationsConfig,
  type SigningConfig,
  parseApplicationsConfig,
  parseSigningConfig
} from "./schema.js";

function readJsonFile(path: string): unknown {
  let source: string;
  try {
    source = readFileSync(path, "utf8");
  } catch (error) {
    throw new Error(`JSONファイルを読み込めません: ${path}`, { cause: error });
  }
  try {
    return JSON.parse(source);
  } catch (error) {
    throw new Error(`JSONを解析できません: ${path}`, { cause: error });
  }
}

function assertRegularFile(path: string, message: string): void {
  let information;
  try {
    information = statSync(path);
  } catch (error) {
    throw new Error(`${message}: ${path}`, { cause: error });
  }
  if (!information.isFile()) {
    throw new Error(`${message}: ${path}`);
  }
}

function assertUniqueConfiguration(applications: ApplicationsConfig): void {
  const repositories = new Set<string>();
  const appIds = new Set<string>();
  const guids = new Set<string>();
  for (const [appKey, application] of Object.entries(applications.applications)) {
    const repositoryKey = `${application.repository.toLowerCase()}\u0000${application.workingDirectory}`;
    if (repositories.has(repositoryKey)) {
      throw new Error(`repositoryとworkingDirectoryが重複しています: ${appKey}`);
    }
    repositories.add(repositoryKey);
    if (appIds.has(application.identity.appId)) {
      throw new Error(`identity.appIdが重複しています: ${appKey}`);
    }
    appIds.add(application.identity.appId);
    if (guids.has(application.windows.guid)) {
      throw new Error(`Windows GUIDが重複しています: ${appKey}`);
    }
    guids.add(application.windows.guid);
  }
}

/** apps.jsonとsigning.jsonを読み込み、設定全体を検証します。 */
export function loadConfiguration(rootDirectory: string): {
  applications: ApplicationsConfig;
  signing: SigningConfig;
  digest: string;
} {
  const applicationsPath = resolve(rootDirectory, "config/apps.json");
  const signingPath = resolve(rootDirectory, "config/signing.json");
  assertRegularFile(applicationsPath, "apps.jsonがありません");
  assertRegularFile(signingPath, "signing.jsonがありません");
  const applications = parseApplicationsConfig(readJsonFile(applicationsPath));
  const signing = parseSigningConfig(readJsonFile(signingPath));
  assertUniqueConfiguration(applications);
  return {
    applications,
    signing,
    digest: canonicalDigest({ applications, signing })
  };
}

/** 設定中のapp-idに対応するapplicationを返します。 */
export function getApplication(applications: ApplicationsConfig, appId: string): ApplicationConfig {
  if (!Object.hasOwn(applications.applications, appId)) {
    throw new Error(`app-idが設定されていません: ${appId}`);
  }
  const application = applications.applications[appId];
  if (application === undefined) {
    throw new Error(`app-idが設定されていません: ${appId}`);
  }
  return application;
}

/** JSONを読み込みます。 */
export function loadJsonFile(path: string): unknown {
  return readJsonFile(path);
}

/** JSONを整形してファイルへ書き込みます。 */
export function writeJsonFile(path: string, value: unknown): void {
  const contents = JSON.stringify(value, null, 2);
  if (contents === undefined) {
    throw new Error(`JSONを生成できません: ${path}`);
  }
  try {
    writeFileSync(path, `${contents}\n`, "utf8");
  } catch (error) {
    throw new Error(`JSONファイルを書き込めません: ${path}`, { cause: error });
  }
}
