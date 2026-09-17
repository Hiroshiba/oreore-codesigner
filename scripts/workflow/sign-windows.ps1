param(
  [Parameter(Mandatory = $true)][string]$CentralRoot,
  [Parameter(Mandatory = $true)][string]$ContractPath,
  [Parameter(Mandatory = $true)][string]$SourceManifestPath,
  [Parameter(Mandatory = $true)][string]$UnsignedArchive,
  [Parameter(Mandatory = $true)][string]$AssetsDirectory,
  [Parameter(Mandatory = $true)][string]$AssetsArchive,
  [Parameter(Mandatory = $true)][string]$NormalProject,
  [Parameter(Mandatory = $true)][string]$WebProject
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
}

function Assert-EmptyDirectory([string]$Path) {
  if (Test-Path -LiteralPath $Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item -isnot [System.IO.DirectoryInfo] -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "出力先が通常directoryではありません: $Path"
    }
    if (@(Get-ChildItem -LiteralPath $Path -Force).Count -ne 0) {
      throw "出力先は空でなければなりません: $Path"
    }
  } else {
    New-Item -ItemType Directory -Path $Path -ErrorAction Stop | Out-Null
  }
}

function Get-CentralPath([string]$RelativePath) {
  if ($RelativePath -notmatch '^[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*$') {
    throw "中央repo内のpathが不正です: $RelativePath"
  }
  $centralFull = [System.IO.Path]::GetFullPath($CentralRoot)
  $candidate = [System.IO.Path]::GetFullPath((Join-Path $CentralRoot ($RelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)))
  $prefix = $centralFull.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  if (-not $candidate.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
    throw "中央repo外のpathです: $RelativePath"
  }
  return $candidate
}

