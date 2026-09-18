import { z } from "zod";

const semverIdentifier = "(?:0|[1-9][0-9]*|[A-Za-z-][0-9A-Za-z-]*)";
const semverPattern = new RegExp(
  `^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(?:-(${semverIdentifier}(?:\\.${semverIdentifier})*))?(?:\\+[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?$`
);

const appIdPattern = /^[A-Za-z][A-Za-z0-9-]*(?:\.[A-Za-z][A-Za-z0-9-]*)+$/;
const appKeyPattern = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
const buildScriptPattern = /^[A-Za-z0-9:_-]+$/;
const packageManagerPattern = /^pnpm@(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/;
const packageNamePattern = /^(?:@[A-Za-z0-9._-]+\/)?[A-Za-z0-9._-]+$/;
const artifactNamePattern = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const repositoryPattern =
  /^[A-Za-z0-9](?:[A-Za-z0-9_.-]*[A-Za-z0-9])?\/[A-Za-z0-9](?:[A-Za-z0-9_.-]*[A-Za-z0-9])?$/;
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const fingerprintPattern = /^(?:[0-9A-Fa-f]{64}|(?:[0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2})$/;
const digestPattern = /^sha256:[0-9a-fA-F]{64}$/;
const sha512Pattern = /^(?:[0-9A-Fa-f]{128}|[A-Za-z0-9+/]{86}==)$/;

function isValidGitRef(value: string, allowTrailingSlash: boolean): boolean {
  if (
    value.length === 0 ||
    value === "@" ||
    value.startsWith("/") ||
    (!allowTrailingSlash && value.endsWith("/")) ||
    value.includes("//") ||
    value.includes("..") ||
    value.includes("@{") ||
    (!allowTrailingSlash && value.endsWith(".")) ||
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
    if (code === undefined) {
      throw new Error("tagの文字を解析できません");
    }
    if (code <= 0x20 || code === 0x7f) {
      return false;
    }
  }
  const segments = value.split("/");
  return segments.every(
    (segment) =>
      (allowTrailingSlash && segment === "") ||
      (segment.length > 0 &&
        segment !== "." &&
        segment !== ".." &&
        segment !== "@" &&
        !segment.startsWith(".") &&
        !segment.endsWith(".") &&
        !segment.endsWith(".lock"))
  );
}

function isValidGitTag(value: string): boolean {
  return isValidGitRef(value, false);
}

function isValidGitTagPrefix(value: string): boolean {
  return isValidGitRef(value, true);
}

const semverSchema = z.string().regex(semverPattern, "SemVer形式で指定してください");
const appKeySchema = z.string().regex(appKeyPattern, "app_idは小文字kebab-caseで指定してください");
const packageManagerSchema = z
  .string()
  .regex(packageManagerPattern, "pnpmのexact versionを指定してください");
const repositorySchema = z
  .string()
  .regex(repositoryPattern, "repositoryはowner/name形式で指定してください");
const packageNameSchema = z.string().regex(packageNamePattern, "packageNameが不正です");
const appIdSchema = z.string().regex(appIdPattern, "appIdはreverse-DNS形式で指定してください");
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
          code !== undefined && code >= 0x20 && code !== 0x7f && !(code >= 0x80 && code <= 0x9f)
        );
      }),
    "productNameに制御文字またはpath separatorを指定できません"
  );
const artifactNameSchema = z
  .string()
  .regex(artifactNamePattern, "artifactNameが不正です")
  .refine((value) => !value.endsWith("."), "artifactNameの末尾にdotを指定できません");

function isRelativePosixPath(value: string, allowCurrentDirectory: boolean): boolean {
  if (
    value.length === 0 ||
    value.includes("\\") ||
    value.includes(":") ||
    value.startsWith("/") ||
    value.includes("\u0000")
  ) {
    return false;
  }
  if (value === ".") {
    return allowCurrentDirectory;
  }
  const segments = value.split("/");
  return segments.every((segment) => segment.length > 0 && segment !== "." && segment !== "..");
}

const workingDirectorySchema = z
  .string()
  .refine(
    (value) => isRelativePosixPath(value, true),
    "workingDirectoryは相対POSIX pathで指定してください"
  );
const centralPathSchema = z
  .string()
  .refine(
    (value) => isRelativePosixPath(value, false),
    "中央repo内の相対POSIX pathで指定してください"
  );
const buildScriptSchema = z.string().regex(buildScriptPattern, "build script名が不正です");
const tagPartSchema = z.string().refine(isValidGitTag, "tagはGit refとして不正です");
const tagPrefixSchema = z.string().refine(isValidGitTagPrefix, "tag prefixが不正です");

