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
  | "wrong-web-extension"
  | "cleanup";

function powershellLiteral(value: string): string {
  return `'${value.replaceAll("'", "''")}'`;
}

function realPnpmPath(): string {
  const output = execFileSync("where.exe", ["pnpm"], { encoding: "utf8" });
  const path = output.split(/\r?\n/).find((line) => line.length > 0);
  if (path == undefined) {
    throw new Error("pnpmの実行ファイルがありません");
  }
  return path;
}

function createFixture(mode: WorkflowMode): {
  argumentsPath: string;
  cleanupPath: string;
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
    JSON.stringify({
      version: "1.0.0-foo-mac.1",
      packageManager: "pnpm@10.30.2",
      scripts: { build: "build" },
      devDependencies: { "electron-builder": "26.16.1" }
    })
  );
  writeFileSync(
    join(sourceDirectory, "electron-builder.yml"),
    [
      "productName: App",
      "extraMetadata:",
      "  version: 9.9.9",
      "win:",
      "  target:",
      "    - nsis",
      ""
    ].join("\n")
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
      "const childProcess = require('node:child_process');",
      "const args = process.argv.slice(2);",
      "if (args[0] === 'cli') {",
      "  const result = childProcess.spawnSync(process.env.WINDOWS_TEST_REAL_PNPM, args, { stdio: 'inherit', shell: true });",
      "  process.exit(result.status === null ? 1 : result.status);",
      "}",
      "if (args[0] === 'exec' && args[1] === 'tsx') {",
      "  const result = childProcess.spawnSync(process.env.WINDOWS_TEST_REAL_PNPM, args, { stdio: 'inherit', shell: true });",
      "  process.exit(result.status === null ? 1 : result.status);",
      "}",
      "if (args[0] !== 'exec' || args[1] !== 'electron-builder') process.exit(0);",
      "const outputArg = args.find((arg) => arg.startsWith('--config.directories.output='));",
      "if (outputArg === undefined) process.exit(1);",
      "const output = outputArg.slice('--config.directories.output='.length);",
      "const nested = path.join(output, 'nested');",
      "const web = path.join(output, 'nsis-web', 'nested');",
      "fs.mkdirSync(nested, { recursive: true });",
      "fs.mkdirSync(web, { recursive: true });",
      "fs.writeFileSync(process.env.WINDOWS_TEST_ARGUMENTS, args.join('\\n'));",
      "const version = '1.0.0-foo-mac.1';",
      "const channel = 'foo-mac';",
      "const installer = 'App Setup ' + version + '.exe';",
      "const webInstaller = 'App Web Setup ' + version + '.exe';",
      "const webPackage = 'app-' + version + '-x64.nsis.7z';",
      "fs.writeFileSync(path.join(nested, installer), 'exe');",
      "fs.writeFileSync(path.join(nested, installer + '.blockmap'), 'blockmap');",
      "fs.writeFileSync(path.join(web, webInstaller), 'web-exe');",
      "fs.writeFileSync(path.join(web, webPackage), 'web-package');",
      "const sha512 = 'A'.repeat(86) + '==';",
      "const metadata = [",
      "  'version: ' + version,",
      "  'files:',",
      "  '  - url: ' + installer,",
      "  '    sha512: ' + sha512,",
      "  '    size: 3',",
      "  'path: ' + installer,",
      "  'sha512: ' + sha512,",
      "  ''",
      "].join('\\n');",
      "fs.writeFileSync(path.join(output, channel + '.yml'), metadata);",
      "const packageName = process.env.WINDOWS_TEST_MODE === 'wrong-web-extension' ? webPackage.replace('.nsis.7z', '.nsis.zip') : webPackage;",
      "const webMetadata = [",
      "  'version: ' + version,",
      "  'files:',",
      "  '  - url: ' + webInstaller,",
      "  '    sha512: ' + sha512,",
      "  'path: ' + webInstaller,",
      "  'sha512: ' + sha512,",
      "  'packages:',",
      "  '  x64:',",
      "  '    size: 11',",
      "  '    sha512: ' + sha512,",
      "  '    path: ' + packageName,",
      "  '    file: ' + packageName,",
      "  ''",
      "].join('\\n');",
      "fs.writeFileSync(path.join(output, 'nsis-web', channel + '.yml'), webMetadata);",
      "fs.writeFileSync(path.join(output, 'builder-debug.yml'), 'debug');",
      "fs.writeFileSync(path.join(output, 'nsis-web', 'unrelated.exe'), 'extra');",
      "fs.writeFileSync(path.join(output, 'nsis-web', 'unrelated.nsis.7z'), 'extra');",
      "if (process.env.WINDOWS_TEST_MODE === 'missing') fs.rmSync(path.join(nested, installer + '.blockmap'));",
      "if (process.env.WINDOWS_TEST_MODE === 'duplicate') { fs.mkdirSync(path.join(output, 'duplicate'), { recursive: true }); fs.writeFileSync(path.join(output, 'duplicate', installer), 'duplicate'); }",
      "if (process.env.WINDOWS_TEST_MODE === 'web-missing') fs.rmSync(path.join(web, webPackage));",
      "if (process.env.WINDOWS_TEST_MODE === 'web-duplicate') { fs.mkdirSync(path.join(output, 'nsis-web', 'duplicate'), { recursive: true }); fs.writeFileSync(path.join(output, 'nsis-web', 'duplicate', webPackage), 'duplicate'); }",
      ""
    ].join("\r\n")
  );

  const env: NodeJS.ProcessEnv = {
    ...process.env,
    PATH: `${binDirectory}${process.platform === "win32" ? ";" : ":"}${process.env.PATH ?? ""}`,
    WINDOWS_TEST_ARGUMENTS: argumentsPath,
    WINDOWS_TEST_CLEANUP_PATH: cleanupPath,
    WINDOWS_TEST_MODE: mode,
    WINDOWS_TEST_REAL_PNPM: realPnpmPath(),
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
          outputDirectory,
          "-ExpectedVersion",
          "1.0.0-foo-mac.1",
          "-Channel",
          "foo-mac",
          "-BuilderConfig",
          "electron-builder.yml"
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
      `& ${powershellLiteral(scriptPath)} -SourceDirectory ${powershellLiteral(sourceDirectory)} -Repository 'owner/name' -Tag 'v1.0.0-beta.1' -ReleaseOutputDirectory ${powershellLiteral(outputDirectory)} -ExpectedVersion '1.0.0-foo-mac.1' -Channel 'foo-mac' -BuilderConfig 'electron-builder.yml'`
    ].join("\n");
    execFileSync("pwsh", ["-NoProfile", "-NonInteractive", "-Command", command], {
      cwd: repositoryRoot,
      env,
      stdio: "pipe"
    });
  };
  return { argumentsPath, cleanupPath, outputDirectory, run: invoke };
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

