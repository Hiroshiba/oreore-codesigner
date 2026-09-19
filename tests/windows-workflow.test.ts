import { strict as assert } from "node:assert";
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const repositoryRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const windowsTest = process.platform === "win32" ? test : test.skip;

type WorkflowMode =
  | "normal"
  | "missing"
  | "duplicate"
  | "web-missing"
  | "web-duplicate"
  | "cleanup";

function powershellLiteral(value: string): string {
  return `'${value.replaceAll("'", "''")}'`;
}

function createFixture(mode: WorkflowMode): {
  argumentsPath: string;
  outputDirectory: string;
  run: () => void;
} {
  const workDirectory = mkdtempSync(join(tmpdir(), "windows-workflow-test-"));
  const sourceDirectory = join(workDirectory, "source");
  const binDirectory = join(workDirectory, "bin");
  const outputDirectory = join(workDirectory, "release");
  const argumentsPath = join(workDirectory, "builder-arguments.txt");
  const cleanupPath = join(workDirectory, "cleanup-path.txt");
  mkdirSync(sourceDirectory);
  mkdirSync(binDirectory);
  writeFileSync(
    join(sourceDirectory, "package.json"),
    JSON.stringify({ packageManager: "pnpm@10.30.2" })
  );
  writeFileSync(join(binDirectory, "corepack.cmd"), "@echo off\r\nexit /b 0\r\n");
  writeFileSync(
    join(binDirectory, "pnpm.cmd"),
    '@echo off\r\nnode "%~dp0fake-pnpm.cjs" %*\r\nexit /b %errorlevel%\r\n'
  );
  writeFileSync(
    join(binDirectory, "fake-pnpm.cjs"),
    [
      "const fs = require('node:fs');",
      "const path = require('node:path');",
      "const args = process.argv.slice(2);",
      "if (args[0] !== 'exec' || args[1] !== 'electron-builder') process.exit(0);",
      "const outputArg = args.find((arg) => arg.startsWith('--config.directories.output='));",
      "if (outputArg === undefined) process.exit(1);",
      "const output = outputArg.slice('--config.directories.output='.length);",
      "const nested = path.join(output, 'nested');",
      "const web = path.join(output, 'nsis-web', 'nested');",
      "fs.mkdirSync(nested, { recursive: true });",
      "fs.mkdirSync(web, { recursive: true });",
      "fs.writeFileSync(process.env.WINDOWS_TEST_ARGUMENTS, args.join('\\n'));",
      "const version = '1.0.0-beta.1';",
      "const installer = 'App Setup ' + version + '.exe';",
      "const webInstaller = 'App Web Setup ' + version + '.exe';",
      "const webPackage = 'app-' + version + '-x64.nsis.7z';",
      "fs.writeFileSync(path.join(nested, installer), 'exe');",
      "fs.writeFileSync(path.join(nested, installer + '.blockmap'), 'blockmap');",
      "fs.writeFileSync(path.join(web, webInstaller), 'web-exe');",
      "fs.writeFileSync(path.join(web, webPackage), 'web-package');",
      "const metadata = [",
      "  'version: ' + version,",
      "  'files:',",
      "  '  - url: ' + installer,",
      "  '    sha512: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==',",
      "  '    size: 3',",
      "  '    blockMapSize: 8',",
      "  'path: ' + installer,",
      "  'sha512: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==',",
      "  ''",
      "].join('\\n');",
      "fs.writeFileSync(path.join(output, 'beta.yml'), metadata);",
      "const webMetadata = [",
      "  'version: ' + version,",
      "  'files:',",
      "  '  - url: ' + webInstaller,",
      "  '    sha512: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==',",
      "  '    size: 7',",
      "  'path: ' + webInstaller,",
      "  'sha512: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==',",
      "  'packages:',",
      "  '  x64:',",
      "  '    size: 11',",
      "  '    sha512: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==',",
      "  '    path: ' + webPackage,",
      "  '    file: ' + webPackage,",
      "  ''",
      "].join('\\n');",
      "fs.writeFileSync(path.join(output, 'nsis-web', 'beta.yml'), webMetadata);",
      "fs.writeFileSync(path.join(output, 'builder-debug.yml'), 'debug');",
      "fs.writeFileSync(path.join(output, 'nsis-web', 'unrelated.exe'), 'extra');",
      "fs.writeFileSync(path.join(output, 'nsis-web', 'unrelated.nsis.7z'), 'extra');",
      `if (process.env.WINDOWS_TEST_MODE === 'missing') fs.rmSync(path.join(nested, installer + '.blockmap'));`,
      `if (process.env.WINDOWS_TEST_MODE === 'duplicate') { fs.mkdirSync(path.join(output, 'duplicate'), { recursive: true }); fs.writeFileSync(path.join(output, 'duplicate', installer), 'duplicate'); }`,
      `if (process.env.WINDOWS_TEST_MODE === 'web-missing') fs.rmSync(path.join(web, webPackage));`,
      `if (process.env.WINDOWS_TEST_MODE === 'web-duplicate') { fs.mkdirSync(path.join(output, 'nsis-web', 'duplicate'), { recursive: true }); fs.writeFileSync(path.join(output, 'nsis-web', 'duplicate', webPackage), 'duplicate'); }`,
      ""
    ].join("\r\n")
  );

  const env: NodeJS.ProcessEnv = {
    ...process.env,
    PATH: `${binDirectory}${process.platform === "win32" ? ";" : ":"}${process.env.PATH ?? ""}`,
    WINDOWS_TEST_ARGUMENTS: argumentsPath,
    WINDOWS_TEST_CLEANUP_PATH: cleanupPath,
    WINDOWS_TEST_MODE: mode,
    WIN_CSC_KEY_PASSWORD: "fixture-password",
    WIN_CSC_LINK: "fixture-certificate"
  };
  const scriptPath = join(repositoryRoot, "scripts/workflow/sign-windows.ps1");
  const invoke = (): void => {
    if (mode !== "cleanup") {
      execFileSync(
        "pwsh",
        [
          "-NoProfile",
          "-NonInteractive",
          "-File",
          scriptPath,
          "-SourceDirectory",
          sourceDirectory,
          "-Repository",
          "owner/name",
          "-Tag",
          "v1.0.0-beta.1",
          "-ReleaseOutputDirectory",
          outputDirectory
        ],
        { cwd: repositoryRoot, env, stdio: "pipe" }
      );
      return;
    }
    const command = [
      "function Remove-Item {",
      "  param([string]$LiteralPath, [switch]$Recurse, [switch]$Force, [System.Management.Automation.ActionPreference]$ErrorAction)",
      "  if ($LiteralPath -like '*central-package-windows-*') { Set-Content -LiteralPath $env:WINDOWS_TEST_CLEANUP_PATH -Value $LiteralPath; throw 'fixture cleanup failure' }",
      "  Microsoft.PowerShell.Management\\Remove-Item -LiteralPath $LiteralPath -Recurse:$Recurse -Force:$Force -ErrorAction $ErrorAction",
      "}",
      `& ${powershellLiteral(scriptPath)} -SourceDirectory ${powershellLiteral(sourceDirectory)} -Repository 'owner/name' -Tag 'v1.0.0-beta.1' -ReleaseOutputDirectory ${powershellLiteral(outputDirectory)}`
    ].join("\n");
    execFileSync("pwsh", ["-NoProfile", "-NonInteractive", "-Command", command], {
      cwd: repositoryRoot,
      env,
      stdio: "pipe"
    });
  };
  return { argumentsPath, outputDirectory, run: invoke };
}

