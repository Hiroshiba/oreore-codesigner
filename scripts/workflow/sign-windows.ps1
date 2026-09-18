param(
  [Parameter(Mandatory = $true)][string]$UnsignedArchive,
  [Parameter(Mandatory = $true)][string]$PackageInputDirectory,
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

function Assert-EmptyDirectory([string]$Path, [string]$Message) {
  if (Test-Path -LiteralPath $Path) {
    Assert-Directory $Path $Message | Out-Null
    if (@(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop).Count -ne 0) {
      throw $Message
    }
    return
  }
  New-Item -ItemType Directory -Path $Path -ErrorAction Stop | Out-Null
  Assert-Directory $Path $Message | Out-Null
}

function Invoke-SafeExtract([string]$Archive, [string]$Output, [string]$CentralRoot) {
  $python = Get-Command python.exe -ErrorAction Stop
  $pythonVersion = (& $python.Source --version 2>&1 | Out-String).Trim()
  $pythonExitCode = $LASTEXITCODE
  if ($pythonExitCode -ne 0 -or $pythonVersion -notmatch '^Python 3\.(9|[1-9][0-9])\.[0-9]+$') {
    throw 'Python 3.9以上が必要です'
  }
  $extractor = Join-Path $CentralRoot 'scripts/workflow/safe-extract.py'
  Assert-RegularFile $extractor 'safe extractorがありません' | Out-Null
  & $python.Source $extractor --archive $Archive --output $Output --platform windows
  Assert-ExternalSuccess 'unsigned Windows archiveの展開に失敗しました'
}

function Find-SignTool {
  $kitRoots = [System.Collections.Generic.List[string]]::new()
  foreach ($programFiles in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    if (-not [string]::IsNullOrEmpty($programFiles)) {
      [void]$kitRoots.Add((Join-Path $programFiles 'Windows Kits/10/bin'))
    }
  }
  $candidates = [System.Collections.Generic.List[object]]::new()
  $seenPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($kitRoot in $kitRoots) {
    if (-not (Test-Path -LiteralPath $kitRoot -PathType Container)) {
      continue
    }
    foreach ($versionDirectory in @(Get-ChildItem -LiteralPath $kitRoot -Directory -Force -ErrorAction Stop | Where-Object { $_.Name -match '^10\.\d+\.\d+\.\d+$' })) {
      $binary = Join-Path $versionDirectory.FullName 'x64/signtool.exe'
      if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) {
        continue
      }
      $binaryItem = Get-Item -LiteralPath $binary -Force -ErrorAction Stop
      if (($binaryItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "SignToolがreparse pointです: $binary"
      }
      if (-not $seenPaths.Add($binaryItem.FullName)) {
        continue
      }
      [void]$candidates.Add([pscustomobject]@{
          Path = $binaryItem.FullName
          Version = [version]$versionDirectory.Name
        })
    }
  }
  $ordered = @($candidates | Sort-Object -Property Version -Descending)
  if ($ordered.Count -eq 0) {
    throw 'Windows Kitsのx64 SignToolが見つかりません'
  }
  $selectedVersion = $ordered[0].Version
  $selected = @($ordered | Where-Object { $_.Version -eq $selectedVersion })
  if ($selected.Count -ne 1) {
    throw '同じversionのx64 SignToolが複数あります'
  }
  return [string]$selected[0].Path
}

function Get-CentralPath([string]$CentralRoot, [string]$RelativePath) {
  if ($RelativePath -notmatch '^[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*$') {
    throw "中央repo内のpathが不正です: $RelativePath"
  }
  $centralFullPath = [System.IO.Path]::GetFullPath($CentralRoot)
  $candidate = [System.IO.Path]::GetFullPath((Join-Path $CentralRoot ($RelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)))
  $prefix = $centralFullPath.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  if (-not $candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "中央repo外のpathです: $RelativePath"
  }
  return $candidate
}

function Assert-CodeSigningCertificate(
  [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
  [string]$Fingerprint,
  [string]$CommonName,
  [string]$Label
) {
  $actualFingerprint = $Certificate.GetCertHashString([System.Security.Cryptography.HashAlgorithmName]::SHA256).ToUpperInvariant()
  if ($actualFingerprint -cne $Fingerprint) {
    throw "$LabelのSHA-256 fingerprintが一致しません"
  }
  $actualCommonName = $Certificate.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
  if ($actualCommonName -cne $CommonName) {
    throw "$LabelのCNが一致しません"
  }
  $ekuExtension = @($Certificate.Extensions | Where-Object { $_.Oid.Value -ceq '2.5.29.37' }) | Select-Object -First 1
  if ($null -eq $ekuExtension) {
    throw "$LabelにCode Signing EKUがありません"
  }
  $enhancedKeyUsage = [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($ekuExtension, $false)
  if (@($enhancedKeyUsage.EnhancedKeyUsages | Where-Object { $_.Value -ceq '1.3.6.1.5.5.7.3.3' }).Count -eq 0) {
    throw "$LabelにCode Signing EKUがありません"
  }
}

function New-Store([string]$Name) {
  $store = [System.Security.Cryptography.X509Certificates.X509Store]::new(
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
  $matches = @($Store.Certificates | Where-Object {
      $_.GetCertHashString([System.Security.Cryptography.HashAlgorithmName]::SHA256).ToUpperInvariant() -ceq $Fingerprint
    })
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

function Get-SignableFiles([string]$Root) {
  $signableExtensions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($extension in @('.exe', '.dll', '.node')) {
    [void]$signableExtensions.Add($extension)
  }
  $files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction Stop)
  $signableFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
  foreach ($file in $files) {
    if ($file -isnot [System.IO.FileInfo]) {
      throw "Windows payloadに通常file以外があります: $($file.FullName)"
    }
    if (($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "Windows payloadにreparse pointがあります: $($file.FullName)"
    }
    if ($signableExtensions.Contains($file.Extension)) {
      [void]$signableFiles.Add($file)
    }
  }
  $directories = @(Get-ChildItem -LiteralPath $Root -Recurse -Directory -Force -ErrorAction Stop)
  foreach ($directory in $directories) {
    if (($directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "Windows payloadにreparse pointがあります: $($directory.FullName)"
    }
  }
  return @($signableFiles)
}

function Invoke-SignTool(
  [string]$SignTool,
  [string]$Path,
  [string]$PfxPath,
  [string]$Password,
  [string]$TimestampUrl
) {
  & $SignTool sign /fd SHA256 /f $PfxPath /p $Password /tr $TimestampUrl /td SHA256 $Path
  Assert-ExternalSuccess "Windows code署名に失敗しました: $Path"
}

function Assert-AuthenticodeSigner(
  [string]$SignTool,
  [string]$Path,
  [string]$ExpectedFingerprint,
  [string]$ExpectedPublisher
) {
  & $SignTool verify /pa /all /q $Path
  Assert-ExternalSuccess "Authenticode署名検証に失敗しました: $Path"
  $signature = Get-AuthenticodeSignature -LiteralPath $Path
  if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or $null -eq $signature.SignerCertificate) {
    throw "Authenticode署名が有効ではありません: $Path"
  }
  $certificate = $signature.SignerCertificate
  $actualFingerprint = $certificate.GetCertHashString([System.Security.Cryptography.HashAlgorithmName]::SHA256).ToUpperInvariant()
  $actualPublisher = $certificate.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
  if ($actualFingerprint -cne $ExpectedFingerprint -or $actualPublisher -cne $ExpectedPublisher) {
    throw "Authenticode signerが設定と一致しません: $Path"
  }
}

function Invoke-Builder([string]$Project, [string]$Prepackaged, [string]$CentralRoot) {
  Push-Location $CentralRoot
  try {
    & pnpm exec electron-builder --projectDir $Project --config (Join-Path $Project 'electron-builder.yml') --prepackaged $Prepackaged --publish never
    Assert-ExternalSuccess 'electron-builderに失敗しました'
  } finally {
    Pop-Location
  }
}

function Invoke-CreatePackageProject(
  [string]$CentralRoot,
  [string]$PackageInput,
  [string]$Target,
  [string]$RepositoryName,
  [string]$ReleaseTag,
  [string]$OutputDirectory
) {
  Push-Location $CentralRoot
  try {
    & pnpm cli create-package-project --package-input-directory $PackageInput --target $Target --repository $RepositoryName --tag $ReleaseTag --output-directory $OutputDirectory
    Assert-ExternalSuccess "$Target package projectの生成に失敗しました"
  } finally {
    Pop-Location
  }
}

function Get-TargetOutputs([string]$DistDirectory, [string]$Target) {
  Assert-Directory $DistDirectory 'electron-builderのdistがありません' | Out-Null
  $entries = @(Get-ChildItem -LiteralPath $DistDirectory -Force -ErrorAction Stop)
  if ($entries.Count -eq 0) {
    throw "$Targetの出力がありません"
  }
  foreach ($entry in $entries) {
    if ($entry -isnot [System.IO.FileInfo] -or ($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "$Targetの出力に通常file以外があります: $($entry.FullName)"
    }
    if ($entry.Length -eq 0) {
      throw "$Targetの出力が空です: $($entry.Name)"
    }
  }
  $executables = @($entries | Where-Object { $_.Extension -ieq '.exe' })
  if ($executables.Count -ne 1) {
    throw "$Targetのexe出力が一件ではありません"
  }
  $result = [ordered]@{ Installer = $executables[0] }
  if ($Target -ceq 'windows-nsis') {
    $blockmaps = @($entries | Where-Object { $_.Extension -ieq '.blockmap' })
    $metadata = @($entries | Where-Object { $_.Extension -ieq '.yml' })
    if ($blockmaps.Count -ne 1 -or $metadata.Count -ne 1) {
      throw '通常NSISの必須出力が揃っていません'
    }
    $result.Blockmap = $blockmaps[0]
    $result.Metadata = $metadata[0]
  } elseif ($Target -ceq 'windows-nsis-web') {
    $packages = @($entries | Where-Object { $_.Extension -ieq '.7z' })
    if ($packages.Count -ne 1) {
      throw 'NSIS Webの必須出力が揃っていません'
    }
    $result.Package = $packages[0]
  } else {
    throw "未知のWindows targetです: $Target"
  }
  $known = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($value in $result.Values) {
    [void]$known.Add($value.FullName)
  }
  if ($known.Count -ne $entries.Count) {
    throw "$Targetの出力に想定外fileがあります"
  }
  return [pscustomobject]$result
}

function Copy-ReleaseFile([System.IO.FileInfo]$Source, [string]$DestinationDirectory) {
  $destination = Join-Path $DestinationDirectory $Source.Name
  if (Test-Path -LiteralPath $destination) {
    throw "release outputが既に存在します: $destination"
  }
  Copy-Item -LiteralPath $Source.FullName -Destination $destination -ErrorAction Stop
  Assert-RegularFile $destination 'release出力が通常fileではありません' | Out-Null
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$centralRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptRoot '../..'))
$packageInputPath = Join-Path $PackageInputDirectory 'package-input.json'
Assert-Directory $centralRoot '中央repoのpathが不正です' | Out-Null
Assert-RegularFile $UnsignedArchive 'unsigned Windows archiveが通常fileではありません' | Out-Null
Assert-Directory $PackageInputDirectory 'package-input directoryが通常directoryではありません' | Out-Null
Assert-RegularFile $packageInputPath 'package-input.jsonが通常fileではありません' | Out-Null
if ($Repository -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9_.-]*[A-Za-z0-9])?/[A-Za-z0-9](?:[A-Za-z0-9_.-]*[A-Za-z0-9])?$') {
  throw 'repositoryはowner/name形式でなければなりません'
}
if ($Tag.Length -eq 0 -or $Tag.Contains("`n") -or $Tag.Contains("`r")) {
  throw 'tagが不正です'
}
if ($ReleaseOutputDirectory.Length -eq 0) {
  throw 'release output directoryが空です'
}

$signingPath = Join-Path $centralRoot 'config/signing.json'
Assert-RegularFile $signingPath 'signing設定が通常fileではありません' | Out-Null
$signing = Get-Content -LiteralPath $signingPath -Raw -ErrorAction Stop | ConvertFrom-Json
$windowsSigning = $signing.windows
if ($windowsSigning.configured -ne $true) {
  throw 'Windows signingが未設定です'
}
$certificateRelativePath = [string]$windowsSigning.certificatePath
$certificatePath = Get-CentralPath $centralRoot $certificateRelativePath
Assert-RegularFile $certificatePath 'Windows公開証明書が通常fileではありません' | Out-Null
$expectedFingerprint = ([string]$windowsSigning.fingerprint).Replace(':', '').Replace(' ', '').ToUpperInvariant()
$expectedPublisher = [string]$windowsSigning.displayName
$timestampUrl = [string]$windowsSigning.timestampUrl
if ($expectedFingerprint -notmatch '^[0-9A-F]{64}$' -or $expectedPublisher.Length -eq 0 -or $timestampUrl -notmatch '^https://') {
  throw 'Windows signing設定が不正です'
}

$releaseRoot = [System.IO.Path]::GetFullPath($ReleaseOutputDirectory)
if (Test-Path -LiteralPath $releaseRoot) {
  Assert-Directory $releaseRoot 'release output directoryが通常directoryではありません' | Out-Null
  if (@(Get-ChildItem -LiteralPath $releaseRoot -Force -ErrorAction Stop).Count -ne 0) {
    throw 'release outputは空のdirectoryでなければなりません'
  }
} else {
  New-Item -ItemType Directory -Path $releaseRoot -ErrorAction Stop | Out-Null
}
$payloadDirectory = Join-Path $releaseRoot 'payload'
$metadataDirectory = Join-Path $releaseRoot 'metadata'
Assert-EmptyDirectory $payloadDirectory 'release/payloadが空の通常directoryではありません'
Assert-EmptyDirectory $metadataDirectory 'release/metadataが空の通常directoryではありません'

$temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('central-sign-windows-' + [Guid]::NewGuid().ToString('N'))
$pfxPath = Join-Path $temporaryDirectory 'certificate.pfx'
$sourceRoot = Join-Path $temporaryDirectory 'source'
$normalProject = Join-Path $temporaryDirectory 'normal-project'
$webProject = Join-Path $temporaryDirectory 'web-project'
$normalDist = Join-Path $normalProject 'dist'
$webDist = Join-Path $webProject 'dist'
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
$pfxBase64 = $null
$pfxPasswordPlain = $null

try {
  New-Item -ItemType Directory -Path $temporaryDirectory -ErrorAction Stop | Out-Null
  Invoke-SafeExtract $UnsignedArchive $sourceRoot $centralRoot
  $pfxBase64 = $env:WINDOWS_CERTIFICATE_PFX_BASE64
  $pfxPasswordPlain = $env:WINDOWS_CERTIFICATE_PASSWORD
  $env:WINDOWS_CERTIFICATE_PFX_BASE64 = $null
  $env:WINDOWS_CERTIFICATE_PASSWORD = $null
  if ([string]::IsNullOrEmpty($pfxBase64) -or [string]::IsNullOrEmpty($pfxPasswordPlain)) {
    throw 'Windows signing secretが空です'
  }
  try {
    [System.IO.File]::WriteAllBytes($pfxPath, [System.Convert]::FromBase64String($pfxBase64))
  } catch {
    throw [System.InvalidOperationException]::new('Windows signing PFXの復元に失敗しました', $_.Exception)
  }
  $publicCertificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($certificatePath)
  if ($publicCertificate.HasPrivateKey) {
    throw 'Windows公開証明書に秘密鍵が含まれています'
  }
  Assert-CodeSigningCertificate $publicCertificate $expectedFingerprint $expectedPublisher 'Windows公開証明書'

  $securePassword = ConvertTo-SecureString $pfxPasswordPlain -AsPlainText -Force
  $pfxCertificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
    $pfxPath,
    $securePassword,
    [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
  )
  if (-not $pfxCertificate.HasPrivateKey) {
    throw 'PFXに秘密鍵がありません'
  }
  Assert-CodeSigningCertificate $pfxCertificate $expectedFingerprint $expectedPublisher 'PFX'

  $rootStore = New-Store 'Root'
  $rootStoreOpened = $true
  $publisherStore = New-Store 'TrustedPublisher'
  $publisherStoreOpened = $true
  $addedToRoot = Add-TrustCertificate $rootStore $publicCertificate $expectedFingerprint
  $addedToPublisher = Add-TrustCertificate $publisherStore $publicCertificate $expectedFingerprint

  $signTool = Find-SignTool
  $payloadEntries = @(Get-ChildItem -LiteralPath $sourceRoot -Force -ErrorAction Stop)
  if ($payloadEntries.Count -ne 1 -or -not $payloadEntries[0].PSIsContainer -or ($payloadEntries[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'unsigned Windows archiveは直下一件のdirectoryでなければなりません'
  }
  $payloadPath = $payloadEntries[0].FullName
  $signFiles = @(Get-SignableFiles $payloadPath)
  if ($signFiles.Count -eq 0) {
    throw '署名対象のWindows codeがありません'
  }
  foreach ($file in $signFiles) {
    Invoke-SignTool $signTool $file.FullName $pfxPath $pfxPasswordPlain $timestampUrl
    Assert-AuthenticodeSigner $signTool $file.FullName $expectedFingerprint $expectedPublisher
  }

  $env:CSC_LINK = $pfxPath
  $env:CSC_KEY_PASSWORD = $pfxPasswordPlain
  $env:WIN_CSC_LINK = $pfxPath
  $env:WIN_CSC_KEY_PASSWORD = $pfxPasswordPlain
  $env:CSC_IDENTITY_AUTO_DISCOVERY = 'false'
  Invoke-CreatePackageProject $centralRoot $PackageInputDirectory 'windows-nsis' $Repository $Tag $normalProject
  Invoke-CreatePackageProject $centralRoot $PackageInputDirectory 'windows-nsis-web' $Repository $Tag $webProject
  Invoke-Builder $normalProject $payloadPath $centralRoot
  Invoke-Builder $webProject $payloadPath $centralRoot

  $normalOutputs = Get-TargetOutputs $normalDist 'windows-nsis'
  $webOutputs = Get-TargetOutputs $webDist 'windows-nsis-web'
  foreach ($installer in @($normalOutputs.Installer, $webOutputs.Installer)) {
    Assert-AuthenticodeSigner $signTool $installer.FullName $expectedFingerprint $expectedPublisher
  }

  Copy-ReleaseFile $normalOutputs.Installer $payloadDirectory
  Copy-ReleaseFile $normalOutputs.Blockmap $payloadDirectory
  Copy-ReleaseFile $webOutputs.Installer $payloadDirectory
  Copy-ReleaseFile $webOutputs.Package $payloadDirectory
  Copy-ReleaseFile $normalOutputs.Metadata $metadataDirectory
} catch {
  $operationException = $_.Exception
} finally {
  $env:WINDOWS_CERTIFICATE_PFX_BASE64 = $null
  $env:WINDOWS_CERTIFICATE_PASSWORD = $null
  $env:CSC_LINK = $null
  $env:CSC_KEY_PASSWORD = $null
  $env:WIN_CSC_LINK = $null
  $env:WIN_CSC_KEY_PASSWORD = $null
  $env:CSC_IDENTITY_AUTO_DISCOVERY = $null
  if ($publisherStoreOpened -and $null -ne $publisherStore) {
    if ($addedToPublisher -and $null -ne $publicCertificate) {
      try { Remove-AddedCertificate $publisherStore $publicCertificate } catch { [void]$cleanupExceptions.Add($_.Exception) }
    }
    try { $publisherStore.Close() } catch { [void]$cleanupExceptions.Add($_.Exception) }
  }
  if ($rootStoreOpened -and $null -ne $rootStore) {
    if ($addedToRoot -and $null -ne $publicCertificate) {
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
  $pfxBase64 = $null
  $pfxPasswordPlain = $null
}

if ($null -ne $operationException -and $cleanupExceptions.Count -ne 0) {
  $allExceptions = [System.Collections.Generic.List[System.Exception]]::new()
  [void]$allExceptions.Add($operationException)
  foreach ($cleanupException in $cleanupExceptions) {
    [void]$allExceptions.Add($cleanupException)
  }
  throw [System.AggregateException]::new('Windows署名処理とcleanupの両方に失敗しました', $allExceptions)
}
if ($null -ne $operationException) {
  throw [System.InvalidOperationException]::new('Windows署名処理に失敗しました', $operationException)
}
if ($cleanupExceptions.Count -ne 0) {
  throw [System.AggregateException]::new('Windows signing cleanupに失敗しました', $cleanupExceptions)
}