void windowsTest("Windows scriptがfoo-mac channelの成果物と余分な出力を正しく選ぶ", () => {
  withFixture("normal", ({ argumentsPath, outputDirectory, run }) => {
    run();
    const argumentsText = readFileSync(argumentsPath, "utf8");
    assert.match(argumentsText, /--config\.publish\.provider=generic/);
    assert.match(argumentsText, /--config\.publish\.channel=foo-mac/);
    assert.match(argumentsText, /--config\.forceCodeSigning=true/);
    assert.match(argumentsText, /--config\.win\.forceCodeSigning=true/);
    assert.match(argumentsText, /--config\.detectUpdateChannel=false/);
    assert.match(argumentsText, /--config\.win\.detectUpdateChannel=false/);
    assert.match(argumentsText, /--config\.nsis\.differentialPackage=true/);
    assert.match(argumentsText, /--config\.nsisWeb\.differentialPackage=true/);
    assert.match(argumentsText, /--config\.nsisWeb\.useZip=false/);
    assert.match(argumentsText, /--config\.nsisWeb\.appPackageUrl=null/);
    assert.doesNotMatch(argumentsText, /--config\.win\.publish/);
    assert.doesNotMatch(argumentsText, /--config\.nsis\.publish/);
    assert.doesNotMatch(argumentsText, /--config\.nsisWeb\.publish/);
    assert.equal(existsSync(join(outputDirectory, "payload/App Setup 1.0.0-foo-mac.1.exe")), true);
    assert.equal(
      existsSync(join(outputDirectory, "payload/App Setup 1.0.0-foo-mac.1.exe.blockmap")),
      true
    );
    assert.equal(
      existsSync(join(outputDirectory, "payload/App Web Setup 1.0.0-foo-mac.1.exe")),
      true
    );
    assert.equal(
      existsSync(join(outputDirectory, "payload/app-1.0.0-foo-mac.1-x64.nsis.7z")),
      true
    );
    assert.equal(existsSync(join(outputDirectory, "metadata/foo-mac.yml")), true);
    assert.equal(existsSync(join(outputDirectory, "payload/unrelated.exe")), false);
  });
});

void windowsTest("Windows scriptの通常NSIS blockmap欠落を検出する", () => {
  withFixture("missing", ({ run }) => {
    assert.throws(run);
  });
});

void windowsTest("Windows scriptの通常NSIS成果物重複を検出する", () => {
  withFixture("duplicate", ({ run }) => {
    assert.throws(run);
  });
});

void windowsTest("Windows scriptのNSIS Web package欠落と重複を検出する", () => {
  withFixture("web-missing", ({ run }) => {
    assert.throws(run);
  });
  withFixture("web-duplicate", ({ run }) => {
    assert.throws(run);
  });
});

void windowsTest("Windows scriptがnsis.zipをNSIS Web packageとして受け入れない", () => {
  withFixture("wrong-web-extension", ({ run }) => {
    assert.throws(run);
  });
});

void windowsTest("Windows scriptのcleanup失敗を検出する", () => {
  withFixture("cleanup", ({ cleanupPath, outputDirectory, run }) => {
    assert.throws(run);
    assert.match(readFileSync(cleanupPath, "utf8"), /central-package-windows-/);
    assert.equal(existsSync(join(outputDirectory, "payload/App Setup 1.0.0-foo-mac.1.exe")), true);
  });
});
