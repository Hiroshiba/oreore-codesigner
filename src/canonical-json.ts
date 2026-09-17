import { createHash } from "node:crypto";

function quote(value: string): string {
  const encoded = JSON.stringify(value);
  if (encoded === undefined) {
    throw new Error("文字列をJSONに変換できません");
  }
  return encoded;
}

/** 値をキー順に並べたcanonical JSONへ変換します。 */
export function canonicalJson(value: unknown): string {
  if (value === null) {
    return "null";
  }
  if (typeof value === "string") {
    return quote(value);
  }
  if (typeof value === "boolean") {
    return value ? "true" : "false";
  }
  if (typeof value === "number") {
    if (!Number.isFinite(value)) {
      throw new Error("有限でない数値はcanonical JSONにできません");
    }
    return String(value);
  }
  if (Array.isArray(value)) {
    return `[${value.map((item) => canonicalJson(item)).join(",")}]`;
  }
  if (typeof value === "object") {
    const entries = Object.entries(value).sort(([left], [right]) => {
      if (left < right) {
        return -1;
      }
      if (left > right) {
        return 1;
      }
      return 0;
    });
    return `{${entries.map(([key, item]) => `${quote(key)}:${canonicalJson(item)}`).join(",")}}`;
  }
  throw new Error("canonical JSONにできない値です");
}

/** canonical JSONのSHA-256 digestを返します。 */
export function canonicalDigest(value: unknown): string {
  return `sha256:${createHash("sha256").update(canonicalJson(value), "utf8").digest("hex")}`;
}
