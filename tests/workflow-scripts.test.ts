import { strict as assert } from "node:assert";
import { execFileSync } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const repositoryRoot = dirname(dirname(fileURLToPath(import.meta.url)));

type WorkflowMode = "normal" | "missing" | "duplicate" | "cleanup";
type WorkflowChannel = "stable" | "beta" | "custom";
type WorkflowContext = {
  argumentsPath: string;
  builderArgumentsPath: string;
  invoke: () => void;
  outputDirectory: string;
};

function writeExecutable(path: string, contents: string): void {
  writeFileSync(path, contents);
  chmodSync(path, 0o755);
}

function withMacosWorkflow(
  mode: WorkflowMode,
  channel: WorkflowChannel,
  run: (context: WorkflowContext) => void
): void {
  const workDirectory = mkdtempSync(join(tmpdir(), "workflow-script-test-"));
  const sourceDirectory = join(workDirectory, "source");
  const binDirectory = join(workDirectory, "bin");
  const outputDirectory = join(workDirectory, "release");
  const argumentsPath = join(workDirectory, "arguments.txt");
  const builderArgumentsPath = join(workDirectory, "builder-arguments.txt");
  mkdirSync(sourceDirectory);
  mkdirSync(binDirectory);
  const version =
    channel === "stable" ? "1.0.0" : channel === "beta" ? "1.0.0-beta.1" : "1.0.0-preview.1";
  const metadataName =
    channel === "stable"
      ? "latest-mac.yml"
      : channel === "beta"
        ? "beta-mac.yml"
        : "preview-mac.yml";
  writeFileSync(
    join(sourceDirectory, "package.json"),
    JSON.stringify({
      packageManager: "pnpm@10.30.2",
      build: {
        publish: [{ provider: "github", url: "https://source.invalid/root" }],
        mac: { publish: [{ provider: "github", url: "https://source.invalid/mac" }] },
        zip: { publish: [{ provider: "github", url: "https://source.invalid/zip" }] },
        generateUpdatesFilesForAllChannels: true
      }
    })
  );
  writeExecutable(
    join(binDirectory, "corepack"),
    ["#!/usr/bin/env bash", "set -Eeuo pipefail", "exit 0", ""].join("\n")
  );
  writeExecutable(
    join(binDirectory, "pnpm"),
    [
      "#!/usr/bin/env bash",
      "set -Eeuo pipefail",
      'printf \'%s\\n\' "$@" >> "$WORKFLOW_TEST_ARGUMENTS"',
      'if [[ "${1:-}" != exec || "${2:-}" != electron-builder ]]; then exit 0; fi',
      "builder_output=''",
      'for argument in "$@"; do',
      '  if [[ "$argument" == --config.directories.output=* ]]; then builder_output=${argument#*=}; fi',
      "done",
      'if [[ -z "$builder_output" ]]; then exit 1; fi',
      'mkdir -p -- "$builder_output/nested"',
      'printf \'%s\\n\' "$@" > "$WORKFLOW_TEST_BUILDER_ARGUMENTS"',
      'if [[ "${WORKFLOW_TEST_EXPECT_CONFIG_MERGE:-}" == true ]]; then',
      "  if ! jq -e '.build.zip.publish[0].provider == \"github\"' package.json >/dev/null; then exit 1; fi",
      '  grep -F -- "--config.zip.publish.provider=generic" "$WORKFLOW_TEST_BUILDER_ARGUMENTS" >/dev/null',
      '  grep -F -- "--config.mac.publish.provider=generic" "$WORKFLOW_TEST_BUILDER_ARGUMENTS" >/dev/null',
      "fi",
      "printf '%s' zip > \"$builder_output/nested/app.zip\"",
      "printf '%s' blockmap > \"$builder_output/nested/app.zip.blockmap\"",
      'printf \'version: %s\\nfiles:\\n  - url: app.zip\\n    sha512: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==\\n    size: 3\\npath: app.zip\\nsha512: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==\\n\' "$WORKFLOW_TEST_VERSION" > "$builder_output/$WORKFLOW_TEST_METADATA_NAME"',
      "printf '%s' extra > \"$builder_output/builder-debug.yml\"",
      "printf '%s' extra-zip > \"$builder_output/extra.zip\"",
      "printf '%s' extra-blockmap > \"$builder_output/extra.zip.blockmap\"",
      'if [[ "$WORKFLOW_TEST_MODE" == missing ]]; then rm -- "$builder_output/nested/app.zip.blockmap"; fi',
      'if [[ "$WORKFLOW_TEST_MODE" == duplicate ]]; then',
      '  mkdir -p -- "$builder_output/duplicate"',
      "  printf '%s' duplicate-zip > \"$builder_output/duplicate/app.zip\"",
      "fi",
      ""
    ].join("\n")
  );
  writeExecutable(
    join(binDirectory, "rm"),
    [
      "#!/usr/bin/env bash",
      "set -Eeuo pipefail",
      'if [[ "$WORKFLOW_TEST_MODE" == cleanup && "$*" == *central-package-macos.* ]]; then exit 1; fi',
      'exec /usr/bin/rm "$@"',
      ""
    ].join("\n")
  );

  const env: NodeJS.ProcessEnv = {
    ...process.env,
    CSC_KEY_PASSWORD: "fixture-password",
    CSC_LINK: "fixture-certificate",
    PATH: `${binDirectory}:${process.env.PATH ?? ""}`,
    RUNNER_TEMP: workDirectory,
    WORKFLOW_TEST_ARGUMENTS: argumentsPath,
    WORKFLOW_TEST_BUILDER_ARGUMENTS: builderArgumentsPath,
    WORKFLOW_TEST_EXPECT_CONFIG_MERGE: "true",
    WORKFLOW_TEST_METADATA_NAME: metadataName,
    WORKFLOW_TEST_MODE: mode,
    WORKFLOW_TEST_VERSION: version
  };
  const invoke = (): void => {
    execFileSync(
      "bash",
      [
        join(repositoryRoot, "scripts/workflow/sign-macos.sh"),
        sourceDirectory,
        "owner/name",
        "v1.0.0-beta.1",
        outputDirectory
      ],
      { cwd: repositoryRoot, env, stdio: "pipe" }
    );
  };
  try {
    run({ argumentsPath, builderArgumentsPath, invoke, outputDirectory });
  } finally {
    rmSync(workDirectory, { recursive: true, force: true });
  }
}

