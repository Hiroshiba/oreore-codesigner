# 個人用証明書の生成

両スクリプトは、既存の空ディレクトリだけを出力先に受け付けます。パスワードは対話入力だけで受け取ります。

macOS:

```sh
bash scripts/certificates/create-macos-certificate.sh OUTPUT_DIRECTORY DISPLAY_NAME VALIDITY_DAYS
```

`certificate.cer`、`certificate.p12`、`fingerprint.txt` を出力します。秘密鍵は一時ディレクトリ内だけで生成し、最終出力には平文秘密鍵を残しません。`certificate.p12` だけが秘密鍵を含む成果物です。

P12 は PKCS#12 の伝統的な PBE と SHA-1 MAC で出力します。macOS の `security import` は OpenSSL 3 系が既定で使う PBES2 と SHA-256 MAC を読めず、パスワードが正しくても MAC 検証の失敗として扱います。生成後は使い捨ての keychain へ実際に取り込み、Code Signing identity を取得できることを確認します。

Windows:

```powershell
./scripts/certificates/create-windows-certificate.ps1 -OutputDirectory OUTPUT_DIRECTORY -Subject "CN=DISPLAY_NAME" -Years YEARS
```

`certificate.cer`、`certificate.pfx`、`fingerprint.txt` を出力します。証明書は生成中だけCurrentUserのMyストアに置き、PFXの再import検証後に削除します。

`fingerprint.txt` は次の固定キーを持ちます。

```text
subject=...
sha1_fingerprint=...
sha256_fingerprint=...
validity_days=...
```

Windows版の年数行は `validity_years` です。Windowsのtrust導入にはSHA-1値を使い、中央設定のfingerprintにはSHA-256値を使います。

Windowsで公開証明書をCurrentUserのRootとTrustedPublisherへ導入する場合は、SHA-1 fingerprintを完全一致で指定します。

```powershell
./scripts/certificates/install-windows-trust.ps1 -CertificatePath certificate.cer -Fingerprint SHA1_FINGERPRINT
```

登録対象は現在の利用者だけで、管理者権限は不要です。同一fingerprintはno-opとし、同名の別証明書は対象にしません。SmartScreenやSmart App Controlは変更しません。

秘密鍵を別のPCや利用者へ配布せず、P12またはPFXとパスワードは本人だけがアクセスできる保管場所に置きます。公開証明書だけを端末やリポジトリへ配布します。

CI secret用のbase64値を作る場合は、リポジトリ外のアクセス制限された一時ファイルへ出力し、その内容をログへ表示しません。

```sh
base64 < certificate.p12 | tr -d '\n' > /secure/private/p12.base64
chmod 600 /secure/private/p12.base64
```

Windowsでは管理者権限の不要な保管場所を選び、PowerShellで同じくログへ表示せずに保存します。

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes('certificate.pfx')) | Set-Content -NoNewline -Encoding ASCII -Path 'C:\secure\private\pfx.base64'
```

base64化しても秘密情報であることは変わりません。実際のsecret値をこのリポジトリや文書へ書きません。