function withFixture(
  mode: WorkflowMode,
  run: (fixture: ReturnType<typeof createFixture>) => void
): void {
  const fixture = createFixture(mode);
  try {
    run(fixture);
  } finally {
    if (existsSync(join(dirname(fixture.outputDirectory), "cleanup-path.txt"))) {
      const cleanupPath = readFileSync(
        join(dirname(fixture.outputDirectory), "cleanup-path.txt"),
        "utf8"
      ).trim();
      if (cleanupPath.length > 0) {
        rmSync(cleanupPath, { recursive: true, force: true });
      }
    }
    rmSync(dirname(fixture.outputDirectory), { recursive: true, force: true });
  }
}

void windowsTest("Windows scriptがmetadata参照で再帰的に成果物を選び余分な出力を無視する", () => {
  withFixture("normal", ({ argumentsPath, outputDirectory, run }) => {
    run();
    const argumentsText = readFileSync(argumentsPath, "utf8");
    assert.match(argumentsText, /--config\.publish\.provider=generic/);
    assert.match(
      argumentsText,
      /--config\.publish\.url=https:\/\/github\.com\/owner\/name\/releases\/download\/v1\.0\.0-beta\.1/
    );
    assert.match(argumentsText, /--config\.win\.publish\.provider=generic/);
    assert.match(
      argumentsText,
      /--config\.win\.publish\.url=https:\/\/github\.com\/owner\/name\/releases\/download\/v1\.0\.0-beta\.1/
    );
    assert.match(argumentsText, /--config\.nsis\.publish\.provider=generic/);
    assert.match(
      argumentsText,
      /--config\.nsis\.publish\.url=https:\/\/github\.com\/owner\/name\/releases\/download\/v1\.0\.0-beta\.1/
    );
    assert.match(argumentsText, /--config\.nsisWeb\.publish\.provider=generic/);
    assert.match(
      argumentsText,
      /--config\.nsisWeb\.publish\.url=https:\/\/github\.com\/owner\/name\/releases\/download\/v1\.0\.0-beta\.1/
    );
    assert.match(argumentsText, /--config\.nsisWeb\.appPackageUrl=null/);
    assert.match(argumentsText, /--config\.forceCodeSigning=true/);
    assert.match(argumentsText, /--config\.win\.forceCodeSigning=true/);
    assert.match(argumentsText, /--config\.generateUpdatesFilesForAllChannels=false/);
    assert.match(argumentsText, /--config\.win\.generateUpdatesFilesForAllChannels=false/);
    assert.equal(existsSync(join(outputDirectory, "payload/App Setup 1.0.0-beta.1.exe")), true);
    assert.equal(existsSync(join(outputDirectory, "payload/App Web Setup 1.0.0-beta.1.exe")), true);
    assert.equal(existsSync(join(outputDirectory, "payload/app-1.0.0-beta.1-x64.nsis.7z")), true);
    assert.equal(existsSync(join(outputDirectory, "payload/unrelated.exe")), false);
    assert.equal(existsSync(join(outputDirectory, "metadata/beta.yml")), true);
  });
});

void windowsTest("Windows scriptが必須出力の欠落と重複を検出する", () => {
  withFixture("missing", ({ run }) => {
    assert.throws(run);
  });
  withFixture("duplicate", ({ run }) => {
    assert.throws(run);
  });
  withFixture("web-missing", ({ run }) => {
    assert.throws(run);
  });
  withFixture("web-duplicate", ({ run }) => {
    assert.throws(run);
  });
});

void windowsTest("Windows scriptがcleanup失敗を伝播する", () => {
  withFixture("cleanup", ({ run }) => {
    assert.throws(run);
  });
});
