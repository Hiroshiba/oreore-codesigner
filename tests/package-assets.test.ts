import { strict as assert } from "node:assert";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { validatePackagedOutput } from "../src/package-assets.js";

const sha512 = "A".repeat(86) + "==";

function macMetadata(version: string): string {
  return [
    `version: ${version}`,
    "files:",
    "  - url: app.zip",
    `    sha512: ${sha512}`,
    "    size: 3",
    "path: app.zip",
    `sha512: ${sha512}`,
    ""
  ].join("\n");
}

function windowsMetadata(version: string, installer: string): string {
  return [
    `version: ${version}`,
    "files:",
    `  - url: ${installer}`,
    `    sha512: ${sha512}`,
    "    size: 3",
    `path: ${installer}`,
    `sha512: ${sha512}`,
    ""
  ].join("\n");
}

function webMetadata(
  version: string,
  installer: string,
  packageName: string,
  includeSize: boolean
): string {
  const lines = [
    `version: ${version}`,
    "files:",
    `  - url: ${installer}`,
    `    sha512: ${sha512}`,
    `path: ${installer}`,
    `sha512: ${sha512}`,
    "packages:",
    "  x64:",
    "    size: 11",
    `    sha512: ${sha512}`,
    `    path: ${packageName}`,
    `    file: ${packageName}`,
    ""
  ];
  if (includeSize) {
    lines.splice(4, 0, "    size: 7");
  }
  return lines.join("\n");
}

