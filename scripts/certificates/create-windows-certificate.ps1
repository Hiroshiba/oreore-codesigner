#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $OutputDirectory,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $Subject,

    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 30)]
    [int] $Years
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    throw '出力先は空白だけで指定できません。'
}

try {
    $outputItem = Get-Item -LiteralPath $OutputDirectory -Force
} catch {
    throw [System.InvalidOperationException]::new('出力先の確認に失敗しました。', $_.Exception)
}

if ($outputItem -isnot [System.IO.DirectoryInfo]) {
    throw '出力先は既存のディレクトリで指定してください。'
}
if (($outputItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw '出力先にシンボリックリンクやジャンクションは指定できません。'
}
if ([System.IO.Path]::GetPathRoot($outputItem.FullName) -eq $outputItem.FullName) {
    throw 'ルートディレクトリは出力先に指定できません。'
}

$outputEntries = @(Get-ChildItem -LiteralPath $outputItem.FullName -Force)
if ($outputEntries.Count -ne 0) {
    throw '出力先は空のディレクトリでなければなりません。'
}

if ($Subject -ne $Subject.Trim()) {
    throw 'subjectの先頭または末尾に空白を指定できません。'
}
if ($Subject -notmatch '^CN=.+$') {
    throw 'subjectはCN=で始まるX.500 distinguished nameで指定してください。'
}
foreach ($character in $Subject.ToCharArray()) {
    if ([char]::IsControl($character)) {
        throw 'subjectに制御文字を指定できません。'
    }
}
try {
    $null = [System.Security.Cryptography.X509Certificates.X500DistinguishedName]::new($Subject)
} catch {
    throw [System.ArgumentException]::new('subjectがX.500 distinguished nameとして不正です。', $_.Exception)
}

$certificatePath = Join-Path -Path $outputItem.FullName -ChildPath 'certificate.cer'
$pfxPath = Join-Path -Path $outputItem.FullName -ChildPath 'certificate.pfx'
$fingerprintPath = Join-Path -Path $outputItem.FullName -ChildPath 'fingerprint.txt'
$artifactPaths = @($certificatePath, $pfxPath, $fingerprintPath)
foreach ($artifactPath in $artifactPaths) {
    if (Test-Path -LiteralPath $artifactPath) {
        throw "出力ファイルが既に存在します: $artifactPath"
    }
}

$password = Read-Host -Prompt 'PFX password' -AsSecureString
if ($password.Length -eq 0) {
    $password.Dispose()
    throw 'PFX passwordは空にできません。'
}

$tempDirectory = $null
$createdCertificate = $null
$createdCertificateThumbprint = $null
$certificateCreationStarted = $false
$publicCertificate = $null
$reimportedCertificate = $null
$operationException = $null
$cleanupExceptions = [System.Collections.Generic.List[System.Exception]]::new()
$committedOutputPaths = [System.Collections.Generic.List[string]]::new()
$commitComplete = $false

try {
    $tempDirectory = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('personal-signing-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDirectory -ErrorAction Stop | Out-Null

    $tempCertificatePath = Join-Path -Path $tempDirectory -ChildPath 'certificate.cer'
    $tempPfxPath = Join-Path -Path $tempDirectory -ChildPath 'certificate.pfx'
    $tempFingerprintPath = Join-Path -Path $tempDirectory -ChildPath 'fingerprint.txt'

    $newCertificateParameters = @{
        Subject = $Subject
        Type = 'CodeSigningCert'
        KeyAlgorithm = 'RSA'
        KeyLength = 3072
        HashAlgorithm = 'SHA256'
        KeyExportPolicy = 'Exportable'
        NotAfter = (Get-Date).AddYears($Years)
        CertStoreLocation = 'Cert:\CurrentUser\My'
        ErrorAction = 'Stop'
    }
    $certificateCreationStarted = $true
    $createdCertificate = New-SelfSignedCertificate @newCertificateParameters
    try {
        $createdCertificateThumbprint = $createdCertificate.Thumbprint.ToUpperInvariant()
    } catch {
        throw [System.InvalidOperationException]::new('生成した証明書のthumbprint取得に失敗しました。', $_.Exception)
    }
    if ([string]::IsNullOrEmpty($createdCertificateThumbprint)) {
        throw '生成した証明書のthumbprintが空です。'
    }

    Export-Certificate -Cert $createdCertificate -FilePath $tempCertificatePath -Type CERT -NoClobber -ErrorAction Stop | Out-Null
    $publicCertificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($tempCertificatePath)
    $publicEkuExtension = @($publicCertificate.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.37' }) | Select-Object -First 1
    if ($null -eq $publicEkuExtension) {
        throw '生成された証明書にEnhanced Key Usageがありません。'
    }
    $publicEnhancedKeyUsage = [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($publicEkuExtension, $false)
    $publicHasCodeSigning = @($publicEnhancedKeyUsage.EnhancedKeyUsages | Where-Object { $_.Value -eq '1.3.6.1.5.5.7.3.3' }).Count -gt 0
    if (-not $publicHasCodeSigning) {
        throw '生成された証明書にCode Signing EKUがありません。'
    }

    Export-PfxCertificate -Cert $createdCertificate -FilePath $tempPfxPath -Password $password -NoClobber -ErrorAction Stop | Out-Null
    $reimportedCertificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
        $tempPfxPath,
        $password,
        [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
    )
    if (-not $reimportedCertificate.HasPrivateKey) {
        throw 'PFXの再import後に秘密鍵を確認できません。'
    }
    $reimportedThumbprint = $reimportedCertificate.Thumbprint.ToUpperInvariant()
    if ($reimportedThumbprint -cne $createdCertificateThumbprint) {
        throw 'PFX再import後のthumbprintが一致しません。'
    }
    $sha256Fingerprint = (Get-FileHash -LiteralPath $tempCertificatePath -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
    $fingerprintText = @(
        "subject=$Subject"
        "sha1_fingerprint=$createdCertificateThumbprint"
        "sha256_fingerprint=$sha256Fingerprint"
        "validity_years=$Years"
    ) -join [Environment]::NewLine
    [System.IO.File]::WriteAllText($tempFingerprintPath, $fingerprintText + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))

    foreach ($artifactPath in $artifactPaths) {
        if (Test-Path -LiteralPath $artifactPath) {
            throw "確定前に出力ファイルが検出されました: $artifactPath"
        }
    }

    Move-Item -LiteralPath $tempCertificatePath -Destination $certificatePath -ErrorAction Stop
    [void]$committedOutputPaths.Add($certificatePath)
    Move-Item -LiteralPath $tempPfxPath -Destination $pfxPath -ErrorAction Stop
    [void]$committedOutputPaths.Add($pfxPath)
    Move-Item -LiteralPath $tempFingerprintPath -Destination $fingerprintPath -ErrorAction Stop
    [void]$committedOutputPaths.Add($fingerprintPath)
    $commitComplete = $true
} catch {
    $operationException = $_.Exception
} finally {
    if ($null -ne $publicCertificate) {
        try {
            $publicCertificate.Dispose()
        } catch {
            [void]$cleanupExceptions.Add($_.Exception)
        }
    }
    if ($null -ne $reimportedCertificate) {
        try {
            $reimportedCertificate.Dispose()
        } catch {
            [void]$cleanupExceptions.Add($_.Exception)
        }
    }

    $temporaryStore = $null
    $temporaryStoreOpened = $false
    if ($null -ne $createdCertificate) {
        try {
            $temporaryStore = New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Store -ArgumentList @('My', [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
            $temporaryStore.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
            $temporaryStoreOpened = $true
            $temporaryStore.Remove($createdCertificate)
        } catch {
            [void]$cleanupExceptions.Add($_.Exception)
        } finally {
            if ($temporaryStoreOpened) {
                try {
                    $temporaryStore.Close()
                } catch {
                    [void]$cleanupExceptions.Add($_.Exception)
                }
            }
        }
    } elseif (-not [string]::IsNullOrEmpty($createdCertificateThumbprint)) {
        try {
            Remove-Item -LiteralPath "Cert:\CurrentUser\My\$createdCertificateThumbprint" -Force -ErrorAction Stop
        } catch {
            [void]$cleanupExceptions.Add($_.Exception)
        }
    } elseif ($certificateCreationStarted) {
        [void]$cleanupExceptions.Add([System.InvalidOperationException]::new('生成した証明書をCurrentUserストアから削除するための証明書objectとthumbprintがありません。'))
    }

    if ($null -ne $createdCertificate) {
        try {
            $createdCertificate.Dispose()
        } catch {
            [void]$cleanupExceptions.Add($_.Exception)
        }
    }

    if (-not $commitComplete) {
        foreach ($committedOutputPath in $committedOutputPaths) {
            try {
                Remove-Item -LiteralPath $committedOutputPath -Force -ErrorAction Stop
            } catch {
                [void]$cleanupExceptions.Add($_.Exception)
            }
        }
    }

    if ($null -ne $tempDirectory -and (Test-Path -LiteralPath $tempDirectory)) {
        try {
            Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction Stop
        } catch {
            [void]$cleanupExceptions.Add($_.Exception)
        }
    }

    try {
        $password.Dispose()
    } catch {
        [void]$cleanupExceptions.Add($_.Exception)
    }
}

if ($null -ne $operationException -and $cleanupExceptions.Count -ne 0) {
    $allExceptions = [System.Collections.Generic.List[System.Exception]]::new()
    [void]$allExceptions.Add($operationException)
    foreach ($cleanupException in $cleanupExceptions) {
        [void]$allExceptions.Add($cleanupException)
    }
    throw [System.AggregateException]::new('証明書生成の失敗とcleanupの失敗が発生しました。', $allExceptions)
}
if ($null -ne $operationException) {
    throw [System.InvalidOperationException]::new('証明書の生成または出力に失敗しました。', $operationException)
}
if ($cleanupExceptions.Count -ne 0) {
    throw [System.AggregateException]::new('cleanupに失敗しました。', $cleanupExceptions)
}

Write-Output "証明書を生成しました: $($outputItem.FullName)"
Write-Output '生成中だけCurrentUserのMyストアに置き、PFXとCERの検証後に出力しました。'
