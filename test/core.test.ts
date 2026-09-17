import { createHash } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { canonicalDigest, canonicalJson } from "../src/canonical-json.js";
import { loadConfiguration } from "../src/config.js";
import { createPublishPlan } from "../src/publish-plan.js";
import { assertReleaseSetComplete, createReleaseManifest } from "../src/release-manifest.js";
import { validateReleaseTag } from "../src/release-policy.js";
import {
  type ApplicationConfig,
  parseApplicationsConfig,
  parseCentralPath
} from "../src/schema.js";
import { prepareContract, validateSource } from "../src/source-validation.js";
import { runCli } from "../src/cli.js";

const temporaryDirectories: string[] = [];

function temporaryDirectory(): string {
  const directory = mkdtempSync(join("/tmp", "personal-signing-test-"));
  temporaryDirectories.push(directory);
  return directory;
}

function validApplication(): ApplicationConfig {
  return {
    repository: "owner/demo",
    workingDirectory: ".",
    packageName: "demo",
    pnpmVersion: "10.30.2",
    buildScripts: { macos: "build:macos", windows: "build:windows" },
    identity: { appId: "com.example.demo", productName: "Demo" },
    macos: {
      runner: "macos-14",
      architecture: "x64",
      entitlements: "config/entitlements/demo.plist",
      entitlementsInherit: "config/entitlements/demo-inherit.plist"
    },
    windows: {
      runner: "windows-2022",
      architecture: "x64",
      executableName: "demo",
      guid: "01234567-89ab-4cde-8fab-0123456789ab",
      publisherName: "Demo Publisher"
    },
    release: {
      tagStrategy: { type: "versioned", prefix: "v" },
      channel: "latest",
      assetPolicy: "append-only"
    }
  };
}

function writeConfiguration(rootDirectory: string, application: Record<string, unknown>): void {
  mkdirSync(join(rootDirectory, "config"), { recursive: true });
  writeFileSync(
    join(rootDirectory, "config/apps.json"),
    JSON.stringify({ applications: { "demo-app": application } })
  );
  writeFileSync(
    join(rootDirectory, "config/signing.json"),
    JSON.stringify({ macos: { configured: false }, windows: { configured: false } })
  );
}

function writeSource(rootDirectory: string, dependencyVersion: string | undefined): void {
  const version = dependencyVersion === undefined ? "26.16.1" : dependencyVersion;
  writeFileSync(
    join(rootDirectory, "package.json"),
    JSON.stringify({ name: "workspace", packageManager: "pnpm@10.30.2" })
  );
  writeFileSync(join(rootDirectory, "pnpm-lock.yaml"), "lockfileVersion: '9.0'\n");
  writeFileSync(
    join(rootDirectory, "package.json"),
    JSON.stringify({
      name: "demo",
      version: "1.2.3",
      packageManager: "pnpm@10.30.2",
      scripts: { "build:macos": "build", "build:windows": "build" },
      dependencies: { "electron-updater": "6.8.9" },
      devDependencies: { "electron-builder": version }
    })
  );
}

afterEach(() => {
  while (temporaryDirectories.length > 0) {
    const directory = temporaryDirectories.pop();
    if (directory !== undefined && existsSync(directory)) {
      rmSync(directory, { recursive: true, force: true });
    }
  }
});

describe("canonical JSON", () => {
  it("object key orderに依存しないdigestを作る", () => {
    expect(canonicalJson({ b: 2, a: 1 })).toBe(canonicalJson({ a: 1, b: 2 }));
    expect(canonicalDigest({ b: 2, a: 1 })).toBe(canonicalDigest({ a: 1, b: 2 }));
  });
});

