import { createHash } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync
} from "node:fs";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { canonicalDigest, canonicalJson } from "../src/canonical-json.js";
import { loadConfiguration, writeJsonFile } from "../src/config.js";
import { createPackageProject } from "../src/package-project.js";
import { createPublishPlan } from "../src/publish-plan.js";
import { assertReleaseSetComplete, createReleaseManifest } from "../src/release-manifest.js";
import { validateReleaseTag } from "../src/release-policy.js";
import {
  type ApplicationConfig,
  parseApplicationsConfig,
  parseCentralPath,
  parseGitTag
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
    identity: { appId: "com.example.demo", productName: "Demo", artifactName: "demo" },
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
    JSON.stringify({
      macos: {
        configured: true,
        certificatePath: "certificates/macos.cer",
        fingerprint: "0".repeat(64),
        displayName: "Demo Publisher"
      },
      windows: {
        configured: true,
        certificatePath: "certificates/windows.pfx",
        fingerprint: "1".repeat(64),
        displayName: "Demo Publisher",
        timestampUrl: "https://timestamp.example.test"
      }
    })
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

function writeSourcePackage(
  rootDirectory: string,
  dependencies: Record<string, string>,
  devDependencies: Record<string, string>
): void {
  writeFileSync(
    join(rootDirectory, "package.json"),
    JSON.stringify({
      name: "demo",
      version: "1.2.3",
      packageManager: "pnpm@10.30.2",
      scripts: { "build:macos": "build", "build:windows": "build" },
      dependencies,
      devDependencies
    })
  );
}

function writeSourcePackageWithScripts(
  rootDirectory: string,
  macosScript: string,
  windowsScript: string
): void {
  writeFileSync(
    join(rootDirectory, "package.json"),
    JSON.stringify({
      name: "demo",
      version: "1.2.3",
      packageManager: "pnpm@10.30.2",
      scripts: { "build:macos": macosScript, "build:windows": windowsScript },
      dependencies: { "electron-updater": "6.8.9" },
      devDependencies: { "electron-builder": "26.16.1" }
    })
  );
}

function sha512(value: string): string {
  return createHash("sha512").update(value).digest("base64");
}

function writeWindowsMetadata(
  assetsDirectory: string,
  version: string,
  installerName: string,
  installerContents: string,
  metadataName: string
): void {
  writeFileSync(
    join(assetsDirectory, metadataName),
    [
      `version: ${version}`,
      "files:",
      `  - url: ${installerName}`,
      `    sha512: ${sha512(installerContents)}`,
      `    size: ${installerContents.length}`,
      `path: ${installerName}`,
      `sha512: ${sha512(installerContents)}`,
      ""
    ].join("\n")
  );
}

function writeSourceVersion(rootDirectory: string, version: string): void {
  writeFileSync(
    join(rootDirectory, "package.json"),
    JSON.stringify({
      name: "demo",
      version,
      packageManager: "pnpm@10.30.2",
      scripts: { "build:macos": "build", "build:windows": "build" },
      dependencies: { "electron-updater": "6.8.9" },
      devDependencies: { "electron-builder": "26.16.1" }
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

  it("appId componentはASCII letterで始める", () => {
    const application = validApplication();
    application.identity = { ...application.identity, appId: "1com.example.demo" };
    expect(() => parseApplicationsConfig({ applications: { "demo-app": application } })).toThrow();
  });

  it("artifactNameとproductNameの表示値を厳格に検証する", () => {
    const productNameWithSeparator = validApplication();
    productNameWithSeparator.identity = {
      ...productNameWithSeparator.identity,
      productName: " Demo"
    };
    expect(() =>
      parseApplicationsConfig({ applications: { "demo-app": productNameWithSeparator } })
    ).toThrow();
    const artifactNameWithSeparator = validApplication();
    artifactNameWithSeparator.identity = {
      ...artifactNameWithSeparator.identity,
      artifactName: "demo/name"
    };
    expect(() =>
      parseApplicationsConfig({ applications: { "demo-app": artifactNameWithSeparator } })
    ).toThrow();
    const artifactNameWithDot = validApplication();
    artifactNameWithDot.identity = {
      ...artifactNameWithDot.identity,
      artifactName: "demo."
    };
    expect(() =>
      parseApplicationsConfig({ applications: { "demo-app": artifactNameWithDot } })
    ).toThrow();
  });

  it("signing未設定とpublisherName不一致をprepareで拒否する", () => {
    const root = temporaryDirectory();
    const application = validApplication();
    writeConfiguration(root, application);
    writeFileSync(
      join(root, "config/signing.json"),
      JSON.stringify({ macos: { configured: false }, windows: { configured: false } })
    );
    expect(() => prepareContract(root, "demo-app", "v1.2.3", false)).toThrow(/signing/);
    writeConfiguration(root, application);
    writeFileSync(
      join(root, "config/signing.json"),
      JSON.stringify({
        macos: {
          configured: true,
          certificatePath: "certificates/macos.cer",
          fingerprint: "0".repeat(64),
          displayName: "Demo Publisher"
        },
        windows: {
          configured: true,
          certificatePath: "certificates/windows.pfx",
          fingerprint: "1".repeat(64),
          displayName: "Other Publisher",
          timestampUrl: "https://timestamp.example.test"
        }
      })
    );
    expect(() => prepareContract(root, "demo-app", "v1.2.3", false)).toThrow(/publisherName/);
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

  it("Git refとして不正なtagを拒否する", () => {
    for (const tag of ["", "v1..2", "v1@{bad}", "v1.", "v1.lock", "v1//2", "v1\\2"]) {
      expect(() => parseGitTag(tag)).toThrow();
    }
  });
});

describe("source validation", () => {
  it("dependency version mismatchを拒否する", () => {
    const root = temporaryDirectory();
    writeConfiguration(root, validApplication());
    writeSource(root, "26.16.0");
    expect(() =>
      validateSource(root, prepareContract(root, "demo-app", "v1.2.3", false), root)
    ).toThrow();
  });

  it("electron依存の重複と分類違いを拒否する", () => {
    const root = temporaryDirectory();
    writeConfiguration(root, validApplication());
    writeSource(root, undefined);
    const contract = prepareContract(root, "demo-app", "v1.2.3", false);
    writeSourcePackage(
      root,
      { "electron-builder": "26.16.1", "electron-updater": "6.8.9" },
      { "electron-builder": "26.16.1" }
    );
    expect(() => validateSource(root, contract, root)).toThrow();
    writeSourcePackage(
      root,
      { "electron-builder": "26.16.0", "electron-updater": "6.8.9" },
      { "electron-builder": "26.16.1" }
    );
    expect(() => validateSource(root, contract, root)).toThrow();
    writeSourcePackage(root, { "electron-builder": "26.16.1" }, { "electron-updater": "6.8.9" });
    expect(() => validateSource(root, contract, root)).toThrow();
  });

  it("allowlist build scriptの空文字と空白だけの値を拒否する", () => {
    const root = temporaryDirectory();
    writeConfiguration(root, validApplication());
    writeSource(root, undefined);
    const contract = prepareContract(root, "demo-app", "v1.2.3", false);
    writeSourcePackageWithScripts(root, "", "build");
    expect(() => validateSource(root, contract, root)).toThrow(/build script/);
    writeSourcePackageWithScripts(root, "build", " \t ");
    expect(() => validateSource(root, contract, root)).toThrow(/build script/);
  });

  it("contractの改ざんを後続commandで拒否する", () => {
    const root = temporaryDirectory();
    writeConfiguration(root, validApplication());
    writeSource(root, undefined);
    const contract = prepareContract(root, "demo-app", "v1.2.3", false);
    const tampered = { ...contract, configDigest: `sha256:${"f".repeat(64)}` };
    expect(() => validateSource(root, tampered, root)).toThrow(/中央設定/);
  });

  it("root package.jsonはnameとversionがなくてもworkingDirectoryを検証する", () => {
    const root = temporaryDirectory();
    const application = validApplication();
    application.workingDirectory = "app";
    writeConfiguration(root, application);
    mkdirSync(join(root, "app"));
    writeFileSync(join(root, "package.json"), JSON.stringify({ packageManager: "pnpm@10.30.2" }));
    writeFileSync(join(root, "pnpm-lock.yaml"), "lockfileVersion: '9.0'\n");
    writeFileSync(
      join(root, "app/package.json"),
      JSON.stringify({
        name: "demo",
        version: "1.2.3",
        scripts: { "build:macos": "build", "build:windows": "build" },
        dependencies: { "electron-updater": "6.8.9" },
        devDependencies: { "electron-builder": "26.16.1" }
      })
    );
    expect(
      validateSource(root, prepareContract(root, "demo-app", "v1.2.3", false), root).version
    ).toBe("1.2.3");
  });

  it("空またはsymlinkのlockfileを拒否する", () => {
    const root = temporaryDirectory();
    writeConfiguration(root, validApplication());
    writeSource(root, undefined);
    const contract = prepareContract(root, "demo-app", "v1.2.3", false);
    writeFileSync(join(root, "pnpm-lock.yaml"), "");
    expect(() => validateSource(root, contract, root)).toThrow();
    writeFileSync(join(root, "pnpm-lock.yaml"), "lockfileVersion: '9.0'\n");
    const lockTarget = join(root, "lock-target");
    writeFileSync(lockTarget, "lockfileVersion: '9.0'\n");
    rmSync(join(root, "pnpm-lock.yaml"));
    symlinkSync(lockTarget, join(root, "pnpm-lock.yaml"));
    expect(() => validateSource(root, contract, root)).toThrow();
  });

  it("source rootとworkingDirectoryのsymlinkを拒否する", () => {
    const central = temporaryDirectory();
    const source = temporaryDirectory();
    writeConfiguration(central, validApplication());
    writeSource(source, undefined);
    const contract = prepareContract(central, "demo-app", "v1.2.3", false);
    const sourceLink = join(central, "source-link");
    symlinkSync(source, sourceLink);
    expect(() => validateSource(central, contract, sourceLink)).toThrow();

    const linkedSource = temporaryDirectory();
    const externalWorkingDirectory = temporaryDirectory();
    const application = validApplication();
    application.workingDirectory = "linked-app";
    writeConfiguration(central, application);
    writeConfiguration(linkedSource, application);
    writeFileSync(
      join(linkedSource, "package.json"),
      JSON.stringify({ packageManager: "pnpm@10.30.2" })
    );
    writeFileSync(join(linkedSource, "pnpm-lock.yaml"), "lockfileVersion: '9.0'\n");
    writeFileSync(
      join(externalWorkingDirectory, "package.json"),
      JSON.stringify({
        name: "demo",
        version: "1.2.3",
        scripts: { "build:macos": "build", "build:windows": "build" },
        dependencies: { "electron-updater": "6.8.9" },
        devDependencies: { "electron-builder": "26.16.1" }
      })
    );
    symlinkSync(externalWorkingDirectory, join(linkedSource, "linked-app"));
    const linkedContract = prepareContract(central, "demo-app", "v1.2.3", false);
    expect(() => validateSource(central, linkedContract, linkedSource)).toThrow();
  });
});

describe("manifest and publish plan", () => {
  it("既存またはsymlinkのJSON outputを拒否する", () => {
    const root = temporaryDirectory();
    const output = join(root, "output.json");
    writeFileSync(output, "{}");
    expect(() => writeJsonFile(output, { ok: true })).toThrow();
    const target = join(root, "target.json");
    writeFileSync(target, "{}");
    const link = join(root, "link.json");
    symlinkSync(target, link);
    expect(() => writeJsonFile(link, { ok: true })).toThrow();

    const realParent = join(root, "real-parent");
    mkdirSync(realParent);
    const parentLink = join(root, "parent-link");
    symlinkSync(realParent, parentLink);
    expect(() => writeJsonFile(join(parentLink, "nested.json"), { ok: true })).toThrow();
  });

  it("windows targetを通常NSISとWebに分離する", () => {
    const root = temporaryDirectory();
    writeConfiguration(root, validApplication());
    writeSource(root, undefined);
    const contract = validateSource(root, prepareContract(root, "demo-app", "v1.2.3", false), root);
    const nsisDirectory = join(root, "nsis");
    const webDirectory = join(root, "web");
    createPackageProject(root, contract, "windows-nsis", nsisDirectory);
    createPackageProject(root, contract, "windows-nsis-web", webDirectory);
    const nsisConfig = readFileSync(join(nsisDirectory, "electron-builder.yml"), "utf8");
    const webConfig = readFileSync(join(webDirectory, "electron-builder.yml"), "utf8");
    expect(nsisConfig).toContain("target: nsis");
    expect(nsisConfig).not.toContain("target: nsis-web");
    expect(webConfig).toContain("target: nsis-web");
    expect(webConfig).not.toContain("target: nsis\n");
    expect(nsisConfig).toContain("artifactName: demo-Setup-");
    expect(nsisConfig).not.toContain("${productName} Setup");
    expect(webConfig).toContain("publishAutoUpdate: false");
    expect(nsisConfig).not.toContain("publishAutoUpdate");
    const realParent = join(root, "project-parent");
    mkdirSync(realParent);
    const parentLink = join(root, "project-parent-link");
    symlinkSync(realParent, parentLink);
    expect(() =>
      createPackageProject(root, contract, "windows-nsis", join(parentLink, "project"))
    ).toThrow();
  });

  it("electron-builderのWindows Web package名を厳格にrole化する", () => {
    const root = temporaryDirectory();
    writeConfiguration(root, validApplication());
    writeSource(root, undefined);
    const contract = validateSource(root, prepareContract(root, "demo-app", "v1.2.3", false), root);
    const assets = join(root, "assets");
    mkdirSync(assets);
    writeFileSync(join(assets, "demo-1.2.3-x64.nsis.7z"), "package");
    const manifest = createReleaseManifest(root, contract, assets);
    expect(manifest.assets[0]?.role).toBe("windows-web-package");
    writeFileSync(join(assets, "demo-1.2.3.nsis.7z"), "package");
    expect(() => createReleaseManifest(root, contract, assets)).toThrow();
  });

  it("metadataのsizeとsha512とURLを実assetと照合する", () => {
    const root = temporaryDirectory();
    writeConfiguration(root, validApplication());
    writeSource(root, undefined);
    const contract = validateSource(root, prepareContract(root, "demo-app", "v1.2.3", false), root);
    const assets = join(root, "assets");
    mkdirSync(assets);
    const installerName = "demo-Setup-1.2.3.exe";
    const installerContents = "installer";
    writeFileSync(join(assets, installerName), installerContents);
    writeWindowsMetadata(assets, "1.2.3", installerName, installerContents, "latest.yml");
    const manifest = createReleaseManifest(root, contract, assets);
    expect(manifest.metadata?.[0]?.path).toBe(installerName);
    writeWindowsMetadata(assets, "1.2.3", installerName, "other", "latest.yml");
    expect(() => createReleaseManifest(root, contract, assets)).toThrow();
    writeFileSync(
      join(assets, "latest.yml"),
      [
        "version: 1.2.3",
        "files:",
        `  - url: ${installerName}`,
        `    sha512: ${sha512(installerContents)}`,
        `    size: ${installerContents.length}`,
        "path: missing.exe",
        `sha512: ${sha512(installerContents)}`,
        ""
      ].join("\n")
    );
    expect(() => createReleaseManifest(root, contract, assets)).toThrow();
  });

  it("publish plan生成時に保存manifestと実assetとmetadataを再照合する", () => {
    const root = temporaryDirectory();
    writeConfiguration(root, validApplication());
    writeSource(root, undefined);
    const contract = validateSource(root, prepareContract(root, "demo-app", "v1.2.3", false), root);
    const assets = join(root, "assets");
    mkdirSync(assets);
    const installerName = "demo-Setup-1.2.3.exe";
    writeFileSync(join(assets, installerName), "installer");
    writeWindowsMetadata(assets, "1.2.3", installerName, "installer", "latest.yml");
    const manifest = createReleaseManifest(root, contract, assets);
    const installer = manifest.assets.find((asset) => asset.role === "windows-nsis");
    if (installer === undefined) {
      throw new Error("test installerがありません");
    }
    const remoteAssets = [{ name: installerName, digest: installer.digest }];
    expect(() => createPublishPlan(root, contract, manifest, remoteAssets, assets)).not.toThrow();
    const fakeManifest = {
      ...manifest,
      assets: manifest.assets.map((asset) =>
        asset.role === "windows-nsis" ? { ...asset, digest: `sha256:${"f".repeat(64)}` } : asset
      )
    };
    expect(() => createPublishPlan(root, contract, fakeManifest, remoteAssets, assets)).toThrow();

    writeFileSync(join(assets, installerName), "replaced installer");
    expect(() => createPublishPlan(root, contract, manifest, remoteAssets, assets)).toThrow();
    writeFileSync(join(assets, installerName), "installer");
    writeFileSync(
      join(assets, "latest.yml"),
      [
        "version: 1.2.3",
        "releaseDate: 2026-09-17T00:00:00.000Z",
        "files:",
        `  - url: ${installerName}`,
        `    sha512: ${sha512("installer")}`,
        "    size: 9",
        `path: ${installerName}`,
        `sha512: ${sha512("installer")}`,
        ""
      ].join("\n")
    );
    expect(() => createPublishPlan(root, contract, manifest, remoteAssets, assets)).toThrow();
  });

  it("Web outputのmetadataをrelease assetとして受理しない", () => {
    const root = temporaryDirectory();
    writeConfiguration(root, validApplication());
    writeSource(root, undefined);
    const contract = validateSource(root, prepareContract(root, "demo-app", "v1.2.3", false), root);
    const assets = join(root, "assets");
    mkdirSync(assets);
    writeFileSync(join(assets, "latest-web.yml"), "version: 1.2.3\n");
    expect(() => createReleaseManifest(root, contract, assets)).toThrow();
  });

  it("betaとdevのmetadata filenameをchannelから導出する", () => {
    const cases = [
      {
        version: "1.2.3-beta.1",
        tag: "v1.2.3-beta.1",
        channel: "beta",
        strategy: { type: "versioned", prefix: "v" },
        metadataName: "beta.yml"
      },
      {
        version: "1.2.3",
        tag: "dev",
        channel: "dev",
        strategy: { type: "rolling", tag: "dev" },
        metadataName: "dev.yml"
      }
    ] satisfies Array<{
      version: string;
      tag: string;
      channel: "beta" | "dev";
      strategy: { type: "versioned"; prefix: string } | { type: "rolling"; tag: string };
      metadataName: string;
    }>;
    for (const testCase of cases) {
      const root = temporaryDirectory();
      const application = validApplication();
      application.release = {
        tagStrategy: testCase.strategy,
        channel: testCase.channel,
        assetPolicy: testCase.channel === "dev" ? "replaceable" : "append-only"
      };
      writeConfiguration(root, application);
      writeSource(root, undefined);
      writeSourceVersion(root, testCase.version);
      const contract = validateSource(
        root,
        prepareContract(root, "demo-app", testCase.tag, false),
        root
      );
      const assets = join(root, "assets");
      mkdirSync(assets);
      const installerName = `demo-Setup-${testCase.version}.exe`;
      writeFileSync(join(assets, installerName), "installer");
      writeWindowsMetadata(
        assets,
        testCase.version,
        installerName,
        "installer",
        testCase.metadataName
      );
      const manifest = createReleaseManifest(root, contract, assets);
      expect(manifest.metadata?.[0]?.name).toBe(testCase.metadataName);
    }
  });

  it("symlink assetを拒否する", () => {
    const root = temporaryDirectory();
    writeConfiguration(root, validApplication());
    writeSource(root, undefined);
    const contract = validateSource(root, prepareContract(root, "demo-app", "v1.2.3", false), root);
    const assets = join(root, "assets");
    mkdirSync(assets);
    const source = join(root, "payload");
    writeFileSync(source, "payload");
    symlinkSync(source, join(assets, "demo-1.2.3-x64.zip"));
    expect(() => createReleaseManifest(root, contract, assets)).toThrow();
  });

  it("同名同digestをskipし無関係assetを触らない", () => {
    const root = temporaryDirectory();
    writeConfiguration(root, validApplication());
    writeSource(root, undefined);
    const contract = validateSource(root, prepareContract(root, "demo-app", "v1.2.3", false), root);
    const assets = join(root, "assets");
    mkdirSync(assets);
    writeFileSync(join(assets, "demo-1.2.3-x64.zip"), "payload");
    const manifest = createReleaseManifest(root, contract, assets);
    const asset = manifest.assets[0];
    if (asset === undefined) {
      throw new Error("test assetがありません");
    }
    const plan = createPublishPlan(
      root,
      contract,
      manifest,
      [
        { name: "demo-1.2.3-x64.zip", digest: asset.digest },
        { name: "unrelated.zip", digest: `sha256:${"0".repeat(64)}` }
      ],
      assets
    );
    expect(plan.operations[0]?.action).toBe("skip");
    expect(plan.operations).toHaveLength(1);
    expect(() =>
      createPublishPlan(
        root,
        contract,
        manifest,
        [
          { name: "demo-1.2.3-x64.zip", digest: `sha256:${"0".repeat(64)}` },
          { name: "demo-1.2.3-x64.zip", digest: `sha256:${"1".repeat(64)}` }
        ],
        assets
      )
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
