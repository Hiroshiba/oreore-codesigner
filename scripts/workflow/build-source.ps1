param(
  [Parameter(Mandatory = $true)][string]$Platform,
  [Parameter(Mandatory = $true)][string]$SourceRoot,
  [Parameter(Mandatory = $true)][string]$WorkingDirectory,
  [Parameter(Mandatory = $true)][string]$BuildScript,
  [Parameter(Mandatory = $true)][string]$PnpmVersion,
  [Parameter(Mandatory = $true)][string]$SourceSha,
  [Parameter(Mandatory = $true)][string]$SourceTag,
  [Parameter(Mandatory = $true)][string]$ArchivePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Platform -ne 'windows') {
  throw "platformが不正です: $Platform"
}
if ($env:CENTRAL_BUILD_ARCH -notmatch '^(x64|arm64)$') {
  throw 'CENTRAL_BUILD_ARCHが不正です'
}
if ($WorkingDirectory -notmatch '^\.?([A-Za-z0-9._-]+/)*[A-Za-z0-9._-]+$|^\.$') {
  throw "working directoryが不正です: $WorkingDirectory"
}
if ($BuildScript -notmatch '^[A-Za-z0-9:_-]+$') {
  throw "build script名が不正です: $BuildScript"
}
if ($PnpmVersion -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
  throw "pnpm versionが不正です: $PnpmVersion"
}
if ($SourceSha -notmatch '^[0-9a-fA-F]{40}$') {
  throw 'source SHAが40桁ではありません'
}
if ($SourceTag.Length -eq 0) {
  throw 'source tagが空です'
}
if ($env:SOURCE_DATE_EPOCH -notmatch '^[0-9]+$') {
  throw 'SOURCE_DATE_EPOCHが整数ではありません'
}

$prepackagedDirectory = $env:CENTRAL_PREPACKAGED_DIR
if ([string]::IsNullOrEmpty($prepackagedDirectory)) {
  throw 'CENTRAL_PREPACKAGED_DIRが必要です'
}

$sourceItem = Get-Item -LiteralPath $SourceRoot -Force -ErrorAction Stop
if ($sourceItem -isnot [System.IO.DirectoryInfo] -or ($sourceItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
  throw 'source rootが不正です'
}

if (Test-Path -LiteralPath $prepackagedDirectory) {
  $prepackagedItem = Get-Item -LiteralPath $prepackagedDirectory -Force -ErrorAction Stop
  if ($prepackagedItem -isnot [System.IO.DirectoryInfo] -or ($prepackagedItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'prepackaged outputが通常directoryではありません'
  }
  if (@(Get-ChildItem -LiteralPath $prepackagedDirectory -Force).Count -ne 0) {
    throw 'prepackaged outputは事前に空でなければなりません'
  }
} else {
  New-Item -ItemType Directory -Path $prepackagedDirectory -ErrorAction Stop | Out-Null
}

corepack enable
if ($LASTEXITCODE -ne 0) {
  throw 'source用corepackの有効化に失敗しました'
}
corepack prepare "pnpm@$PnpmVersion" --activate
if ($LASTEXITCODE -ne 0) {
  throw 'source用pnpmの準備に失敗しました'
}
$actualPnpmVersion = (& pnpm --version)
if ($LASTEXITCODE -ne 0 -or $actualPnpmVersion.Trim() -ne $PnpmVersion) {
  throw "source pnpm versionが一致しません: $actualPnpmVersion"
}
Push-Location $SourceRoot
try {
  & pnpm install --frozen-lockfile
  if ($LASTEXITCODE -ne 0) {
    throw 'sourceのfrozen installに失敗しました'
  }
} finally {
  Pop-Location
}

$workingPath = $SourceRoot
if ($WorkingDirectory -ne '.') {
  $workingPath = Join-Path $SourceRoot $WorkingDirectory
}
$workingItem = Get-Item -LiteralPath $workingPath -Force -ErrorAction Stop
if ($workingItem -isnot [System.IO.DirectoryInfo] -or ($workingItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
  throw "working directoryが不正です: $workingPath"
}

$env:CENTRAL_BUILD_PLATFORM = $Platform
$env:CENTRAL_PREPACKAGED_DIR = $prepackagedDirectory
$env:CENTRAL_SOURCE_SHA = $SourceSha
$env:CENTRAL_SOURCE_TAG = $SourceTag
Push-Location $workingPath
try {
  & pnpm run $BuildScript
  if ($LASTEXITCODE -ne 0) {
    throw "allowlist済みbuild scriptが失敗しました: $BuildScript"
  }
} finally {
  Pop-Location
}

$entries = @(Get-ChildItem -LiteralPath $prepackagedDirectory -Force)
if ($entries.Count -ne 1) {
  throw 'prepackaged outputは直下一件でなければなりません'
}
$entry = $entries[0]
if (-not $entry.PSIsContainer -or ($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
  throw 'prepackaged outputの直下はsymlinkでないdirectoryでなければなりません'
}

$archiveParent = Split-Path -Parent $ArchivePath
if (-not (Test-Path -LiteralPath $archiveParent -PathType Container)) {
  New-Item -ItemType Directory -Path $archiveParent -ErrorAction Stop | Out-Null
}
tar -cf $ArchivePath -C $prepackagedDirectory $entry.Name
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
  throw 'prepackaged archiveの作成に失敗しました'
}
