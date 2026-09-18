param(
  [Parameter(Mandatory = $true)][string]$SourceArchive,
  [Parameter(Mandatory = $true)][string]$SourceSha,
  [Parameter(Mandatory = $true)][string]$CommitTimestamp,
  [Parameter(Mandatory = $true)][string]$UnsignedArchive,
  [Parameter(Mandatory = $true)][string]$PackageInputDirectory,
  [Parameter(Mandatory = $true)][Alias('GithubOutputPath')][string]$OutputFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-ExternalSuccess([string]$Message) {
  if ($LASTEXITCODE -ne 0) {
    throw $Message
  }
}

function Assert-RegularFile([string]$Path, [string]$Message) {
  $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
  if ($item -isnot [System.IO.FileInfo] -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw $Message
  }
  return $item
}

function Assert-Directory([string]$Path, [string]$Message) {
  $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
  if ($item -isnot [System.IO.DirectoryInfo] -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw $Message
  }
  return $item
}

function Get-TarCommitId([string]$Archive) {
  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = 'git.exe'
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardInput = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  [void]$startInfo.ArgumentList.Add('get-tar-commit-id')
  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  if (-not $process.Start()) {
    throw 'git get-tar-commit-idを起動できません'
  }
  try {
    $outputTask = $process.StandardOutput.ReadToEndAsync()
    $errorTask = $process.StandardError.ReadToEndAsync()
    $stream = [System.IO.File]::OpenRead($Archive)
    try {
      $stream.CopyTo($process.StandardInput.BaseStream)
    } finally {
      $stream.Dispose()
    }
    $process.StandardInput.Close()
    $process.WaitForExit()
    $output = $outputTask.Result.Trim()
    $null = $errorTask.Result
    if ($process.ExitCode -ne 0) {
      throw 'source archiveのcommit SHAを確認できません'
    }
    return $output
  } finally {
    if (-not $process.HasExited) {
      $process.Kill()
      $process.WaitForExit()
    }
    $process.Dispose()
  }
}

if ($SourceArchive.Length -eq 0 -or $UnsignedArchive.Length -eq 0 -or $PackageInputDirectory.Length -eq 0 -or $OutputFile.Length -eq 0) {
  throw 'pathを空にできません'
}
if ($SourceSha -notmatch '^[0-9a-fA-F]{40}$') {
  throw 'source SHAが40桁ではありません'
}
if ($CommitTimestamp -notmatch '^[0-9]+$') {
  throw 'commit timestampが整数ではありません'
}

$SourceArchive = [System.IO.Path]::GetFullPath($SourceArchive)
$UnsignedArchive = [System.IO.Path]::GetFullPath($UnsignedArchive)
$PackageInputDirectory = [System.IO.Path]::GetFullPath($PackageInputDirectory)
$OutputFile = [System.IO.Path]::GetFullPath($OutputFile)
Assert-RegularFile $SourceArchive 'source archiveが通常fileではありません' | Out-Null
if (Test-Path -LiteralPath $UnsignedArchive -PathType Any) {
  throw 'unsigned app archiveは開始時に存在してはいけません'
}
if (Test-Path -LiteralPath $PackageInputDirectory -PathType Any) {
  throw 'package-input directoryは開始時に存在してはいけません'
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$centralRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptRoot '../..'))
$safeExtractor = Join-Path $scriptRoot 'safe-extract.py'
Assert-Directory $centralRoot '中央repoのpathが不正です' | Out-Null
Assert-RegularFile $safeExtractor 'safe-extract.pyが通常fileではありません' | Out-Null
$archiveSha = Get-TarCommitId $SourceArchive
if ($archiveSha -notmatch '^[0-9a-fA-F]{40}$' -or $archiveSha.ToLowerInvariant() -cne $SourceSha.ToLowerInvariant()) {
  throw 'source archiveのcommit SHAが一致しません'
}

$temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('central-build-source-' + [Guid]::NewGuid().ToString('N'))
$operationException = $null
try {
  New-Item -ItemType Directory -Path $temporaryDirectory -ErrorAction Stop | Out-Null
  $sourceParent = Join-Path $temporaryDirectory 'source-parent'
  $python = Get-Command python.exe -ErrorAction Stop
  & $python.Source $safeExtractor --archive $SourceArchive --output $sourceParent --platform windows
  Assert-ExternalSuccess 'source archiveの安全な展開に失敗しました'

  $rootEntries = @(Get-ChildItem -LiteralPath $sourceParent -Force -ErrorAction Stop)
  if ($rootEntries.Count -ne 1) {
    throw 'source archiveのrootは一件でなければなりません'
  }
  $sourceRoot = $rootEntries[0]
  if ($sourceRoot.Name -cne 'source' -or $sourceRoot -isnot [System.IO.DirectoryInfo] -or ($sourceRoot.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'source archiveのrootはsource directory一件でなければなりません'
  }
  $sourceRootPath = $sourceRoot.FullName

  $packageJsonPath = Join-Path $sourceRootPath 'package.json'
  $lockfilePath = Join-Path $sourceRootPath 'pnpm-lock.yaml'
  Assert-RegularFile $packageJsonPath 'source rootのpackage.jsonが通常fileではありません' | Out-Null
  Assert-RegularFile $lockfilePath 'source rootのpnpm-lock.yamlが通常fileではありません' | Out-Null

  $builderPaths = [System.Collections.Generic.List[string]]::new()
  foreach ($builderName in @('electron-builder.yml', 'electron-builder.yaml')) {
    $builderPath = Join-Path $sourceRootPath $builderName
    if (Test-Path -LiteralPath $builderPath -PathType Any) {
      Assert-RegularFile $builderPath "electron-builder設定が通常fileではありません: $builderName" | Out-Null
      [void]$builderPaths.Add($builderPath)
    }
  }
  if ($builderPaths.Count -ne 1) {
    throw 'source rootのelectron-builder設定は一件でなければなりません'
  }
  $builderConfig = $builderPaths[0]

  $packageJson = Get-Content -LiteralPath $packageJsonPath -Raw -ErrorAction Stop | ConvertFrom-Json
  $packageManager = [string]$packageJson.packageManager
  if ($packageManager -notmatch '^pnpm@(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(\+[A-Za-z0-9._-]+)?$') {
    throw 'source rootのpackageManagerがCorepackのexact specではありません'
  }

  $env:SOURCE_DATE_EPOCH = $CommitTimestamp
  & corepack enable
  Assert-ExternalSuccess 'source用corepackの有効化に失敗しました'
  & corepack prepare $packageManager --activate
  Assert-ExternalSuccess 'source用pnpmの準備に失敗しました'
  Push-Location $sourceRootPath
  try {
    & pnpm install --frozen-lockfile
    Assert-ExternalSuccess 'sourceのfrozen installに失敗しました'
    & pnpm run build
    Assert-ExternalSuccess 'sourceのbuildに失敗しました'
  } finally {
    Pop-Location
  }

  $builderOutput = Join-Path $temporaryDirectory 'builder-output'
  New-Item -ItemType Directory -Path $builderOutput -ErrorAction Stop | Out-Null
  Push-Location $sourceRootPath
  try {
    & pnpm exec electron-builder --dir --win --x64 --publish never --config $builderConfig "--config.directories.output=$builderOutput"
    Assert-ExternalSuccess 'sourceのelectron-builder実行に失敗しました'
  } finally {
    Pop-Location
  }

  $prepackagedEntries = @(Get-ChildItem -LiteralPath $builderOutput -Recurse -Directory -Force -ErrorAction Stop | Where-Object { $_.Name -ceq 'win-unpacked' })
  if ($prepackagedEntries.Count -ne 1) {
    throw 'Windows prepackaged outputは一件でなければなりません'
  }
  $prepackagedEntry = $prepackagedEntries[0]
  if ($prepackagedEntry -isnot [System.IO.DirectoryInfo] -or ($prepackagedEntry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'Windows prepackaged outputはwin-unpacked directory一件でなければなりません'
  }
  $prepackagedDirectory = $prepackagedEntry.FullName

  $packageInputParent = Split-Path -Parent $PackageInputDirectory
  if (-not (Test-Path -LiteralPath $packageInputParent -PathType Container)) {
    New-Item -ItemType Directory -Path $packageInputParent -ErrorAction Stop | Out-Null
  }
  Push-Location $centralRoot
  try {
    & pnpm cli create-package-input --source-directory $sourceRootPath --prepackaged-directory $prepackagedDirectory --platform windows --output-directory $PackageInputDirectory
    Assert-ExternalSuccess 'package-input生成に失敗しました'
  } finally {
    Pop-Location
  }
  $packageInputPath = Join-Path $PackageInputDirectory 'package-input.json'
  Assert-RegularFile $packageInputPath 'package-input.jsonが生成されませんでした' | Out-Null
  $packageInput = Get-Content -LiteralPath $packageInputPath -Raw -ErrorAction Stop | ConvertFrom-Json
  $version = [string]$packageInput.version
  if ($version.Length -eq 0) {
    throw 'package-input.jsonのversionが空です'
  }
  $githubOutputParent = Split-Path -Parent $OutputFile
  if (-not (Test-Path -LiteralPath $githubOutputParent -PathType Container)) {
    New-Item -ItemType Directory -Path $githubOutputParent -ErrorAction Stop | Out-Null
  }
  if (Test-Path -LiteralPath $OutputFile -PathType Any) {
    $githubOutputItem = Get-Item -LiteralPath $OutputFile -Force -ErrorAction Stop
    if (($githubOutputItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw 'GitHub output pathにsymlinkを指定できません'
    }
  }
  Add-Content -LiteralPath $OutputFile -Value "version=$version" -Encoding utf8 -ErrorAction Stop

  $unsignedArchiveParent = Split-Path -Parent $UnsignedArchive
  if (-not (Test-Path -LiteralPath $unsignedArchiveParent -PathType Container)) {
    New-Item -ItemType Directory -Path $unsignedArchiveParent -ErrorAction Stop | Out-Null
  }
  $prepackagedParent = Split-Path -Parent $prepackagedDirectory
  & tar -cf $UnsignedArchive -C $prepackagedParent $prepackagedEntry.Name
  Assert-ExternalSuccess 'unsigned app archiveの生成に失敗しました'
  Assert-RegularFile $UnsignedArchive 'unsigned app archiveが通常fileではありません' | Out-Null
} catch {
  $operationException = $_.Exception
} finally {
  $cleanupException = $null
  try {
    if (Test-Path -LiteralPath $temporaryDirectory -PathType Any) {
      Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction Stop
    }
  } catch {
    $cleanupException = $_.Exception
  }
  if ($null -ne $operationException -and $null -ne $cleanupException) {
    throw [System.AggregateException]::new('source buildとcleanupに失敗しました', @($operationException, $cleanupException))
  }
  if ($null -ne $cleanupException) {
    throw $cleanupException
  }
}
if ($null -ne $operationException) {
  throw $operationException
}
