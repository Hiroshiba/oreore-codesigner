import { z } from "zod";

const semverIdentifier = "(?:0|[1-9][0-9]*|[A-Za-z-][0-9A-Za-z-]*)";
const semverPattern = new RegExp(
  `^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(?:-(${semverIdentifier}(?:\\.${semverIdentifier})*))?(?:\\+[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?$`
);
const appIdPattern = /^[A-Za-z][A-Za-z0-9-]*(?:\.[A-Za-z][A-Za-z0-9-]*)+$/;
const packageNamePattern = /^(?:@[A-Za-z0-9._-]+\/)?[A-Za-z0-9._-]+$/;
const repositoryPattern =
  /^[A-Za-z0-9](?:[A-Za-z0-9_.-]*[A-Za-z0-9])?\/[A-Za-z0-9](?:[A-Za-z0-9_.-]*[A-Za-z0-9])?$/;
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const sha512Pattern = /^(?:[0-9A-Fa-f]{128}|[A-Za-z0-9+/]{86}==)$/;
const packageManagerPattern =
  /^pnpm@(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:\+[A-Za-z0-9._-]+)?$/;
const artifactTokens = new Set(["version", "name", "productName", "arch", "ext"]);

function isValidArtifactName(value: string): boolean {
  if (value.length === 0) {
    return false;
  }
  let index = 0;
  let hasPart = false;
  while (index < value.length) {
    if (value.startsWith("${", index)) {
      const tokenEnd = value.indexOf("}", index + 2);
      if (tokenEnd < 0 || !artifactTokens.has(value.slice(index + 2, tokenEnd))) {
        return false;
      }
      hasPart = true;
      index = tokenEnd + 1;
      continue;
    }
    const character = value[index];
    if (character == undefined || !/[A-Za-z0-9._-]/u.test(character)) {
      return false;
    }
    if (index === 0 && !/[A-Za-z0-9]/u.test(character)) {
      return false;
    }
    hasPart = true;
    index += 1;
  }
  return hasPart;
}

function isValidGitRef(value: string): boolean {
  if (
    value.length === 0 ||
    value === "@" ||
    value.startsWith("/") ||
    value.endsWith("/") ||
    value.includes("//") ||
    value.includes("..") ||
    value.includes("@{") ||
    value.endsWith(".") ||
    value.includes("~") ||
    value.includes("^") ||
    value.includes(":") ||
    value.includes("?") ||
    value.includes("*") ||
    value.includes("[") ||
    value.includes("\\")
  ) {
    return false;
  }
  for (const character of value) {
    const code = character.codePointAt(0);
    if (code == undefined) {
      throw new Error("tagの文字を解析できません");
    }
    if (code <= 0x20 || code === 0x7f) {
      return false;
    }
  }
  return value
    .split("/")
    .every(
      (segment) =>
        segment.length > 0 &&
        segment !== "." &&
        segment !== ".." &&
        segment !== "@" &&
        !segment.startsWith(".") &&
        !segment.endsWith(".lock")
    );
}

const semverSchema = z.string().regex(semverPattern, "SemVer形式で指定してください");
const appIdSchema = z.string().regex(appIdPattern, "appIdはreverse-DNS形式で指定してください");
const packageNameSchema = z.string().regex(packageNamePattern, "package nameが不正です");
const repositorySchema = z
  .string()
  .regex(repositoryPattern, "repositoryはowner/name形式で指定してください");
const tagSchema = z.string().refine(isValidGitRef, "tagはGit refとして不正です");
const uuidSchema = z.string().regex(uuidPattern, "GUIDはcanonical UUIDで指定してください");
const nonEmptyStringSchema = z.string().min(1, "空文字は指定できません");
const productNameSchema = nonEmptyStringSchema
  .refine((value) => value.trim() === value, "productNameの先頭末尾に空白を指定できません")
  .refine(
    (value) =>
      !value.includes("/") &&
      !value.includes("\\") &&
      [...value].every((character) => {
        const code = character.codePointAt(0);
        return (
          code != undefined && code >= 0x20 && code !== 0x7f && !(code >= 0x80 && code <= 0x9f)
        );
      }),
    "productNameに制御文字またはpath separatorを指定できません"
  );
