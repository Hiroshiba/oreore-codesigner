import { strict as assert } from "node:assert";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { z } from "zod";
import { validateSourceContract } from "../src/source-contract.js";

const repositoryRoot = join(import.meta.dirname, "..");
const outputSchema = z.object({
  version: z.string(),
  channel: z.string(),
  builder_config: z.string()
});

function createSource(
  version: string,
  config: string,
  packageJson: Record<string, unknown>,
  configName: "electron-builder.yml" | "electron-builder.yaml"
): string {
  const sourceDirectory = mkdtempSync(join(tmpdir(), "source-contract-test-"));
  writeFileSync(join(sourceDirectory, "package.json"), JSON.stringify(packageJson));
  writeFileSync(join(sourceDirectory, configName), config);
  assert.equal(packageJson.version, version);
  return sourceDirectory;
}

function validPackage(version: string): Record<string, unknown> {
  return {
    version,
    packageManager: "pnpm@10.30.2",
    scripts: { build: "build" },
    devDependencies: { "electron-builder": "26.16.1" }
  };
}

function validConfig(): string {
  return [
    "productName: Fixture",
    "extraMetadata:",
    "  version: 9.9.9",
    "mac:",
    "  target:",
    "    - zip",
    "win:",
    "  target:",
    "    - nsis",
    ""
  ].join("\n");
}

function withSource(
  version: string,
  config: string,
  packageJson: Record<string, unknown>,
  configName: "electron-builder.yml" | "electron-builder.yaml",
  run: (sourceDirectory: string) => void
): void {
  const sourceDirectory = createSource(version, config, packageJson, configName);
  try {
    run(sourceDirectory);
  } finally {
    rmSync(sourceDirectory, { recursive: true, force: true });
  }
}

void test("stable versionはlatest channelとしてJSON出力される", () => {
  withSource("1.2.3", validConfig(), validPackage("1.2.3"), "electron-builder.yml", (source) => {
    const result = validateSourceContract(source);
    assert.deepEqual(result, {
      version: "1.2.3",
      channel: "latest",
      builderConfig: "electron-builder.yml"
    });
    const output = execFileSync(
      process.execPath,
      [
        "--import",
        "tsx",
        join(repositoryRoot, "src/cli.ts"),
        "validate-source",
        "--source-directory",
        source
      ],
      {
        cwd: repositoryRoot,
        encoding: "utf8"
      }
    );
    assert.deepEqual(outputSchema.parse(JSON.parse(output)), {
      version: "1.2.3",
      channel: "latest",
      builder_config: "electron-builder.yml"
    });
  });
});

void test("betaと複合prereleaseの最初のidentifierをchannelにする", () => {
  withSource(
    "1.2.3-beta.1",
    validConfig(),
    validPackage("1.2.3-beta.1"),
    "electron-builder.yaml",
    (source) => {
      assert.equal(validateSourceContract(source).channel, "beta");
    }
  );
  withSource(
    "1.2.3-foo-mac.1",
    validConfig(),
    validPackage("1.2.3-foo-mac.1"),
    "electron-builder.yml",
    (source) => {
      assert.equal(validateSourceContract(source).channel, "foo-mac");
    }
  );
});

void test("builder設定のpublishとextendsをすべて拒否する", () => {
  const fields = [
    "publish: null",
    "mac:\n  publish: null",
    "win:\n  publish: null",
    "nsis:\n  publish: null",
    "nsisWeb:\n  publish: null",
    "target:\n  - publish: null",
    "mac:\n  target:\n    - publish: null",
    "extends: base.yml"
  ];
  for (const field of fields) {
    withSource("1.0.0", field, validPackage("1.0.0"), "electron-builder.yml", (source) => {
      assert.throws(() => validateSourceContract(source));
    });
  }
});

void test("extraMetadataのpublishはsource契約の対象外として許可する", () => {
  const config = ["extraMetadata:", "  publish:", "    provider: github", ""].join("\n");
  withSource("1.0.0", config, validPackage("1.0.0"), "electron-builder.yml", (source) => {
    assert.doesNotThrow(() => validateSourceContract(source));
  });
});

void test("package.jsonのbuildフィールドを拒否する", () => {
  const packageJson = validPackage("1.0.0");
  packageJson.build = { appId: "invalid" };
  withSource("1.0.0", validConfig(), packageJson, "electron-builder.yml", (source) => {
    assert.throws(() => validateSourceContract(source));
  });
});

void test("builder設定を二つ置くことを拒否する", () => {
  const source = createSource(
    "1.0.0",
    validConfig(),
    validPackage("1.0.0"),
    "electron-builder.yml"
  );
  try {
    writeFileSync(join(source, "electron-builder.yaml"), validConfig());
    assert.throws(() => validateSourceContract(source));
  } finally {
    rmSync(source, { recursive: true, force: true });
  }
});

void test("electron-builderとpackageManagerの固定値を検証する", () => {
  const packageJson = validPackage("1.0.0");
  packageJson.packageManager = "pnpm@10.30";
  withSource("1.0.0", validConfig(), packageJson, "electron-builder.yml", (source) => {
    assert.throws(() => validateSourceContract(source));
  });
  const invalidBuilder = validPackage("1.0.0");
  invalidBuilder.devDependencies = { "electron-builder": "26.15.0" };
  withSource("1.0.0", validConfig(), invalidBuilder, "electron-builder.yml", (source) => {
    assert.throws(() => validateSourceContract(source));
  });
});

void test("build scriptを必須にする", () => {
  const packageJson = validPackage("1.0.0");
  packageJson.scripts = {};
  withSource("1.0.0", validConfig(), packageJson, "electron-builder.yml", (source) => {
    assert.throws(() => validateSourceContract(source));
  });
});