const macosRunnerSchema = z.enum(["macos-14", "macos-15"]);
const windowsRunnerSchema = z.enum(["windows-2022", "windows-2025"]);
const architectureSchema = z.enum(["x64", "arm64"]);

const versionedTagStrategySchema = z
  .object({
    type: z.literal("versioned"),
    prefix: tagPrefixSchema
  })
  .strict();

const rollingTagStrategySchema = z
  .object({
    type: z.literal("rolling"),
    tag: tagPartSchema
  })
  .strict();

const tagStrategySchema = z.discriminatedUnion("type", [
  versionedTagStrategySchema,
  rollingTagStrategySchema
]);

const releaseSchema = z
  .object({
    tagStrategy: tagStrategySchema,
    channel: z.enum(["latest", "beta", "dev"]),
    assetPolicy: z.enum(["append-only", "replaceable"])
  })
  .strict()
  .superRefine((release, context) => {
    if (release.tagStrategy.type === "versioned") {
      if (release.channel === "dev") {
        context.addIssue({
          code: z.ZodIssueCode.custom,
          message: "versionedはdev channelにできません"
        });
      }
      if (release.assetPolicy !== "append-only") {
        context.addIssue({
          code: z.ZodIssueCode.custom,
          message: "versionedはappend-onlyにしてください"
        });
      }
    }
    if (release.tagStrategy.type === "rolling") {
      if (release.channel !== "dev") {
        context.addIssue({
          code: z.ZodIssueCode.custom,
          message: "rollingはdev channelにしてください"
        });
      }
      if (release.assetPolicy !== "replaceable") {
        context.addIssue({
          code: z.ZodIssueCode.custom,
          message: "rollingはreplaceableにしてください"
        });
      }
    }
  });

const buildScriptsSchema = z
  .object({
    macos: buildScriptSchema,
    windows: buildScriptSchema
  })
  .strict();

const identitySchema = z
  .object({
    appId: appIdSchema,
    productName: productNameSchema,
    artifactName: artifactNameSchema
  })
  .strict();

const macosSchema = z
  .object({
    runner: macosRunnerSchema,
    architecture: architectureSchema,
    entitlements: centralPathSchema,
    entitlementsInherit: centralPathSchema
  })
  .strict();

const windowsSchema = z
  .object({
    runner: windowsRunnerSchema,
    architecture: z.literal("x64"),
    executableName: z
      .string()
      .min(1, "executableNameは空にできません")
      .refine(
        (value) => !value.includes("/") && !value.includes("\\"),
        "executableNameにpath separatorは使えません"
      ),
    guid: z.string().regex(uuidPattern, "guidはcanonical UUIDで指定してください"),
    publisherName: nonEmptyStringSchema
  })
  .strict();

const applicationSchema = z
  .object({
    repository: repositorySchema,
    workingDirectory: workingDirectorySchema,
    packageName: packageNameSchema,
    pnpmVersion: z
      .string()
      .regex(
        /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/,
        "pnpmVersionはexact versionで指定してください"
      ),
    buildScripts: buildScriptsSchema,
    identity: identitySchema,
    macos: macosSchema,
    windows: windowsSchema,
    release: releaseSchema
  })
  .strict();

const applicationsConfigSchema = z
  .object({
    applications: z.record(appKeySchema, applicationSchema)
  })
  .strict()
  .superRefine((config, context) => {
    const repositories = new Set<string>();
    const appIds = new Set<string>();
    const guids = new Set<string>();
    for (const [appKey, application] of Object.entries(config.applications)) {
      const repositoryKey = `${application.repository.toLowerCase()}\u0000${application.workingDirectory}`;
      if (repositories.has(repositoryKey)) {
        context.addIssue({
          code: z.ZodIssueCode.custom,
          path: ["applications", appKey, "repository"],
          message: "repositoryとworkingDirectoryが重複しています"
        });
      }
      repositories.add(repositoryKey);
      if (appIds.has(application.identity.appId)) {
        context.addIssue({
          code: z.ZodIssueCode.custom,
          path: ["applications", appKey, "identity", "appId"],
          message: "identity.appIdが重複しています"
        });
      }
      appIds.add(application.identity.appId);
      if (guids.has(application.windows.guid)) {
        context.addIssue({
          code: z.ZodIssueCode.custom,
          path: ["applications", appKey, "windows", "guid"],
          message: "Windows GUIDが重複しています"
        });
      }
      guids.add(application.windows.guid);
    }
  });

