import { parseArgs } from "node:util";
import { z } from "zod";
import { validatePackagedOutput } from "./package-assets.js";
import { validateReleaseAssets } from "./release-assets.js";
import { validateSourceContract } from "./source-contract.js";

const commandSchema = z.union([
  z.literal("validate-release-assets"),
  z.literal("validate-source"),
  z.literal("validate-packaged-output")
]);
const pathSchema = z.string().min(1, "pathを空にできません");
const releaseOptionsSchema = z
  .object({
    "assets-directory": pathSchema,
    "expected-version": z.string().min(1, "expected-versionを空にできません")
  })
  .strict();
const sourceOptionsSchema = z
  .object({
    "source-directory": pathSchema
  })
  .strict();
const packagedOutputOptionsSchema = z
  .object({
    "output-directory": pathSchema,
    platform: z.enum(["macos", "windows"]),
    channel: z.string().min(1, "channelを空にできません"),
    "expected-version": z.string().min(1, "expected-versionを空にできません")
  })
  .strict();

type ParsedOptions = Record<string, string>;
type ParsedCommand = {
  command: z.infer<typeof commandSchema>;
  options: ParsedOptions;
};

function parseOptions(args: string[]): ParsedCommand {
  const parsed = parseArgs({
    args,
    options: {
      "assets-directory": { type: "string", multiple: true },
      "expected-version": { type: "string", multiple: true },
      "source-directory": { type: "string", multiple: true },
      "output-directory": { type: "string", multiple: true },
      platform: { type: "string", multiple: true },
      channel: { type: "string", multiple: true }
    },
    allowPositionals: true,
    strict: true
  });
  if (parsed.positionals.length !== 1) {
    throw new Error("subcommandは一つだけ指定してください");
  }
  const command = commandSchema.parse(parsed.positionals[0]);
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

/** CLI引数を検証して指定された検証を実行します。 */
function runCli(args: string[]): void {
  const parsed = parseOptions(args);
  if (parsed.command === "validate-release-assets") {
    const options = releaseOptionsSchema.parse(parsed.options);
    validateReleaseAssets(options["assets-directory"], options["expected-version"]);
    return;
  }
  if (parsed.command === "validate-source") {
    const options = sourceOptionsSchema.parse(parsed.options);
    const contract = validateSourceContract(options["source-directory"]);
    process.stdout.write(
      `${JSON.stringify({
        version: contract.version,
        channel: contract.channel,
        builder_config: contract.builderConfig
      })}\n`
    );
    return;
  }
  const options = packagedOutputOptionsSchema.parse(parsed.options);
  const result = validatePackagedOutput(
    options["output-directory"],
    options.platform,
    options.channel,
    options["expected-version"]
  );
  process.stdout.write(`${JSON.stringify(result)}\n`);
}

runCli(process.argv.slice(2));
