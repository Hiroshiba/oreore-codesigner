#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $CertificatePath,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9A-Fa-f]{40}$')]
    [string] $Fingerprint
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($CertificatePath)) {
    throw '証明書パスは空白だけで指定できません。'
}

$expectedFingerprint = $Fingerprint.ToUpperInvariant()
try {
    $certificateItem = Get-Item -LiteralPath $CertificatePath -Force
} catch {
    throw [System.InvalidOperationException]::new('公開証明書の確認に失敗しました。', $_.Exception)
}

if ($certificateItem -isnot [System.IO.FileInfo]) {
    throw '公開証明書パスは通常ファイルで指定してください。'
}
if (($certificateItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'シンボリックリンクやジャンクションの証明書は受け付けません。'
}

$certificate = $null
$rootStore = $null
$trustedPublisherStore = $null
$rootStoreOpened = $false
$trustedPublisherStoreOpened = $false
$addedToRoot = $false
$addedToTrustedPublisher = $false

try {
    try {
        $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($certificateItem.FullName)
        if ($certificate.HasPrivateKey) {
            throw '秘密鍵を含むファイルは公開証明書として指定できません。'
        }

        $actualFingerprint = $certificate.GetCertHashString().ToUpperInvariant()
        if ($actualFingerprint -cne $expectedFingerprint) {
            throw "証明書のfingerprintが一致しません。期待値: $expectedFingerprint 実際の値: $actualFingerprint"
        }

        $ekuExtension = @($certificate.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.37' }) | Select-Object -First 1
        if ($null -eq $ekuExtension) {
            throw '証明書にEnhanced Key Usageがありません。'
        }
        $enhancedKeyUsage = [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($ekuExtension, $false)
        $hasCodeSigning = @($enhancedKeyUsage.EnhancedKeyUsages | Where-Object { $_.Value -eq '1.3.6.1.5.5.7.3.3' }).Count -gt 0
        if (-not $hasCodeSigning) {
            throw '証明書にCode Signing EKUがありません。'
        }
    } catch {
        throw [System.InvalidOperationException]::new('公開証明書の検証に失敗しました。', $_.Exception)
    }

    try {
        $storeLocation = [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser
        $rootStore = New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Store -ArgumentList @('Root', $storeLocation)
        $trustedPublisherStore = New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Store -ArgumentList @('TrustedPublisher', $storeLocation)
        $rootStore.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        $rootStoreOpened = $true
        $trustedPublisherStore.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        $trustedPublisherStoreOpened = $true

        $rootMatches = @($rootStore.Certificates | Where-Object { $_.Thumbprint.ToUpperInvariant() -ceq $expectedFingerprint })
        if ($rootMatches.Count -eq 0) {
            $rootStore.Add($certificate)
            $addedToRoot = $true
            Write-Output 'Rootへ登録しました: CurrentUser'
        } else {
            Write-Output 'Rootは同一fingerprintのため変更しません: CurrentUser'
        }

        $trustedPublisherMatches = @($trustedPublisherStore.Certificates | Where-Object { $_.Thumbprint.ToUpperInvariant() -ceq $expectedFingerprint })
        if ($trustedPublisherMatches.Count -eq 0) {
            $trustedPublisherStore.Add($certificate)
            $addedToTrustedPublisher = $true
            Write-Output 'TrustedPublisherへ登録しました: CurrentUser'
        } else {
            Write-Output 'TrustedPublisherは同一fingerprintのため変更しません: CurrentUser'
        }

        Write-Output '証明書のsubject名だけを使った代替検索は行いません。'
    } catch {
        $originalException = $_.Exception
        $rollbackExceptions = @()

        if ($addedToTrustedPublisher) {
            try {
                $trustedPublisherStore.Remove($certificate)
            } catch {
                $rollbackExceptions += $_.Exception
            }
        }
        if ($addedToRoot) {
            try {
                $rootStore.Remove($certificate)
            } catch {
                $rollbackExceptions += $_.Exception
            }
        }

        if ($rollbackExceptions.Count -ne 0) {
            $allExceptions = [System.Collections.Generic.List[System.Exception]]::new()
            [void]$allExceptions.Add($originalException)
            foreach ($rollbackException in $rollbackExceptions) {
                [void]$allExceptions.Add($rollbackException)
            }
            throw [System.AggregateException]::new('信頼ストア登録に失敗し、変更の取り消しにも失敗しました。', $allExceptions)
        }
        throw [System.InvalidOperationException]::new('CurrentUserの信頼ストア登録に失敗しました。', $originalException)
    }
} finally {
    if ($trustedPublisherStoreOpened) {
        $trustedPublisherStore.Close()
    }
    if ($rootStoreOpened) {
        $rootStore.Close()
    }
    if ($null -ne $certificate) {
        $certificate.Dispose()
    }
}
