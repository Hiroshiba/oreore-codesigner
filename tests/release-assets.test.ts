import { strict as assert } from "node:assert";
import { createHash } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { parseSemVer } from "../src/schema.js";
import { validateReleaseAssets } from "../src/release-assets.js";

type Asset = {
  content: Buffer;
  name: string;
};

function hash(content: Buffer): string {
  return createHash("sha512").update(content).digest("base64");
}

function metadata(version: string, asset: Asset, blockmap: Asset): string {
  return [
    `version: ${version}`,
    "files:",
    `  - url: ${asset.name}`,
    `    sha512: ${hash(asset.content)}`,
    `    size: ${asset.content.length}`,
    `    blockMapSize: ${blockmap.content.length}`,
    `path: ${asset.name}`,
    `sha512: ${hash(asset.content)}`,
    ""
  ].join("\n");
}

function writeAssets(root: string, version: string): void {
  const mac = { name: "app.zip", content: Buffer.from("mac") };
  const macBlockmap = { name: "app.zip.blockmap", content: Buffer.from("mac-blockmap") };
  const windows = { name: "app.exe", content: Buffer.from("windows") };
  const windowsBlockmap = {
    name: "app.exe.blockmap",
    content: Buffer.from("windows-blockmap")
  };
  const webInstaller = { name: "app-web.exe", content: Buffer.from("web-installer") };
  const webPackage = { name: "app-web.exe.7z", content: Buffer.from("web-package") };
  for (const asset of [mac, macBlockmap, windows, windowsBlockmap, webInstaller, webPackage]) {
    writeFileSync(join(root, asset.name), asset.content);
  }
  writeFileSync(join(root, "latest-mac.yml"), metadata(version, mac, macBlockmap));
  writeFileSync(join(root, "latest.yml"), metadata(version, windows, windowsBlockmap));
}

function withAssets(run: (root: string) => void): void {
  const root = mkdtempSync(join(tmpdir(), "release-assets-test-"));
  try {
    writeAssets(root, "1.0.0");
    run(root);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

void test("両OSのmetadataと必須assetを検証できる", () => {
  withAssets((root) => {
    assert.doesNotThrow(() => validateReleaseAssets(root, "1.0.0"));
  });
});

void test("必須assetが欠けると検証に失敗する", () => {
  withAssets((root) => {
    rmSync(join(root, "app.exe"));
    assert.throws(() => validateReleaseAssets(root, "1.0.0"));
  });
});

void test("metadataのversionが一致しないと検証に失敗する", () => {
  withAssets((root) => {
    assert.throws(() => validateReleaseAssets(root, "2.0.0"));
  });
});

void test("SemVerの英数字prerelease identifierを受け付ける", () => {
  assert.equal(parseSemVer("1.0.0-1a"), "1.0.0-1a");
});