function New-Store([string]$Name) {
  $store = New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Store -ArgumentList @(
    $Name,
    [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser
  )
  $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
  return $store
}

function Add-TrustCertificate(
  [System.Security.Cryptography.X509Certificates.X509Store]$Store,
  [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
  [string]$Fingerprint
) {
  $matches = @($Store.Certificates | Where-Object { $_.GetCertHashString([System.Security.Cryptography.HashAlgorithmName]::SHA256).ToUpperInvariant() -ceq $Fingerprint })
  if ($matches.Count -eq 0) {
    $Store.Add($Certificate)
    return $true
  }
  return $false
}

function Remove-AddedCertificate(
  [System.Security.Cryptography.X509Certificates.X509Store]$Store,
  [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate
) {
  $Store.Remove($Certificate)
}

function Invoke-Builder([string]$Project, [string]$Prepackaged, [string]$Central) {
  Push-Location $Central
  try {
    & pnpm exec electron-builder --projectDir $Project --config (Join-Path $Project 'electron-builder.yml') --prepackaged $Prepackaged --publish never
    Assert-ExternalSuccess 'electron-builderに失敗しました'
  } finally {
    Pop-Location
  }
}

function Set-WebPackageUrl([string]$Project, [string]$Url) {
  $configPath = Join-Path $Project 'electron-builder.yml'
  Assert-RegularFile $configPath 'WebSetup package projectがありません'
  $contents = [System.IO.File]::ReadAllText($configPath)
  $escapedUrl = $Url.Replace("'", "''")
  $marker = 'nsisWeb:'
  $markerIndex = $contents.IndexOf($marker, [System.StringComparison]::Ordinal)
  if ($markerIndex -lt 0) {
    throw 'WebSetup package projectのnsisWeb設定がありません'
  }
  $lineStart = $markerIndex + $marker.Length
  $remaining = $contents.Substring($lineStart)
  if ($remaining.StartsWith("`r`n", [System.StringComparison]::Ordinal)) {
    $lineBreak = "`r`n"
  } elseif ($remaining.StartsWith("`n", [System.StringComparison]::Ordinal)) {
    $lineBreak = "`n"
  } else {
    throw 'WebSetup package projectの改行を解析できません'
  }
  $insertAt = $lineStart + $lineBreak.Length
  $updated = $contents.Insert($insertAt, "  appPackageUrl: '$escapedUrl'$lineBreak")
  [System.IO.File]::WriteAllText($configPath, $updated, [System.Text.UTF8Encoding]::new($false))
  if (-not [System.IO.File]::ReadAllText($configPath).Contains("  appPackageUrl: '$escapedUrl'")) {
    throw 'WebSetup package URLの設定に失敗しました'
  }
}

function Assert-PackageProjects([string]$Normal, [string]$Web, [string]$Url) {
  $normalConfig = [System.IO.File]::ReadAllText((Join-Path $Normal 'electron-builder.yml'))
  $webConfig = [System.IO.File]::ReadAllText((Join-Path $Web 'electron-builder.yml'))
  $escapedUrl = $Url.Replace("'", "''")
  if ($normalConfig.Contains('publishAutoUpdate')) {
    throw '通常NSIS package projectにWeb用publish設定があります'
  }
  if ($webConfig -notmatch '(?m)^    publishAutoUpdate: false\r?$') {
    throw 'WebSetup package projectのpublishAutoUpdateが無効ではありません'
  }
  if (-not $webConfig.Contains("  appPackageUrl: '$escapedUrl'")) {
    throw 'WebSetup package projectのappPackageUrlがcanonicalではありません'
  }
}

if (-not (Test-Path -LiteralPath $CentralRoot -PathType Container)) {
  throw '中央repoのpathが不正です'
}
foreach ($inputPath in @($ContractPath, $SourceManifestPath, $UnsignedArchive)) {
  Assert-RegularFile $inputPath '入力pathが通常fileではありません'
}
Assert-EmptyDirectory $AssetsDirectory
Assert-EmptyDirectory $NormalProject
Assert-EmptyDirectory $WebProject

$pfxBase64 = $env:WINDOWS_CERTIFICATE_PFX_BASE64
$pfxPasswordPlain = $env:WINDOWS_CERTIFICATE_PASSWORD
if ([string]::IsNullOrEmpty($pfxBase64) -or [string]::IsNullOrEmpty($pfxPasswordPlain)) {
  throw 'Windows signing secretが空です'
}

$contract = Get-Content -LiteralPath $ContractPath -Raw | ConvertFrom-Json
$sourceManifest = Get-Content -LiteralPath $SourceManifestPath -Raw | ConvertFrom-Json
if ($sourceManifest.appId -ne $contract.appId -or $sourceManifest.repository -ne $contract.repository -or $sourceManifest.tag -ne $contract.tag -or
    $sourceManifest.configDigest -ne $contract.configDigest -or $sourceManifest.sourceSha -notmatch '^[0-9a-fA-F]{40}$') {
  throw 'source manifestとrelease contractが一致しません'
}
$signing = Get-Content -LiteralPath (Join-Path $CentralRoot 'config/signing.json') -Raw | ConvertFrom-Json
if ($signing.windows.configured -ne $true) {
  throw 'Windows signingが未設定です'
}
$certificatePath = Get-CentralPath ([string]$signing.windows.certificatePath)
Assert-RegularFile $certificatePath 'Windows公開証明書が通常fileではありません'
$expectedFingerprint = ([string]$signing.windows.fingerprint).Replace(':', '').ToUpperInvariant()
$displayName = [string]$signing.windows.displayName
$timestampUrl = [string]$signing.windows.timestampUrl
if ($expectedFingerprint -notmatch '^[0-9A-F]{64}$' -or $timestampUrl -notmatch '^https://') {
  throw 'Windows signing設定が不正です'
}

$temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('central-sign-windows-' + [Guid]::NewGuid().ToString('N'))
$pfxPath = Join-Path $temporaryDirectory 'certificate.pfx'
$sourceRoot = Join-Path $temporaryDirectory 'source'
$normalDist = Join-Path $NormalProject 'dist'
$webDist = Join-Path $WebProject 'dist'
$operationException = $null
$cleanupExceptions = [System.Collections.Generic.List[System.Exception]]::new()
$rootStore = $null
$publisherStore = $null
$rootStoreOpened = $false
$publisherStoreOpened = $false
$addedToRoot = $false
$addedToPublisher = $false
$publicCertificate = $null
$pfxCertificate = $null
$securePassword = $null
$signTool = $null

try {
  New-Item -ItemType Directory -Path $temporaryDirectory -ErrorAction Stop | Out-Null
  [System.IO.File]::WriteAllBytes($pfxPath, [System.Convert]::FromBase64String($pfxBase64))
  $publicCertificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($certificatePath)
  if ($publicCertificate.HasPrivateKey) {
    throw '公開証明書に秘密鍵が含まれています'
  }
  $actualFingerprint = $publicCertificate.GetCertHashString([System.Security.Cryptography.HashAlgorithmName]::SHA256).ToUpperInvariant()
  if ($actualFingerprint -cne $expectedFingerprint) {
    throw "Windows公開証明書のSHA-256 fingerprintが一致しません: $actualFingerprint"
  }
  if ($publicCertificate.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) -cne $displayName) {
    throw 'Windows公開証明書のpublisherNameが一致しません'
  }
  $ekuExtension = @($publicCertificate.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.37' }) | Select-Object -First 1
  if ($null -eq $ekuExtension) {
    throw 'Windows公開証明書にCode Signing EKUがありません'
  }
  $enhancedKeyUsage = [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($ekuExtension, $false)
  if (@($enhancedKeyUsage.EnhancedKeyUsages | Where-Object { $_.Value -eq '1.3.6.1.5.5.7.3.3' }).Count -eq 0) {
    throw 'Windows公開証明書にCode Signing EKUがありません'
  }

  $securePassword = ConvertTo-SecureString $pfxPasswordPlain -AsPlainText -Force
  $pfxCertificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
    $pfxPath,
    $securePassword,
    [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
  )
  if (-not $pfxCertificate.HasPrivateKey) {
    throw 'PFXに秘密鍵がありません'
  }
  if ($pfxCertificate.GetCertHashString([System.Security.Cryptography.HashAlgorithmName]::SHA256).ToUpperInvariant() -cne $expectedFingerprint) {
    throw 'PFXのSHA-256 fingerprintが設定と一致しません'
  }
  if ($pfxCertificate.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) -cne $displayName) {
    throw 'PFXのpublisherNameが設定と一致しません'
  }

  $rootStore = New-Store 'Root'
  $rootStoreOpened = $true
  $publisherStore = New-Store 'TrustedPublisher'
  $publisherStoreOpened = $true
  $addedToRoot = Add-TrustCertificate $rootStore $publicCertificate $expectedFingerprint
  $addedToPublisher = Add-TrustCertificate $publisherStore $publicCertificate $expectedFingerprint

  $signTool = (Get-Command signtool.exe -ErrorAction Stop).Source
  New-Item -ItemType Directory -Path $sourceRoot -ErrorAction Stop | Out-Null
  tar -xf $UnsignedArchive -C $sourceRoot
  Assert-ExternalSuccess 'unsigned Windows archiveの展開に失敗しました'
  $payloadEntries = @(Get-ChildItem -LiteralPath $sourceRoot -Force)
  if ($payloadEntries.Count -ne 1 -or -not $payloadEntries[0].PSIsContainer -or ($payloadEntries[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'unsigned Windows archiveは直下一件のdirectoryでなければなりません'
  }
  $payloadPath = $payloadEntries[0].FullName
  $signFiles = @(Get-ChildItem -LiteralPath $payloadPath -Recurse -File -Force | Where-Object { $_.Extension.ToLowerInvariant() -in @('.exe', '.dll', '.node') })
  if ($signFiles.Count -eq 0) {
    throw '署名対象のWindows codeがありません'
  }
  foreach ($file in $signFiles) {
    & $signTool sign /fd SHA256 /f $pfxPath /p $pfxPasswordPlain /tr $timestampUrl /td SHA256 $file.FullName
    Assert-ExternalSuccess "Windows code署名に失敗しました: $($file.Name)"
  }
  foreach ($file in $signFiles) {
    & $signTool verify /pa /all /q $file.FullName
    Assert-ExternalSuccess "Windows code署名検証に失敗しました: $($file.Name)"
  }

  $env:CSC_LINK = $pfxPath
  $env:CSC_KEY_PASSWORD = $pfxPasswordPlain
  $env:WIN_CSC_LINK = $pfxPath
  $env:WIN_CSC_KEY_PASSWORD = $pfxPasswordPlain
  Push-Location $CentralRoot
  try {
    & pnpm exec tsx src/cli.ts create-package-project --contract $ContractPath --target windows-nsis --output-directory $NormalProject
    Assert-ExternalSuccess '通常NSIS package projectの生成に失敗しました'
    & pnpm exec tsx src/cli.ts create-package-project --contract $ContractPath --target windows-nsis-web --output-directory $WebProject
    Assert-ExternalSuccess 'WebSetup package projectの生成に失敗しました'
  } finally {
    Pop-Location
  }

  $version = [string]$contract.version
  $artifactName = [string]$contract.application.identity.artifactName
  $architecture = [string]$contract.application.windows.architecture
  $channel = [string]$contract.application.release.channel
  $packageName = [string]$contract.application.packageName
  $sanitizedPackageName = [regex]::Replace($packageName, '[\\/:*?"<>|]', '')
  $sanitizedPackageName = [regex]::Replace($sanitizedPackageName, '^\.+$', '')
  $sanitizedPackageName = [regex]::Replace($sanitizedPackageName, '[. ]+$', '')
  if ([string]::IsNullOrEmpty($sanitizedPackageName) -or $sanitizedPackageName -match '^(con|prn|aux|nul|com[0-9]|lpt[0-9])(?:\..*)?$') {
    throw 'packageNameからWeb package filenameを生成できません'
  }
  if ($sanitizedPackageName.Length -gt 255) {
    $sanitizedPackageName = $sanitizedPackageName.Substring(0, 255)
  }
  $normalName = "$artifactName-Setup-$version.exe"
  $normalBlockmapName = "$normalName.blockmap"
  $webSetupName = "$artifactName-WebSetup-$version.exe"
  $webPackageName = "$sanitizedPackageName-$version-$architecture.nsis.7z"
  $metadataName = "$channel.yml"
  $webPackageUrl = "https://github.com/$($contract.repository)/releases/download/$([Uri]::EscapeDataString([string]$contract.tag))/$([Uri]::EscapeDataString($webPackageName))"
  Set-WebPackageUrl $WebProject $webPackageUrl
  Assert-PackageProjects $NormalProject $WebProject $webPackageUrl

  Invoke-Builder $NormalProject $payloadPath $CentralRoot
  Invoke-Builder $WebProject $payloadPath $CentralRoot

  foreach ($expected in @(
      (Join-Path $normalDist $normalName),
      (Join-Path $normalDist $normalBlockmapName),
      (Join-Path $normalDist $metadataName),
      (Join-Path $webDist $webSetupName),
      (Join-Path $webDist $webPackageName)
    )) {
    Assert-RegularFile $expected "Windows package assetがありません: $expected"
  }
  foreach ($installer in @(
      (Join-Path $normalDist $normalName),
      (Join-Path $webDist $webSetupName)
    )) {
    & $signTool verify /pa /all /q $installer
    Assert-ExternalSuccess "Windows installer署名検証に失敗しました: $installer"
  }
  Copy-Item -LiteralPath (Join-Path $normalDist $normalName) -Destination (Join-Path $AssetsDirectory $normalName) -Force
  Copy-Item -LiteralPath (Join-Path $normalDist $normalBlockmapName) -Destination (Join-Path $AssetsDirectory $normalBlockmapName) -Force
  Copy-Item -LiteralPath (Join-Path $normalDist $metadataName) -Destination (Join-Path $AssetsDirectory $metadataName) -Force
  Copy-Item -LiteralPath (Join-Path $webDist $webSetupName) -Destination (Join-Path $AssetsDirectory $webSetupName) -Force
  Copy-Item -LiteralPath (Join-Path $webDist $webPackageName) -Destination (Join-Path $AssetsDirectory $webPackageName) -Force
  tar -cf $AssetsArchive -C $AssetsDirectory .
  Assert-ExternalSuccess 'Windows signed assets archiveの作成に失敗しました'
  if (-not (Test-Path -LiteralPath $AssetsArchive -PathType Leaf)) {
    throw 'Windows signed assets archiveがありません'
  }
} catch {
  $operationException = $_.Exception
} finally {
  $env:CSC_LINK = $null
  $env:CSC_KEY_PASSWORD = $null
  $env:WIN_CSC_LINK = $null
  $env:WIN_CSC_KEY_PASSWORD = $null
  if ($publisherStoreOpened -and $null -ne $publisherStore) {
    if ($addedToPublisher) {
      try { Remove-AddedCertificate $publisherStore $publicCertificate } catch { [void]$cleanupExceptions.Add($_.Exception) }
    }
    try { $publisherStore.Close() } catch { [void]$cleanupExceptions.Add($_.Exception) }
  }
  if ($rootStoreOpened -and $null -ne $rootStore) {
    if ($addedToRoot) {
      try { Remove-AddedCertificate $rootStore $publicCertificate } catch { [void]$cleanupExceptions.Add($_.Exception) }
    }
    try { $rootStore.Close() } catch { [void]$cleanupExceptions.Add($_.Exception) }
  }
  if ($null -ne $pfxCertificate) {
    try { $pfxCertificate.Dispose() } catch { [void]$cleanupExceptions.Add($_.Exception) }
  }
  if ($null -ne $publicCertificate) {
    try { $publicCertificate.Dispose() } catch { [void]$cleanupExceptions.Add($_.Exception) }
  }
  if ($null -ne $securePassword) {
    try { $securePassword.Dispose() } catch { [void]$cleanupExceptions.Add($_.Exception) }
  }
  if (Test-Path -LiteralPath $pfxPath) {
    try { Remove-Item -LiteralPath $pfxPath -Force -ErrorAction Stop } catch { [void]$cleanupExceptions.Add($_.Exception) }
  }
  if (Test-Path -LiteralPath $temporaryDirectory) {
    try { Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction Stop } catch { [void]$cleanupExceptions.Add($_.Exception) }
  }
  $env:WINDOWS_CERTIFICATE_PFX_BASE64 = $null
  $env:WINDOWS_CERTIFICATE_PASSWORD = $null
  $pfxBase64 = $null
  $pfxPasswordPlain = $null
}

if ($null -ne $operationException -and $cleanupExceptions.Count -ne 0) {
  $allExceptions = [System.Collections.Generic.List[System.Exception]]::new()
  [void]$allExceptions.Add($operationException)
  foreach ($cleanupException in $cleanupExceptions) { [void]$allExceptions.Add($cleanupException) }
  throw [System.AggregateException]::new('Windows署名処理とcleanupの両方に失敗しました', $allExceptions)
}
if ($null -ne $operationException) {
  throw [System.InvalidOperationException]::new('Windows署名処理に失敗しました', $operationException)
}
if ($cleanupExceptions.Count -ne 0) {
  throw [System.AggregateException]::new('Windows signing cleanupに失敗しました', $cleanupExceptions)
}