describe("configuration schema", () => {
  it("unknown keyとpath traversalを拒否する", () => {
    expect(() =>
      parseApplicationsConfig({
        applications: { "demo-app": { ...validApplication(), unknown: true } }
      })
    ).toThrow();
    expect(() => parseCentralPath("../entitlements.plist")).toThrow();
    expect(() => parseCentralPath("config/../entitlements.plist")).toThrow();
    expect(parseCentralPath("config/entitlements.plist")).toBe("config/entitlements.plist");
  });

  it("identityの重複を拒否する", () => {
    const root = temporaryDirectory();
    const first = validApplication();
    const second = validApplication();
    second.repository = "owner/other";
    second.windows = { ...second.windows, guid: "fedcba98-7654-4def-8abc-fedcba987654" };
    mkdirSync(join(root, "config"), { recursive: true });
    writeFileSync(
      join(root, "config/apps.json"),
      JSON.stringify({ applications: { "demo-app": first, "other-app": second } })
    );
    writeFileSync(
      join(root, "config/signing.json"),
      JSON.stringify({ macos: { configured: false }, windows: { configured: false } })
    );
    expect(() => loadConfiguration(root)).toThrow();
  });
});

describe("release policy", () => {
  it("boolean入力はtrueまたはfalseだけを受け付ける", () => {
    expect(() =>
      runCli([
        "prepare",
        "--app-id",
        "demo-app",
        "--tag",
        "v1.2.3",
        "--replace-existing-assets",
        "yes",
        "--output",
        "/tmp/contract.json"
      ])
    ).toThrow();
  });

  it("rollingとlatestの混同を拒否する", () => {
    const application = validApplication();
    application.release = {
      tagStrategy: { type: "rolling", tag: "dev" },
      channel: "dev",
      assetPolicy: "replaceable"
    };
    expect(() => validateReleaseTag(application.release, "v1.2.3", "1.2.3")).toThrow();
  });
});

describe("source validation", () => {
  it("dependency version mismatchを拒否する", () => {
    const root = temporaryDirectory();
    writeConfiguration(root, validApplication());
    writeSource(root, "26.16.0");
    expect(() =>
      validateSource(prepareContract(root, "demo-app", "v1.2.3", false), root)
    ).toThrow();
  });
});

describe("manifest and publish plan", () => {
  it("symlink assetを拒否する", () => {
    const root = temporaryDirectory();
    writeConfiguration(root, validApplication());
    writeSource(root, undefined);
    const contract = validateSource(prepareContract(root, "demo-app", "v1.2.3", false), root);
    const assets = join(root, "assets");
    mkdirSync(assets);
    const source = join(root, "payload");
    writeFileSync(source, "payload");
    symlinkSync(source, join(assets, "Demo-1.2.3-x64.zip"));
    expect(() => createReleaseManifest(contract, assets)).toThrow();
  });

  it("同名同digestをskipし無関係assetを触らない", () => {
    const root = temporaryDirectory();
    writeConfiguration(root, validApplication());
    writeSource(root, undefined);
    const contract = validateSource(prepareContract(root, "demo-app", "v1.2.3", false), root);
    const manifest = {
      schemaVersion: 1,
      appId: "demo-app",
      repository: "owner/demo",
      tag: "v1.2.3",
      version: "1.2.3",
      assets: [
        {
          name: "Demo-1.2.3-x64.zip",
          size: 7,
          digest: `sha256:${createHash("sha256").update("payload").digest("hex")}`,
          role: "macos-zip"
        }
      ]
    };
    const asset = manifest.assets[0];
    if (asset === undefined) {
      throw new Error("test assetがありません");
    }
    const plan = createPublishPlan(contract, manifest, [
      { name: "Demo-1.2.3-x64.zip", digest: asset.digest },
      { name: "unrelated.zip", digest: `sha256:${"0".repeat(64)}` }
    ]);
    expect(plan.operations[0]?.action).toBe("skip");
    expect(plan.operations).toHaveLength(1);
    expect(() =>
      createPublishPlan(contract, manifest, [
        { name: "Demo-1.2.3-x64.zip", digest: `sha256:${"0".repeat(64)}` },
        { name: "Demo-1.2.3-x64.zip", digest: `sha256:${"1".repeat(64)}` }
      ])
    ).toThrow();
  });

  it("release set completionは必須role不足を拒否する", () => {
    expect(() =>
      assertReleaseSetComplete({
        schemaVersion: 1,
        appId: "demo-app",
        repository: "owner/demo",
        tag: "v1.2.3",
        version: "1.2.3",
        assets: []
      })
    ).toThrow();
  });
});
