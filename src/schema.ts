import { z } from "zod";

const semverIdentifier = "(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)";
const semverPattern = new RegExp(
  `^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(?:-(${semverIdentifier}(?:\\.${semverIdentifier})*))?(?:\\+[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?$`
);
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
        return code != undefined && code >= 0x20 && code !== 0x7f;
      }),
    "basenameを指定してください"
  );
const semverSchema = z.string().regex(semverPattern, "SemVer形式で指定してください");
const sha512Schema = z.string().regex(/^[A-Za-z0-9+/]{86}==$/, "metadata sha512が不正です");
const metadataFileSchema = z
  .object({
    url: fileNameSchema,
    size: z.number().int().nonnegative(),
    sha512: sha512Schema,
    blockMapSize: z.number().int().nonnegative().optional()
  })
  .strict();
const updateMetadataSchema = z
  .object({
    version: semverSchema,
    files: z.array(metadataFileSchema).min(1),
    path: fileNameSchema,
    sha512: sha512Schema,
    releaseDate: z.string().optional(),
    stagingPercentage: z.number().optional(),
    minimumSystemVersion: z.string().optional(),
    sha2: z.string().optional(),
    isAdminRightsRequired: z.boolean().optional()
  })
  .strict();

export type UpdateMetadata = z.infer<typeof updateMetadataSchema>;

/** 更新metadataをstrictなschemaで検証します。 */
export function parseUpdateMetadata(value: unknown): UpdateMetadata {
  return updateMetadataSchema.parse(value);
}

/** SemVer文字列を検証します。 */
export function parseSemVer(value: string): string {
  return semverSchema.parse(value);
}
