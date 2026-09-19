param(
  [Parameter(Mandatory = $true)][string]$SourceDirectory,
  [Parameter(Mandatory = $true)][string]$Repository,
  [Parameter(Mandatory = $true)][string]$Tag,
  [Parameter(Mandatory = $true)][string]$ReleaseOutputDirectory
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

if ([string]::IsNullOrEmpty($SourceDirectory) -or [string]::IsNullOrEmpty($ReleaseOutputDirectory)) {
  throw 'pathを空にできません'
}
if ($Repository -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9_.-]*[A-Za-z0-9])?/[A-Za-z0-9](?:[A-Za-z0-9_.-]*[A-Za-z0-9])?$') {
  throw 'repositoryはowner/name形式でなければなりません'
}
if ([string]::IsNullOrEmpty($Tag)) {
  throw 'tagが空です'
}
& git check-ref-format "refs/tags/$Tag"
Assert-ExternalSuccess 'tagはGit refとして不正です'
if ([string]::IsNullOrEmpty($env:WIN_CSC_LINK) -or [string]::IsNullOrEmpty($env:WIN_CSC_KEY_PASSWORD)) {
  throw 'Windows署名用のWIN_CSC_LINKとWIN_CSC_KEY_PASSWORDが必要です'
}

$sourceItem = Assert-Directory $SourceDirectory 'source directoryが通常directoryではありません'
$releaseItem = $null
if (Test-Path -LiteralPath $ReleaseOutputDirectory -PathType Any) {
  $releaseItem = Assert-Directory $ReleaseOutputDirectory 'release outputが通常directoryではありません'
  if (@(Get-ChildItem -LiteralPath $releaseItem.FullName -Force -ErrorAction Stop).Count -ne 0) {
    throw 'release outputは空のdirectoryでなければなりません'
  }
} else {
  New-Item -ItemType Directory -Path $ReleaseOutputDirectory -ErrorAction Stop | Out-Null
  $releaseItem = Assert-Directory $ReleaseOutputDirectory 'release outputが通常directoryではありません'
}

$packageJsonPath = Join-Path $sourceItem.FullName 'package.json'
Assert-RegularFile $packageJsonPath 'source package.jsonが通常fileではありません' | Out-Null
$packageJson = Get-Content -LiteralPath $packageJsonPath -Raw -ErrorAction Stop | ConvertFrom-Json
$packageManager = [string]$packageJson.packageManager
if ($packageManager -notmatch '^pnpm@(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(\+[A-Za-z0-9._-]+)?$') {
  throw 'source packageManagerが不正です'
}

$temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('central-package-windows-' + [Guid]::NewGuid().ToString('N'))
$operationException = $null
$cleanupExceptions = [System.Collections.Generic.List[System.Exception]]::new()
try {
  New-Item -ItemType Directory -Path $temporaryDirectory -ErrorAction Stop | Out-Null
  $builderOutput = Join-Path $temporaryDirectory 'dist'
  New-Item -ItemType Directory -Path $builderOutput -ErrorAction Stop | Out-Null
  & corepack enable
  Assert-ExternalSuccess 'source用corepackの有効化に失敗しました'
  & corepack prepare $packageManager --activate
  Assert-ExternalSuccess 'source用pnpmの準備に失敗しました'
  Push-Location $sourceItem.FullName
  try {
    & pnpm install --frozen-lockfile
    Assert-ExternalSuccess 'sourceのfrozen installに失敗しました'
    & pnpm run build
    Assert-ExternalSuccess 'sourceのbuildに失敗しました'
    $encodedTag = [Uri]::EscapeDataString($Tag)
    $publishUrl = "https://github.com/$Repository/releases/download/$encodedTag"
    & pnpm exec electron-builder `
      --win nsis nsis-web `
      --x64 `
      --publish never `
      "--config.directories.output=$builderOutput" `
      --config.forceCodeSigning=true `
      --config.publish.provider=generic `
      "--config.publish.url=$publishUrl"
    Assert-ExternalSuccess 'sourceのelectron-builder実行に失敗しました'
  } finally {
    Pop-Location
  }

  $normalInstallers = @(Get-ChildItem -LiteralPath $builderOutput -File -Force -ErrorAction Stop | Where-Object {
      $_.Extension -ieq '.exe' -and (Test-Path -LiteralPath ($_.FullName + '.blockmap') -PathType Leaf)
    })
  $normalBlockmaps = @(Get-ChildItem -LiteralPath $builderOutput -File -Force -ErrorAction Stop | Where-Object {
      $_.Extension -ieq '.blockmap' -and (Test-Path -LiteralPath ($_.FullName -replace '\.blockmap$', '') -PathType Leaf)
    })
  $metadataPath = Join-Path $builderOutput 'latest.yml'
  $metadataFiles = @()
  if (Test-Path -LiteralPath $metadataPath -PathType Leaf) {
    $metadataFiles = @(Get-Item -LiteralPath $metadataPath -Force -ErrorAction Stop)
  }
  $webDirectory = Join-Path $builderOutput 'nsis-web'
  Assert-Directory $webDirectory 'NSIS Web output directoryがありません' | Out-Null
  $webInstallers = @(Get-ChildItem -LiteralPath $webDirectory -File -Force -ErrorAction Stop | Where-Object {
      $_.Extension -ieq '.exe' -and (Test-Path -LiteralPath ($_.FullName + '.7z') -PathType Leaf)
    })
  $webPackages = @(Get-ChildItem -LiteralPath $webDirectory -File -Force -ErrorAction Stop | Where-Object {
      $_.Extension -ieq '.7z' -and (Test-Path -LiteralPath ($_.FullName -replace '\.7z$', '') -PathType Leaf)
    })
  if ($normalInstallers.Count -ne 1 -or $normalBlockmaps.Count -ne 1 -or $metadataFiles.Count -ne 1 -or $webInstallers.Count -ne 1 -or $webPackages.Count -ne 1) {
    throw 'Windows packageの通常NSIS、blockmap、metadata、NSIS Web、7zが揃っていません'
  }

  $payloadDirectory = Join-Path $releaseItem.FullName 'payload'
  $metadataDirectory = Join-Path $releaseItem.FullName 'metadata'
  New-Item -ItemType Directory -Path $payloadDirectory -ErrorAction Stop | Out-Null
  New-Item -ItemType Directory -Path $metadataDirectory -ErrorAction Stop | Out-Null
  Copy-Item -LiteralPath $normalInstallers[0].FullName -Destination (Join-Path $payloadDirectory $normalInstallers[0].Name) -ErrorAction Stop
  Copy-Item -LiteralPath $normalBlockmaps[0].FullName -Destination (Join-Path $payloadDirectory $normalBlockmaps[0].Name) -ErrorAction Stop
  Copy-Item -LiteralPath $webInstallers[0].FullName -Destination (Join-Path $payloadDirectory $webInstallers[0].Name) -ErrorAction Stop
  Copy-Item -LiteralPath $webPackages[0].FullName -Destination (Join-Path $payloadDirectory $webPackages[0].Name) -ErrorAction Stop
  Copy-Item -LiteralPath $metadataFiles[0].FullName -Destination (Join-Path $metadataDirectory $metadataFiles[0].Name) -ErrorAction Stop
} catch {
  $operationException = $_.Exception
} finally {
  try {
    $env:WIN_CSC_LINK = $null
    $env:WIN_CSC_KEY_PASSWORD = $null
  } catch {
    [void]$cleanupExceptions.Add($_.Exception)
  }
  if (Test-Path -LiteralPath $temporaryDirectory -PathType Any) {
    try {
      Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction Stop
    } catch {
      [void]$cleanupExceptions.Add($_.Exception)
    }
  }
}

if ($null -ne $operationException -and $cleanupExceptions.Count -ne 0) {
  $allExceptions = [System.Collections.Generic.List[System.Exception]]::new()
  [void]$allExceptions.Add($operationException)
  foreach ($cleanupException in $cleanupExceptions) {
    [void]$allExceptions.Add($cleanupException)
  }
  throw [System.AggregateException]::new('Windows packageの失敗とcleanupの失敗が発生しました', $allExceptions)
}
if ($null -ne $operationException) {
  throw $operationException
}
if ($cleanupExceptions.Count -ne 0) {
  throw [System.AggregateException]::new('Windows packageのcleanupに失敗しました', $cleanupExceptions)
}
