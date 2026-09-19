import { parseArgs } from "node:util";
import { z } from "zod";
import { validateReleaseAssets } from "./release-assets.js";

const commandSchema = z.literal("validate-release-assets");
const pathSchema = z.string().min(1, "pathを空にできません");
const optionsSchema = z
  .object({
    "assets-directory": pathSchema,
    "expected-version": z.string().min(1, "expected-versionを空にできません")
  })
  .strict();

type ParsedOptions = Record<string, string>;

function parseOptions(args: string[]): ParsedOptions {
  const parsed = parseArgs({
    args,
    options: {
      "assets-directory": { type: "string", multiple: true },
      "expected-version": { type: "string", multiple: true }
    },
    allowPositionals: true,
    strict: true
  });
  if (parsed.positionals.length !== 1) {
    throw new Error("subcommandは一つだけ指定してください");
  }
  commandSchema.parse(parsed.positionals[0]);
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
  return options;
}

/** CLI引数を検証してRelease assetを検証します。 */
function runCli(args: string[]): void {
  const options = optionsSchema.parse(parseOptions(args));
  validateReleaseAssets(options["assets-directory"], options["expected-version"]);
}

runCli(process.argv.slice(2));
