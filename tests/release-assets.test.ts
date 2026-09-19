import { strict as assert } from "node:assert";
import { createHash } from "node:crypto";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
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

function metadata(
  version: string,
  asset: Asset,
  blockmap: Asset,
  includeBlockMapSize: boolean
): string {
  const lines = [
    `version: ${version}`,
    "files:",
    `  - url: ${asset.name}`,
    `    sha512: ${hash(asset.content)}`,
    `    size: ${asset.content.length}`,
    `path: ${asset.name}`,
    `sha512: ${hash(asset.content)}`,
    ""
  ];
  if (includeBlockMapSize) {
    lines.splice(5, 0, `    blockMapSize: ${blockmap.content.length}`);
  }
  return lines.join("\n");
}

type MetadataNames = {
  macos: string;
  windows: string;
};

function writeAssets(root: string, version: string, metadataNames: MetadataNames): void {
  const mac = { name: "app.zip", content: Buffer.from("mac") };
  const macBlockmap = { name: "app.zip.blockmap", content: Buffer.from("mac-blockmap") };
  const windows = { name: "app.exe", content: Buffer.from("windows") };
  const windowsBlockmap = {
    name: "app.exe.blockmap",
    content: Buffer.from("windows-blockmap")
  };
  const webInstaller = {
    name: `app Web Setup ${version}.exe`,
    content: Buffer.from("web-installer")
  };
  const webPackage = {
    name: `app-${version}-x64.nsis.7z`,
    content: Buffer.from("web-package")
  };
  for (const asset of [mac, macBlockmap, windows, windowsBlockmap, webInstaller, webPackage]) {
    writeFileSync(join(root, asset.name), asset.content);
  }
  writeFileSync(join(root, metadataNames.macos), metadata(version, mac, macBlockmap, false));
  writeFileSync(
    join(root, metadataNames.windows),
    metadata(version, windows, windowsBlockmap, false)
  );
}

function withAssets(
  version: string,
  metadataNames: MetadataNames,
  run: (root: string) => void
): void {
  const root = mkdtempSync(join(tmpdir(), "release-assets-test-"));
  try {
    writeAssets(root, version, metadataNames);
    run(root);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

void test("stableの両OS metadataと必須assetを検証できる", () => {
  withAssets("1.0.0", { macos: "latest-mac.yml", windows: "latest.yml" }, (root) => {
    assert.doesNotThrow(() => validateReleaseAssets(root, "1.0.0"));
    assert.equal(existsSync(join(root, "app Web Setup 1.0.0.exe")), true);
    assert.equal(existsSync(join(root, "app-1.0.0-x64.nsis.7z")), true);
  });
});

void test("prerelease channelの両OS metadataを検証できる", () => {
  withAssets("1.0.0-beta.1", { macos: "beta-mac.yml", windows: "beta.yml" }, (root) => {
    assert.doesNotThrow(() => validateReleaseAssets(root, "1.0.0-beta.1"));
  });
});

void test("必須assetが欠けると検証に失敗する", () => {
  withAssets("1.0.0", { macos: "latest-mac.yml", windows: "latest.yml" }, (root) => {
    rmSync(join(root, "app.exe"));
    assert.throws(() => validateReleaseAssets(root, "1.0.0"));
  });
});

void test("macOSとWindowsの外部blockmapを必須にする", () => {
  withAssets("1.0.0", { macos: "latest-mac.yml", windows: "latest.yml" }, (root) => {
    rmSync(join(root, "app.zip.blockmap"));
    assert.throws(() => validateReleaseAssets(root, "1.0.0"));
  });
  withAssets("1.0.0", { macos: "latest-mac.yml", windows: "latest.yml" }, (root) => {
    rmSync(join(root, "app.exe.blockmap"));
    assert.throws(() => validateReleaseAssets(root, "1.0.0"));
  });
});

void test("blockMapSizeが存在するときだけ実サイズを照合する", () => {
  withAssets("1.0.0", { macos: "latest-mac.yml", windows: "latest.yml" }, (root) => {
    const mac = { name: "app.zip", content: Buffer.from("mac") };
    const macBlockmap = { name: "app.zip.blockmap", content: Buffer.from("mac-blockmap") };
    writeFileSync(join(root, "latest-mac.yml"), metadata("1.0.0", mac, macBlockmap, true));
    assert.doesNotThrow(() => validateReleaseAssets(root, "1.0.0"));
    writeFileSync(join(root, macBlockmap.name), Buffer.from("wrong"));
    assert.throws(() => validateReleaseAssets(root, "1.0.0"));
  });
});

void test("metadataのversionが一致しないと検証に失敗する", () => {
  withAssets("1.0.0", { macos: "latest-mac.yml", windows: "latest.yml" }, (root) => {
    assert.throws(() => validateReleaseAssets(root, "2.0.0"));
  });
});

void test("SemVerの英数字prerelease identifierを受け付ける", () => {
  assert.equal(parseSemVer("1.0.0-1a"), "1.0.0-1a");
});