const fingerprintSchema = z.string().regex(fingerprintPattern, "SHA-256 fingerprintが不正です");

const unconfiguredSigningSchema = z
  .object({
    configured: z.literal(false)
  })
  .strict();

const configuredMacosSigningSchema = z
  .object({
    configured: z.literal(true),
    certificatePath: centralPathSchema,
    fingerprint: fingerprintSchema,
    displayName: nonEmptyStringSchema
  })
  .strict();

const configuredWindowsSigningSchema = z
  .object({
    configured: z.literal(true),
    certificatePath: centralPathSchema,
    fingerprint: fingerprintSchema,
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

const assetRoleSchema = z.enum([
  "macos-zip",
  "macos-dmg",
  "macos-metadata",
  "windows-nsis",
  "windows-nsis-blockmap",
  "windows-web-setup",
  "windows-web-package",
  "windows-metadata"
]);

const releaseAssetSchema = z
  .object({
    name: nonEmptyStringSchema,
    size: z.number().int().nonnegative(),
    digest: z.string().regex(digestPattern, "digestはsha256:<hex>形式で指定してください"),
    role: assetRoleSchema,
    sha512: z.string().regex(sha512Pattern, "sha512が不正です").optional()
  })
  .strict();

const contractBaseShape = {
  schemaVersion: z.literal(1),
  appId: appKeySchema,
  repository: repositorySchema,
  tag: tagPartSchema,
  replaceExistingAssets: z.boolean(),
  configDigest: z.string().regex(digestPattern, "configDigestはsha256:<hex>形式で指定してください"),
  application: applicationSchema
};

const preparedContractSchema = z
  .object(contractBaseShape)
  .strict()
  .superRefine((contract, context) => {
    if (contract.repository !== contract.application.repository) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        path: ["repository"],
        message: "repositoryがapplicationと一致しません"
      });
    }
    if (
      contract.replaceExistingAssets &&
      contract.application.release.assetPolicy !== "replaceable"
    ) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        path: ["replaceExistingAssets"],
        message: "append-only releaseでは置換を指定できません"
      });
    }
  });

const releaseContractSchema = z
  .object({
    ...contractBaseShape,
    version: semverSchema
  })
  .strict()
  .superRefine((contract, context) => {
    if (contract.repository !== contract.application.repository) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        path: ["repository"],
        message: "repositoryがapplicationと一致しません"
      });
    }
    if (
      contract.replaceExistingAssets &&
      contract.application.release.assetPolicy !== "replaceable"
    ) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        path: ["replaceExistingAssets"],
        message: "append-only releaseでは置換を指定できません"
      });
    }
    if (contract.application.release.tagStrategy.type === "versioned") {
      if (
        contract.tag !== `${contract.application.release.tagStrategy.prefix}${contract.version}`
      ) {
        context.addIssue({
          code: z.ZodIssueCode.custom,
          path: ["tag"],
          message: "versioned tagはprefixとpackage versionの完全一致でなければなりません"
        });
      }
      const versionWithoutBuild = contract.version.split("+")[0];
      const versionParts = versionWithoutBuild === undefined ? [] : versionWithoutBuild.split("-");
      const prerelease = versionParts.slice(1).join("-").split(".");
      if (contract.application.release.channel === "latest" && versionParts.length > 1) {
        context.addIssue({
          code: z.ZodIssueCode.custom,
          path: ["version"],
          message: "latest channelにはprerelease versionを指定できません"
        });
      }
      if (
        contract.application.release.channel === "beta" &&
        (versionParts.length === 1 || prerelease[0] !== "beta")
      ) {
        context.addIssue({
          code: z.ZodIssueCode.custom,
          path: ["version"],
          message: "beta channelのprerelease先頭識別子はbetaでなければなりません"
        });
      }
    }
    if (
      contract.application.release.tagStrategy.type === "rolling" &&
      contract.tag !== contract.application.release.tagStrategy.tag
    ) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        path: ["tag"],
        message: "rolling tagは固定値でなければなりません"
      });
    }
  });

const releaseManifestSchema = z
  .object({
    schemaVersion: z.literal(1),
    appId: appKeySchema,
    repository: repositorySchema,
    tag: tagPartSchema,
    version: semverSchema,
    assets: z.array(releaseAssetSchema),
    metadata: z
      .array(
        z
          .object({
            role: z.enum(["macos-metadata", "windows-metadata"]),
            name: nonEmptyStringSchema,
            path: nonEmptyStringSchema,
            files: z.array(nonEmptyStringSchema)
          })
          .strict()
      )
      .optional()
  })
  .strict();