const packageManagerSchema = z
  .string()
  .regex(packageManagerPattern, "Corepackが受理するpnpmのexact specを指定してください");
const relativePathSchema = z
  .string()
  .min(1, "pathを空にできません")
  .refine((value) => {
    if (
      value.startsWith("/") ||
      value.includes("\\") ||
      value.includes(":") ||
      value.includes("\u0000")
    ) {
      return false;
    }
    return value
      .split("/")
      .every((segment) => segment.length > 0 && segment !== "." && segment !== "..");
  }, "相対POSIX pathを指定してください");
const fileNameSchema = z
  .string()
  .min(1, "filenameを空にできません")
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
      }),
    "basenameを指定してください"
  );
const artifactNameSchema = z
  .string()
  .refine(isValidArtifactName, "artifactNameが不正です")
  .refine((value) => !value.endsWith("."), "artifactNameの末尾にdotを指定できません");
const executableNameSchema = fileNameSchema.refine(
  (value) => !value.toLowerCase().endsWith(".exe"),
  "executableNameは拡張子なしで指定してください"
);

const signingFingerprintSchema = z
  .string()
  .regex(
    /^(?:[0-9A-Fa-f]{64}|(?:[0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2})$/,
    "SHA-256 fingerprintが不正です"
  );

const unconfiguredSigningSchema = z.object({ configured: z.literal(false) }).strict();
const configuredMacosSigningSchema = z
  .object({
    configured: z.literal(true),
    certificatePath: relativePathSchema,
    fingerprint: signingFingerprintSchema,
    displayName: nonEmptyStringSchema
  })
  .strict();
const configuredWindowsSigningSchema = z
  .object({
    configured: z.literal(true),
    certificatePath: relativePathSchema,
    fingerprint: signingFingerprintSchema,
    displayName: nonEmptyStringSchema,
    timestampUrl: z
      .string()
      .url("timestampUrlはURLで指定してください")
      .refine(
        (value) => new URL(value).protocol === "https:",
        "timestampUrlはHTTPSで指定してください"
      )
  })
  .strict();
const macosSigningSchema = z.discriminatedUnion("configured", [
  unconfiguredSigningSchema,
  configuredMacosSigningSchema
]);
const windowsSigningSchema = z.discriminatedUnion("configured", [
  unconfiguredSigningSchema,
  configuredWindowsSigningSchema
]);
const signingConfigSchema = z
  .object({
    macos: macosSigningSchema,
    windows: windowsSigningSchema
  })
  .strict();

const shortcutSchema = z.union([z.boolean(), z.enum(["always", "never", "onLogin"])]);
const nsisOptionsSchema = z
  .object({
    oneClick: z.boolean().optional(),
    perMachine: z.boolean().optional(),
    allowToChangeInstallationDirectory: z.boolean().optional(),
    allowElevation: z.boolean().optional(),
    createDesktopShortcut: shortcutSchema.optional(),
    createStartMenuShortcut: shortcutSchema.optional(),
    createQuickLaunchShortcut: shortcutSchema.optional(),
    shortcutName: fileNameSchema.optional(),
    menuCategory: fileNameSchema.optional(),
    uninstallDisplayName: productNameSchema.optional(),
    deleteAppDataOnUninstall: z.boolean().optional(),
    runAfterFinish: z.boolean().optional(),
    artifactName: artifactNameSchema.optional(),
    guid: uuidSchema.optional()
  })
  .strict();

const architectureSchema = z.enum(["x64", "arm64"]);
const macosInputSchema = z
  .object({
    architecture: architectureSchema,
    artifactName: artifactNameSchema.optional(),
    entitlements: fileNameSchema.optional(),
    entitlementsInherit: fileNameSchema.optional(),
    hardenedRuntime: z.boolean().optional(),
    gatekeeperAssess: z.boolean().optional()
  })
  .strict();
const windowsInputSchema = z
  .object({
    architecture: z.literal("x64"),
    executableName: executableNameSchema,
    publisherName: productNameSchema.optional(),
    artifactName: artifactNameSchema.optional(),
    guid: uuidSchema.optional(),
    nsis: nsisOptionsSchema.optional(),
    nsisWeb: nsisOptionsSchema.optional()
  })
  .strict();

const packageInputSchema = z.discriminatedUnion("platform", [
  z
    .object({
      platform: z.literal("macos"),
      name: packageNameSchema,
      version: semverSchema,
      appId: appIdSchema,
      productName: productNameSchema,
      macos: macosInputSchema
    })
    .strict(),
  z
    .object({
      platform: z.literal("windows"),
      name: packageNameSchema,
      version: semverSchema,
      appId: appIdSchema,
      productName: productNameSchema,
      windows: windowsInputSchema
    })
    .strict()
]);

const metadataFileSchema = z
  .object({
    url: fileNameSchema,
    size: z.number().int().nonnegative(),
    sha512: z.string().regex(sha512Pattern, "metadata sha512が不正です"),
    blockMapSize: z.number().int().nonnegative().optional()
  })
  .strict();
const updateMetadataSchema = z
  .object({
    version: semverSchema,
    files: z.array(metadataFileSchema).min(1),
    path: fileNameSchema,
    sha512: z.string().regex(sha512Pattern, "metadata sha512が不正です"),
    releaseDate: z.string().optional(),
    stagingPercentage: z.number().optional(),
    minimumSystemVersion: z.string().optional(),
    sha2: z.string().optional(),
    isAdminRightsRequired: z.boolean().optional()
  })
  .strict();

export type SigningConfig = z.infer<typeof signingConfigSchema>;
export type PackageInput = z.infer<typeof packageInputSchema>;
export type PackageProjectTarget = "macos" | "windows-nsis" | "windows-nsis-web";
export type UpdateMetadata = z.infer<typeof updateMetadataSchema>;

export { packageInputSchema, signingConfigSchema, updateMetadataSchema };

/** signing.jsonをstrictなschemaで検証します。 */
export function parseSigningConfig(value: unknown): SigningConfig {
  return signingConfigSchema.parse(value);
}

/** package-input.jsonをstrictなschemaで検証します。 */
export function parsePackageInput(value: unknown): PackageInput {
  return packageInputSchema.parse(value);
}

/** 更新metadataをstrictなschemaで検証します。 */
export function parseUpdateMetadata(value: unknown): UpdateMetadata {
  return updateMetadataSchema.parse(value);
}

/** SemVer文字列を検証します。 */
export function parseSemVer(value: string): string {
  return semverSchema.parse(value);
}

/** repository文字列を検証します。 */
export function parseRepository(value: string): string {
  return repositorySchema.parse(value);
}

/** Git tag文字列を検証します。 */
export function parseGitTag(value: string): string {
  return tagSchema.parse(value);
}

/** packageManager文字列を検証します。 */
export function parsePackageManager(value: string): string {
  return packageManagerSchema.parse(value);
}

/** relative pathを検証します。 */
export function parseRelativePath(value: string): string {
  return relativePathSchema.parse(value);
}

/** artifactName patternを検証します。 */
export function parseArtifactName(value: string): string {
  return artifactNameSchema.parse(value);
}

/** Windows executableNameを検証します。 */
export function parseExecutableName(value: string): string {
  return executableNameSchema.parse(value);
}

/** appId文字列を検証します。 */
export function parseAppId(value: string): string {
  return appIdSchema.parse(value);
}
