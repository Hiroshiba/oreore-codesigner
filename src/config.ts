import { lstatSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { parseSigningConfig, type SigningConfig } from "./schema.js";
import { assertNoSymlinkPath } from "./path-safety.js";

function assertRegularFile(path: string): void {
  assertNoSymlinkPath(path, "signing.jsonがregular fileではありません");
  const information = lstatSync(path);
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
  const source = readFileSync(path, "utf8");
  return parseSigningConfig(JSON.parse(source));
}