const remoteAssetSchema = z
  .object({
    name: nonEmptyStringSchema,
    digest: z
      .string()
      .regex(digestPattern, "GitHub digestはsha256:<hex>形式で指定してください")
      .transform((value) => value.toLowerCase()),
    size: z.number().int().nonnegative().optional(),
    id: z.number().int().positive().optional(),
    url: z.string().url().optional(),
    node_id: z.string().optional(),
    label: z.string().nullable().optional(),
    browser_download_url: z.string().url().optional(),
    content_type: z.string().optional(),
    state: z.string().optional(),
    download_count: z.number().int().nonnegative().optional(),
    created_at: z.string().optional(),
    updated_at: z.string().optional(),
    uploader: z.record(z.string(), z.unknown()).optional()
  })
  .strict();

const publishActionSchema = z.enum(["upload", "skip", "replace", "update-metadata"]);
const publishOperationSchema = z
  .object({
    action: publishActionSchema,
    name: nonEmptyStringSchema,
    digest: z.string().regex(digestPattern),
    size: z.number().int().nonnegative(),
    role: assetRoleSchema
  })
  .strict();

const publishPlanSchema = z
  .object({
    schemaVersion: z.literal(1),
    appId: appKeySchema,
    repository: repositorySchema,
    tag: tagPartSchema,
    operations: z.array(publishOperationSchema),
    publishOrder: z.tuple([z.literal("payload"), z.literal("metadata")])
  })
  .strict();

export type ApplicationConfig = z.infer<typeof applicationSchema>;
export type ApplicationsConfig = z.infer<typeof applicationsConfigSchema>;
export type SigningConfig = z.infer<typeof signingConfigSchema>;
export type ReleaseConfig = z.infer<typeof releaseSchema>;
export type TagStrategy = z.infer<typeof tagStrategySchema>;
export type PreparedContract = z.infer<typeof preparedContractSchema>;
export type ReleaseContract = z.infer<typeof releaseContractSchema>;
export type ReleaseAsset = z.infer<typeof releaseAssetSchema>;
export type ReleaseManifest = z.infer<typeof releaseManifestSchema>;
export type RemoteAsset = z.infer<typeof remoteAssetSchema>;
export type PublishOperation = z.infer<typeof publishOperationSchema>;
export type PublishPlan = z.infer<typeof publishPlanSchema>;

export {
  applicationSchema,
  applicationsConfigSchema,
  assetRoleSchema,
  digestPattern,
  releaseContractSchema,
  releaseManifestSchema,
  preparedContractSchema,
  publishPlanSchema,
  remoteAssetSchema,
  releaseSchema,
  semverSchema,
  signingConfigSchema
};

/** applications.jsonをstrictなschemaで検証します。 */
export function parseApplicationsConfig(value: unknown): ApplicationsConfig {
  return applicationsConfigSchema.parse(value);
}

/** signing.jsonをstrictなschemaで検証します。 */
export function parseSigningConfig(value: unknown): SigningConfig {
  return signingConfigSchema.parse(value);
}

/** 準備済みcontractをstrictなschemaで検証します。 */
export function parsePreparedContract(value: unknown): PreparedContract {
  return preparedContractSchema.parse(value);
}

/** release contractをstrictなschemaで検証します。 */
export function parseReleaseContract(value: unknown): ReleaseContract {
  return releaseContractSchema.parse(value);
}

/** release manifestをstrictなschemaで検証します。 */
export function parseReleaseManifest(value: unknown): ReleaseManifest {
  return releaseManifestSchema.parse(value);
}

/** GitHub asset responseをstrictなschemaで検証します。 */
export function parseRemoteAssets(value: unknown): RemoteAsset[] {
  return z.array(remoteAssetSchema).parse(value);
}

/** 公開計画をstrictなschemaで検証します。 */
export function parsePublishPlan(value: unknown): PublishPlan {
  return publishPlanSchema.parse(value);
}

/** packageManager文字列がexactなpnpm versionか検証します。 */
export function parsePnpmVersion(value: string): string {
  return packageManagerSchema.parse(`pnpm@${value}`).slice("pnpm@".length);
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
  return tagPartSchema.parse(value);
}

/** relative POSIX pathを検証します。 */
export function parseCentralPath(value: string): string {
  return centralPathSchema.parse(value);
}

/** asset digestを検証します。 */
export function parseDigest(value: string): string {
  return z.string().regex(digestPattern).parse(value).toLowerCase();
}
