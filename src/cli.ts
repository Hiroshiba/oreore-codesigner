import { parseArgs } from "node:util";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";
import { z } from "zod";
import { createPackageInput } from "./package-input.js";
import { createPackageProject } from "./package-project.js";
import { validateReleaseAssets } from "./release-assets.js";

const commandSchema = z.enum([
  "create-package-input",
  "create-package-project",
  "validate-release-assets"
]);
const pathSchema = z.string().min(1, "pathを空にできません");
const platformSchema = z.enum(["macos", "windows"]);
const targetSchema = z.enum(["macos", "windows-nsis", "windows-nsis-web"]);

const inputOptionsSchema = z
  .object({
    "source-directory": pathSchema,
    "prepackaged-directory": pathSchema,
    platform: platformSchema,
    "output-directory": pathSchema
  })
  .strict();
const projectOptionsSchema = z
  .object({
    "package-input-directory": pathSchema,
    target: targetSchema,
    repository: z
      .string()
      .regex(
        /^[A-Za-z0-9](?:[A-Za-z0-9_.-]*[A-Za-z0-9])?\/[A-Za-z0-9](?:[A-Za-z0-9_.-]*[A-Za-z0-9])?$/,
        "repositoryはowner/name形式で指定してください"
      ),
    tag: z.string().min(1, "tagを空にできません"),
    "output-directory": pathSchema
  })
  .strict();
const assetsOptionsSchema = z
  .object({
    "assets-directory": pathSchema,
    "expected-version": z.string().min(1, "expected-versionを空にできません")
  })
  .strict();

type ParsedOptions = Record<string, string>;

function parseCommand(value: string | undefined): z.infer<typeof commandSchema> {
  return commandSchema.parse(value);
}

function parseOptions(args: string[]): {
  command: z.infer<typeof commandSchema>;
  options: ParsedOptions;
} {
  const parsed = parseArgs({
    args,
    options: {
      "source-directory": { type: "string", multiple: true },
      "prepackaged-directory": { type: "string", multiple: true },
      platform: { type: "string", multiple: true },
      "output-directory": { type: "string", multiple: true },
      "package-input-directory": { type: "string", multiple: true },
      target: { type: "string", multiple: true },
      repository: { type: "string", multiple: true },
      tag: { type: "string", multiple: true },
      "assets-directory": { type: "string", multiple: true },
      "expected-version": { type: "string", multiple: true }
    },
    allowPositionals: true,
    strict: true
  });
  if (parsed.positionals.length !== 1) {
    throw new Error("subcommandは一つだけ指定してください");
  }
  const command = parseCommand(parsed.positionals[0]);
  const options: ParsedOptions = {};
  for (const [key, value] of Object.entries(parsed.values)) {
    if (!Array.isArray(value) || value.length !== 1) {
      throw new Error(`optionが重複または不正です: --${key}`);
    }
    const optionValue = value[0];
    if (optionValue == undefined) {
      throw new Error(`optionの値がありません: --${key}`);
    }
    options[key] = optionValue;
  }
  return { command, options };
}

function executeCreatePackageInput(options: ParsedOptions): void {
  const parsed = inputOptionsSchema.parse(options);
  createPackageInput(
    parsed["source-directory"],
    parsed["prepackaged-directory"],
    parsed.platform,
    parsed["output-directory"]
  );
}

function executeCreatePackageProject(options: ParsedOptions): void {
  const parsed = projectOptionsSchema.parse(options);
  createPackageProject(
    parsed["package-input-directory"],
    parsed.target,
    parsed.repository,
    parsed.tag,
    parsed["output-directory"]
  );
}

function executeValidateReleaseAssets(options: ParsedOptions): void {
  const parsed = assetsOptionsSchema.parse(options);
  validateReleaseAssets(parsed["assets-directory"], parsed["expected-version"]);
}

/** CLI引数を検証してpackage input、package project、asset検証を実行します。 */
export function runCli(args: string[]): void {
  const { command, options } = parseOptions(args);
  if (command === "create-package-input") {
    executeCreatePackageInput(options);
    return;
  }
  if (command === "create-package-project") {
    executeCreatePackageProject(options);
    return;
  }
  executeValidateReleaseAssets(options);
}

if (process.argv[1] != undefined && fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
  runCli(process.argv.slice(2));
}