function withOutput(run: (directory: string) => void): void {
  const directory = mkdtempSync(join(tmpdir(), "package-assets-test-"));
  try {
    run(directory);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

void test("macOSはexact channel metadataからsubdirectoryのZIPと外部blockmapを選ぶ", () => {
  withOutput((directory) => {
    mkdirSync(join(directory, "nested"));
    writeFileSync(join(directory, "nested/app.zip"), "zip");
    writeFileSync(join(directory, "nested/app.zip.blockmap"), "blockmap");
    writeFileSync(join(directory, "latest-mac.yml"), macMetadata("1.0.0"));
    writeFileSync(join(directory, "builder-debug.yml"), "debug");
    writeFileSync(join(directory, "extra.zip"), "extra");
    const result = validatePackagedOutput(directory, "macos", "latest", "1.0.0");
    assert.deepEqual(result, {
      platform: "macos",
      metadata: "latest-mac.yml",
      artifact: "nested/app.zip",
      blockmap: "nested/app.zip.blockmap"
    });
  });
});

void test("macOSのmetadata欠落とartifact重複を拒否する", () => {
  withOutput((directory) => {
    assert.throws(() => validatePackagedOutput(directory, "macos", "latest", "1.0.0"));
  });
  withOutput((directory) => {
    mkdirSync(join(directory, "nested"));
    mkdirSync(join(directory, "duplicate"));
    writeFileSync(join(directory, "nested/app.zip"), "zip");
    writeFileSync(join(directory, "duplicate/app.zip"), "duplicate");
    writeFileSync(join(directory, "nested/app.zip.blockmap"), "blockmap");
    writeFileSync(join(directory, "latest-mac.yml"), macMetadata("1.0.0"));
    assert.throws(() => validatePackagedOutput(directory, "macos", "latest", "1.0.0"));
  });
});

void test("Windowsはfoo-mac channelの通常NSISとNSIS Webを独立に選ぶ", () => {
  withOutput((directory) => {
    const webDirectory = join(directory, "nsis-web", "nested");
    mkdirSync(join(directory, "nested"));
    mkdirSync(webDirectory, { recursive: true });
    const installer = "App Setup 1.0.0-foo-mac.1.exe";
    const webInstaller = "App Web Setup 1.0.0-foo-mac.1.exe";
    const packageName = "app-1.0.0-foo-mac.1-x64.nsis.7z";
    writeFileSync(join(directory, "nested", installer), "exe");
    writeFileSync(join(directory, "nested", `${installer}.blockmap`), "blockmap");
    writeFileSync(join(webDirectory, webInstaller), "web-exe");
    writeFileSync(join(webDirectory, packageName), "web-package");
    writeFileSync(join(directory, "foo-mac.yml"), windowsMetadata("1.0.0-foo-mac.1", installer));
    writeFileSync(
      join(directory, "nsis-web", "foo-mac.yml"),
      webMetadata("1.0.0-foo-mac.1", webInstaller, packageName, false)
    );
    writeFileSync(join(directory, "nsis-web", "unrelated.exe"), "extra");
    writeFileSync(join(directory, "nsis-web", "unrelated.nsis.7z"), "extra");
    const result = validatePackagedOutput(directory, "windows", "foo-mac", "1.0.0-foo-mac.1");
    assert.equal(result.platform, "windows");
    if (result.platform === "windows") {
      assert.equal(result.artifact, `nested/${installer}`);
      assert.equal(result.blockmap, `nested/${installer}.blockmap`);
      assert.equal(result.webInstaller, `nsis-web/nested/${webInstaller}`);
      assert.equal(result.webPackage, `nsis-web/nested/${packageName}`);
    }
  });
});

void test("NSIS Web metadataのfile sizeは省略または実fileと一致する値を受理する", () => {
  withOutput((directory) => {
    const webDirectory = join(directory, "nsis-web");
    mkdirSync(join(directory, "nested"));
    mkdirSync(webDirectory);
    const installer = "installer.exe";
    const webInstaller = "web.exe";
    const packageName = "package-x64.nsis.7z";
    writeFileSync(join(directory, "nested", installer), "exe");
    writeFileSync(join(directory, "nested", `${installer}.blockmap`), "blockmap");
    writeFileSync(join(webDirectory, webInstaller), "web-exe");
    writeFileSync(join(webDirectory, packageName), "web-package");
    writeFileSync(join(directory, "latest.yml"), windowsMetadata("1.0.0", installer));
    const metadataPath = join(webDirectory, "latest.yml");
    writeFileSync(metadataPath, webMetadata("1.0.0", webInstaller, packageName, true));
    assert.doesNotThrow(() => validatePackagedOutput(directory, "windows", "latest", "1.0.0"));
    writeFileSync(
      metadataPath,
      webMetadata("1.0.0", webInstaller, packageName, true).replace("size: 7", "size: 8")
    );
    assert.throws(() => validatePackagedOutput(directory, "windows", "latest", "1.0.0"));
  });
});

void test("Windowsの必須出力欠落と重複を拒否する", () => {
  withOutput((directory) => {
    mkdirSync(join(directory, "nsis-web"));
    writeFileSync(
      join(directory, "foo-mac.yml"),
      windowsMetadata("1.0.0-foo-mac.1", "installer.exe")
    );
    writeFileSync(
      join(directory, "nsis-web", "foo-mac.yml"),
      webMetadata("1.0.0-foo-mac.1", "web.exe", "package-x64.nsis.7z", false)
    );
    assert.throws(() => validatePackagedOutput(directory, "windows", "foo-mac", "1.0.0-foo-mac.1"));
  });
  withOutput((directory) => {
    mkdirSync(join(directory, "nested"));
    mkdirSync(join(directory, "nsis-web", "nested"), { recursive: true });
    mkdirSync(join(directory, "duplicate"));
    const installer = "installer.exe";
    writeFileSync(join(directory, "nested", installer), "exe");
    writeFileSync(join(directory, "nested", `${installer}.blockmap`), "blockmap");
    writeFileSync(join(directory, "duplicate", installer), "duplicate");
    const webInstaller = "web.exe";
    const packageName = "package-x64.nsis.7z";
    writeFileSync(join(directory, "nsis-web", "nested", webInstaller), "web");
    writeFileSync(join(directory, "nsis-web", "nested", packageName), "package");
    writeFileSync(join(directory, "foo-mac.yml"), windowsMetadata("1.0.0-foo-mac.1", installer));
    writeFileSync(
      join(directory, "nsis-web", "foo-mac.yml"),
      webMetadata("1.0.0-foo-mac.1", webInstaller, packageName, false)
    );
    assert.throws(() => validatePackagedOutput(directory, "windows", "foo-mac", "1.0.0-foo-mac.1"));
  });
});

void test("NSIS Webのnsis.zipとmetadata version不一致を拒否する", () => {
  withOutput((directory) => {
    mkdirSync(join(directory, "nested"));
    mkdirSync(join(directory, "nsis-web"));
    const installer = "installer.exe";
    const webInstaller = "web.exe";
    const packageName = "package-x64.nsis.zip";
    writeFileSync(join(directory, "nested", installer), "exe");
    writeFileSync(join(directory, "nested", `${installer}.blockmap`), "blockmap");
    writeFileSync(join(directory, "nsis-web", webInstaller), "web");
    writeFileSync(join(directory, "nsis-web", packageName), "package");
    writeFileSync(join(directory, "foo-mac.yml"), windowsMetadata("1.0.0-foo-mac.1", installer));
    writeFileSync(
      join(directory, "nsis-web", "foo-mac.yml"),
      webMetadata("1.0.0-foo-mac.1", webInstaller, packageName, false)
    );
    assert.throws(() => validatePackagedOutput(directory, "windows", "foo-mac", "1.0.0-foo-mac.1"));
  });
  withOutput((directory) => {
    mkdirSync(join(directory, "nested"));
    writeFileSync(join(directory, "latest-mac.yml"), macMetadata("2.0.0"));
    assert.throws(() => validatePackagedOutput(directory, "macos", "latest", "1.0.0"));
  });
});
