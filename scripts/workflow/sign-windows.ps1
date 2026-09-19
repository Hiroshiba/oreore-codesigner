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
      --config.win.forceCodeSigning=true `
      --config.generateUpdatesFilesForAllChannels=false `
      --config.win.generateUpdatesFilesForAllChannels=false `
      --config.publish.provider=generic `
      "--config.publish.url=$publishUrl" `
      --config.win.publish.provider=generic `
      "--config.win.publish.url=$publishUrl" `
      --config.nsis.publish.provider=generic `
      "--config.nsis.publish.url=$publishUrl" `
      --config.nsisWeb.publish.provider=generic `
      "--config.nsisWeb.publish.url=$publishUrl" `
      --config.nsisWeb.appPackageUrl=null
    Assert-ExternalSuccess 'sourceのelectron-builder実行に失敗しました'
  } finally {
    Pop-Location
  }

  function Test-UpdateMetadata([System.IO.FileInfo]$MetadataFile, [bool]$Web) {
    $content = Get-Content -LiteralPath $MetadataFile.FullName -Raw -ErrorAction Stop
    if ($content -notmatch '(?m)^version:[ \t]+[^\r\n]+$' -or
      $content -notmatch '(?m)^files:[ \t]*$' -or
      $content -notmatch '(?m)^path:[ \t]+[^\r\n]+$' -or
      $content -notmatch '(?m)^sha512:[ \t]+[A-Za-z0-9+/=]+$') {
      return $false
    }
    if ($Web -and ($content -notmatch '(?m)^packages:[ \t]*$' -or
        $content -notmatch '(?m)^[ \t]+file:[ \t]+[^\r\n]+$')) {
      return $false
    }
    return $true
  }

  function Convert-YamlScalar([string]$Value) {
    $scalar = $Value.Trim()
    if (($scalar.StartsWith('"') -and $scalar.EndsWith('"')) -or
      ($scalar.StartsWith("'") -and $scalar.EndsWith("'"))) {
      return $scalar.Substring(1, $scalar.Length - 2)
    }
    return $scalar
  }

  function Get-MetadataValue([System.IO.FileInfo]$MetadataFile, [string]$Key) {
    $content = Get-Content -LiteralPath $MetadataFile.FullName -Raw -ErrorAction Stop
    $pattern = '(?m)^' + [regex]::Escape($Key) + ':[ \t]*([^\r\n]+)$'
    $matches = @([regex]::Matches($content, $pattern))
    if ($matches.Count -ne 1) {
      throw "metadataの$Keyが一意ではありません: $($MetadataFile.Name)"
    }
    return Convert-YamlScalar $matches[0].Groups[1].Value
  }

  function Find-Artifact([string]$Root, [string]$Name) {
    $matches = @(Get-ChildItem -LiteralPath $Root -File -Recurse -Force -ErrorAction Stop | Where-Object {
        $_.Name -ieq $Name -and ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0
      })
    if ($matches.Count -ne 1) {
      throw "metadataが参照するassetの一意な実fileがありません: $Name"
    }
    return $matches[0]
  }

  $metadataFiles = @(Get-ChildItem -LiteralPath $builderOutput -File -Force -ErrorAction Stop | Where-Object {
      $_.Extension -ieq '.yml' -and $_.Name -notmatch '(?i)-mac\.yml$' -and $_.Name -ine 'builder-debug.yml' -and (Test-UpdateMetadata $_ $false)
    })
  if ($metadataFiles.Count -ne 1) {
    throw 'Windows packageの通常NSIS metadataが一意ではありません'
  }
  $normalMetadata = $metadataFiles[0]
  $normalName = Get-MetadataValue $normalMetadata 'path'
  if ([string]::IsNullOrEmpty($normalName) -or $normalName.Contains('/') -or $normalName.Contains('\')) {
    throw '通常NSIS metadataのpathはbasenameでなければなりません'
  }
  $normalInstaller = Find-Artifact $builderOutput $normalName
  $normalBlockmap = Find-Artifact $builderOutput ($normalName + '.blockmap')
  $webDirectory = Join-Path $builderOutput 'nsis-web'
  Assert-Directory $webDirectory 'NSIS Web output directoryがありません' | Out-Null
  $webMetadataFiles = @(Get-ChildItem -LiteralPath $webDirectory -File -Force -ErrorAction Stop | Where-Object {
      $_.Extension -ieq '.yml' -and (Test-UpdateMetadata $_ $true)
    })
  if ($webMetadataFiles.Count -ne 1) {
    throw 'NSIS Web metadataが一意ではありません'
  }
  $webMetadata = $webMetadataFiles[0]
  $webInstallerName = Get-MetadataValue $webMetadata 'path'
  if ([string]::IsNullOrEmpty($webInstallerName) -or $webInstallerName.Contains('/') -or $webInstallerName.Contains('\')) {
    throw 'NSIS Web metadataのpathはbasenameでなければなりません'
  }
  $webMetadataContent = Get-Content -LiteralPath $webMetadata.FullName -Raw -ErrorAction Stop
  $webPackageMatches = @([regex]::Matches($webMetadataContent, '(?m)^[ \t]+file:[ \t]*([^\r\n]+)$'))
  if ($webPackageMatches.Count -ne 1) {
    throw 'NSIS Web metadataのpackageが一意ではありません'
  }
  $webPackageName = Convert-YamlScalar $webPackageMatches[0].Groups[1].Value
  if ([string]::IsNullOrEmpty($webPackageName) -or $webPackageName.Contains('/') -or $webPackageName.Contains('\')) {
    throw 'NSIS Web metadataのpackage pathはbasenameでなければなりません'
  }
  $webInstaller = Find-Artifact $webDirectory $webInstallerName
  $webPackage = Find-Artifact $webDirectory $webPackageName

  $payloadDirectory = Join-Path $releaseItem.FullName 'payload'
  $metadataDirectory = Join-Path $releaseItem.FullName 'metadata'
  New-Item -ItemType Directory -Path $payloadDirectory -ErrorAction Stop | Out-Null
  New-Item -ItemType Directory -Path $metadataDirectory -ErrorAction Stop | Out-Null
  Copy-Item -LiteralPath $normalInstaller.FullName -Destination (Join-Path $payloadDirectory $normalName) -ErrorAction Stop
  Copy-Item -LiteralPath $normalBlockmap.FullName -Destination (Join-Path $payloadDirectory ($normalName + '.blockmap')) -ErrorAction Stop
  Copy-Item -LiteralPath $webInstaller.FullName -Destination (Join-Path $payloadDirectory $webInstallerName) -ErrorAction Stop
  Copy-Item -LiteralPath $webPackage.FullName -Destination (Join-Path $payloadDirectory $webPackageName) -ErrorAction Stop
  Copy-Item -LiteralPath $normalMetadata.FullName -Destination (Join-Path $metadataDirectory $normalMetadata.Name) -ErrorAction Stop
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
