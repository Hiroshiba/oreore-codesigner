import { fileURLToPath } from "node:url";
import { resolve } from "node:path";
import { loadJsonFile, writeJsonFile } from "./config.js";
import { createPackageProject } from "./package-project.js";
import { createPublishPlan } from "./publish-plan.js";
import { assertReleaseSetComplete, createReleaseManifest } from "./release-manifest.js";
import { prepareContract, validateSource } from "./source-validation.js";

type Command =
  | "prepare"
  | "validate-source"
  | "create-package-project"
  | "create-release-manifest"
  | "plan-publish";

function parseCommand(value: string): Command {
  if (
    value !== "prepare" &&
    value !== "validate-source" &&
    value !== "create-package-project" &&
    value !== "create-release-manifest" &&
    value !== "plan-publish"
  ) {
    throw new Error(`未知のsubcommandです: ${value}`);
  }
  return value;
}

function parseOptions(args: string[]): { command: Command; options: Map<string, string> } {
  const commandValue = args[0];
  if (commandValue === undefined) {
    throw new Error("subcommandが必要です");
  }
  const command = parseCommand(commandValue);
  const options = new Map<string, string>();
  let index = 1;
  while (index < args.length) {
    const option = args[index];
    if (option === undefined || !option.startsWith("--")) {
      throw new Error("optionは--で始めてください");
    }
    const optionName = option.slice(2);
    if (optionName.length === 0 || options.has(optionName)) {
      throw new Error(`optionが重複または空です: ${option}`);
    }
    const value = args[index + 1];
    if (value === undefined || value.startsWith("--")) {
      throw new Error(`optionの値がありません: ${option}`);
    }
    options.set(optionName, value);
    index += 2;
  }
  return { command, options };
}

function assertAllowedOptions(options: Map<string, string>, allowed: string[]): void {
  const allowedSet = new Set(allowed);
  for (const name of options.keys()) {
    if (!allowedSet.has(name)) {
      throw new Error(`このsubcommandでは使えないoptionです: --${name}`);
    }
  }
}

function requiredOption(options: Map<string, string>, name: string): string {
  const value = options.get(name);
  if (value === undefined || value.length === 0) {
    throw new Error(`optionが必要です: --${name}`);
  }
  return value;
}

function parseBoolean(value: string): boolean {
  if (value === "true") {
    return true;
  }
  if (value === "false") {
    return false;
  }
  throw new Error("replace-existing-assetsはtrueまたはfalseで指定してください");
}

function executePrepare(options: Map<string, string>): void {
  assertAllowedOptions(options, ["app-id", "tag", "replace-existing-assets", "output"]);
  const contract = prepareContract(
    process.cwd(),
    requiredOption(options, "app-id"),
    requiredOption(options, "tag"),
    parseBoolean(requiredOption(options, "replace-existing-assets"))
  );
  writeJsonFile(requiredOption(options, "output"), contract);
}

function executeValidateSource(options: Map<string, string>): void {
  assertAllowedOptions(options, ["contract", "source-directory", "output"]);
  const contract = loadJsonFile(requiredOption(options, "contract"));
  const releaseContract = validateSource(
    process.cwd(),
    contract,
    requiredOption(options, "source-directory")
  );
  writeJsonFile(requiredOption(options, "output"), releaseContract);
}

function executeCreatePackageProject(options: Map<string, string>): void {
  assertAllowedOptions(options, ["contract", "target", "output-directory"]);
  const contract = loadJsonFile(requiredOption(options, "contract"));
  const targetValue = requiredOption(options, "target");
  if (
    targetValue !== "macos" &&
    targetValue !== "windows-nsis" &&
    targetValue !== "windows-nsis-web"
  ) {
    throw new Error("targetはmacos、windows-nsis、windows-nsis-webのいずれかです");
  }
  createPackageProject(
    process.cwd(),
    contract,
    targetValue,
    requiredOption(options, "output-directory")
  );
}

function executeCreateManifest(options: Map<string, string>): void {
  assertAllowedOptions(options, ["contract", "assets-directory", "output"]);
  const contract = loadJsonFile(requiredOption(options, "contract"));
  const manifest = createReleaseManifest(
    process.cwd(),
    contract,
    requiredOption(options, "assets-directory")
  );
  writeJsonFile(requiredOption(options, "output"), manifest);
}

function executePlanPublish(options: Map<string, string>): void {
  assertAllowedOptions(options, [
    "contract",
    "manifest",
    "remote-assets",
    "assets-directory",
    "output"
  ]);
  const contract = loadJsonFile(requiredOption(options, "contract"));
  const manifest = loadJsonFile(requiredOption(options, "manifest"));
  const remoteAssets = loadJsonFile(requiredOption(options, "remote-assets"));
  const assetsDirectory = requiredOption(options, "assets-directory");
  assertReleaseSetComplete(manifest);
  const plan = createPublishPlan(process.cwd(), contract, manifest, remoteAssets, assetsDirectory);
  writeJsonFile(requiredOption(options, "output"), plan);
}

/** CLI引数を検証して中央署名の一連の処理を実行します。 */
export function runCli(args: string[]): void {
  const { command, options } = parseOptions(args);
  if (command === "prepare") {
    executePrepare(options);
    return;
  }
  if (command === "validate-source") {
    executeValidateSource(options);
    return;
  }
  if (command === "create-package-project") {
    executeCreatePackageProject(options);
    return;
  }
  if (command === "create-release-manifest") {
    executeCreateManifest(options);
    return;
  }
  executePlanPublish(options);
}

if (process.argv[1] !== undefined && fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
  runCli(process.argv.slice(2));
}