void test("macOSのchannel metadataとbuilder引数を実際のscript境界で検証できる", () => {
  withMacosWorkflow(
    "normal",
    "beta",
    ({ argumentsPath, builderArgumentsPath, invoke, outputDirectory }) => {
      invoke();
      const builderArguments = readFileSync(builderArgumentsPath, "utf8").split("\n");
      assert.equal(builderArguments.includes("--config.forceCodeSigning=true"), true);
      assert.equal(builderArguments.includes("--config.mac.forceCodeSigning=true"), true);
      assert.equal(
        builderArguments.includes("--config.generateUpdatesFilesForAllChannels=false"),
        true
      );
      assert.equal(
        builderArguments.includes("--config.mac.generateUpdatesFilesForAllChannels=false"),
        true
      );
      assert.equal(builderArguments.includes("--config.publish.provider=generic"), true);
      assert.equal(
        builderArguments.includes(
          "--config.publish.url=https://github.com/owner/name/releases/download/v1.0.0-beta.1"
        ),
        true
      );
      assert.equal(builderArguments.includes("--config.mac.publish.provider=generic"), true);
      assert.equal(
        builderArguments.includes(
          "--config.mac.publish.url=https://github.com/owner/name/releases/download/v1.0.0-beta.1"
        ),
        true
      );
      assert.equal(builderArguments.includes("--config.zip.publish.provider=generic"), true);
      assert.equal(
        builderArguments.includes(
          "--config.zip.publish.url=https://github.com/owner/name/releases/download/v1.0.0-beta.1"
        ),
        true
      );
      assert.equal(existsSync(join(outputDirectory, "metadata/beta-mac.yml")), true);
      assert.equal(existsSync(join(outputDirectory, "payload/app.zip")), true);
      assert.equal(existsSync(join(outputDirectory, "payload/extra.zip")), false);
      assert.equal(existsSync(join(outputDirectory, "payload/builder-debug.yml")), false);
      assert.equal(readFileSync(argumentsPath, "utf8").includes("--publish"), true);
    }
  );
});

