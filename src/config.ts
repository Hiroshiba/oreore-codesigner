import { lstatSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { parseSigningConfig, type SigningConfig } from "./schema.js";
import { assertNoSymlinkPath } from "./path-safety.js";

function assertRegularFile(path: string): void {
  assertNoSymlinkPath(path, "signing.jsonがregular fileではありません");
  let information;
  try {
    information = lstatSync(path);
  } catch (error) {
    throw new Error(`signing.jsonを確認できません: ${path}`, { cause: error });
  }
  if (!information.isFile() || information.isSymbolicLink()) {
    throw new Error(`signing.jsonがregular fileではありません: ${path}`);
  }
}

/** 中央のsigning.jsonを読み込みます。 */
export function loadSigningConfig(rootDirectory: string): SigningConfig {
  if (typeof rootDirectory !== "string" || rootDirectory.length === 0) {
    throw new Error("中央root directoryが不正です");
  }
  const path = resolve(rootDirectory, "config/signing.json");
  assertRegularFile(path);
  let source: string;
  try {
    source = readFileSync(path, "utf8");
  } catch (error) {
    throw new Error(`signing.jsonを読み込めません: ${path}`, { cause: error });
  }
  let value: unknown;
  try {
    value = JSON.parse(source);
  } catch (error) {
    throw new Error(`signing.jsonを解析できません: ${path}`, { cause: error });
  }
  return parseSigningConfig(value);
}
