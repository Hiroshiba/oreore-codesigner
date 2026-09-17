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

$createdCertificate = $null
$publicCertificate = $null
$createdCertificateThumbprint = $null

try {
    $createdCertificate = New-SelfSignedCertificate `
        -Subject $Subject `
        -Type CodeSigningCert `
        -KeyAlgorithm RSA `
        -KeyLength 3072 `
        -HashAlgorithm SHA256 `
        -KeyExportPolicy Exportable `
        -NotAfter (Get-Date).AddYears($Years) `
        -CertStoreLocation 'Cert:\CurrentUser\My'

    $createdCertificateThumbprint = $createdCertificate.Thumbprint.ToUpperInvariant()

    Export-Certificate `
        -Cert $createdCertificate `
        -FilePath $certificatePath `
        -Type CERT `
        -NoClobber | Out-Null

    $publicCertificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($certificatePath)
    $ekuExtension = @($publicCertificate.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.37' }) | Select-Object -First 1
    if ($null -eq $ekuExtension) {
        throw '生成された証明書にEnhanced Key Usageがありません。'
    }
    $enhancedKeyUsage = [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($ekuExtension, $false)
    $hasCodeSigning = @($enhancedKeyUsage.EnhancedKeyUsages | Where-Object { $_.Value -eq '1.3.6.1.5.5.7.3.3' }).Count -gt 0
    if (-not $hasCodeSigning) {
        throw '生成された証明書にCode Signing EKUがありません。'
    }

    Export-PfxCertificate `
        -Cert $createdCertificate `
        -FilePath $pfxPath `
        -Password $password `
        -NoClobber | Out-Null

    $sha256Fingerprint = (Get-FileHash -LiteralPath $certificatePath -Algorithm SHA256).Hash.ToUpperInvariant()
    $fingerprintText = @(
        "subject=$Subject"
        "sha1_fingerprint=$createdCertificateThumbprint"
        "sha256_fingerprint=$sha256Fingerprint"
        "validity_years=$Years"
    ) -join [Environment]::NewLine
    [System.IO.File]::WriteAllText($fingerprintPath, $fingerprintText + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))

    Write-Output "証明書を生成しました: $($outputItem.FullName)"
    Write-Output '生成中だけCurrentUserのMyストアに置き、PFXとCERの出力後に削除しました。'
} catch {
    throw [System.InvalidOperationException]::new('証明書の生成または出力に失敗しました。', $_.Exception)
} finally {
    if ($null -ne $publicCertificate) {
        $publicCertificate.Dispose()
    }
    if ($null -ne $createdCertificate) {
        if ([string]::IsNullOrEmpty($createdCertificateThumbprint)) {
            throw '生成した証明書のthumbprintを取得できなかったため、CurrentUserストアから削除できません。'
        }
        Remove-Item -LiteralPath "Cert:\CurrentUser\My\$createdCertificateThumbprint" -Force
        $createdCertificate.Dispose()
    }
    $password.Dispose()
}