void test("macOSのstable metadataを選択できる", () => {
  withMacosWorkflow("normal", "stable", ({ invoke, outputDirectory }) => {
    invoke();
    assert.equal(existsSync(join(outputDirectory, "metadata/latest-mac.yml")), true);
  });
});

void test("macOSのcustom channel metadataを選択できる", () => {
  withMacosWorkflow("normal", "custom", ({ invoke, outputDirectory }) => {
    invoke();
    assert.equal(existsSync(join(outputDirectory, "metadata/preview-mac.yml")), true);
  });
});

void test("macOSの必須出力欠落を検出できる", () => {
  withMacosWorkflow("missing", "beta", ({ invoke }) => {
    assert.throws(invoke);
  });
});

void test("macOSの必須出力重複を検出できる", () => {
  withMacosWorkflow("duplicate", "beta", ({ invoke }) => {
    assert.throws(invoke);
  });
});

void test("macOSのcleanup失敗を処理失敗と併せて検出できる", () => {
  withMacosWorkflow("cleanup", "beta", ({ invoke }) => {
    assert.throws(invoke);
  });
});

void test("Windowsの独立したNSIS Web出力とbuilder上書きを保持する", () => {
  const script = readFileSync(join(repositoryRoot, "scripts/workflow/sign-windows.ps1"), "utf8");
  assert.match(script, /--config\.forceCodeSigning=true/);
  assert.match(script, /--config\.win\.forceCodeSigning=true/);
  assert.match(script, /--config\.generateUpdatesFilesForAllChannels=false/);
  assert.match(script, /--config\.win\.generateUpdatesFilesForAllChannels=false/);
  assert.match(script, /--config\.publish\.provider=generic/);
  assert.match(script, /--config\.publish\.url=\$publishUrl/);
  assert.match(script, /--config\.win\.publish\.provider=generic/);
  assert.match(script, /--config\.win\.publish\.url=\$publishUrl/);
  assert.match(script, /--config\.nsis\.publish\.provider=generic/);
  assert.match(script, /--config\.nsis\.publish\.url=\$publishUrl/);
  assert.match(script, /--config\.nsisWeb\.publish\.provider=generic/);
  assert.match(script, /--config\.nsisWeb\.publish\.url=\$publishUrl/);
  assert.match(script, /--config\.nsisWeb\.appPackageUrl=null/);
  assert.match(script, /\$webInstaller = Find-Artifact \$webDirectory \$webInstallerName/);
  assert.match(script, /\$webPackage = Find-Artifact \$webDirectory \$webPackageName/);
  assert.match(script, /Get-MetadataValue \$webMetadata 'path'/);
  assert.match(script, /\^\[ \\t\]\+file:/);
  assert.doesNotMatch(script, /FullName \+ '\.7z'/);
});

void test("workflowのversionは生成metadataから取得する", () => {
  const workflow = readFileSync(join(repositoryRoot, ".github/workflows/sign-release.yml"), "utf8");
  assert.match(workflow, /生成metadataのversionを出力/);
  assert.match(workflow, /macos-release\/metadata/);
  assert.match(workflow, /windows-release.*metadata/);
  assert.doesNotMatch(workflow, /source versionを出力/);
});
