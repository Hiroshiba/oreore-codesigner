# 端末の初期設定

この手順は、本人が管理する端末で本人が実施します。
署名済みアプリを導入する前に、配布元と公開証明書の fingerprint を確認してください。
端末へ入れるのは公開証明書だけです。
P12、PFX、秘密鍵、CI のパスワードを利用者へ配布しません。

公開証明書の SHA-256 fingerprint は、ダウンロードした証明書自身の表示だけで確認を終えず、レビュー済みの `config/signing.json` など、信頼できる経路の値と照合します。
Windows の証明書画面に出る SHA-1 の thumbprint と SHA-256 fingerprint は別の値です。
値が一致しない場合は導入を中断し、配布元を確認してください。

## macOS

公開証明書 `certificate.cer` の SHA-256 fingerprint は、ターミナルで次のように表示できます。
出力値を信頼できる経路の値と照合してから、以下へ進みます。

```sh
openssl x509 -inform DER -in certificate.cer -noout -fingerprint -sha256
```

1. 公開証明書の fingerprint、有効期限、発行先を確認します。
2. キーチェーンアクセスを開き、ファイルメニューから `certificate.cer` を読み込みます。取り込んだ証明書を開き、対象の証明書であることをもう一度確認します。証明書を信頼する操作を求められた場合は、対象の証明書と用途を確認して本人が判断します。
3. ブラウザーで対象 Release の DMG をダウンロードします。quarantine 属性を残したまま開き、アプリを Applications へ移します。
4. アプリを起動します。自己署名だけでは Gatekeeper の標準許可にならないため、警告が出る場合があります。
5. 配布元と署名を確認したうえで利用する場合は、macOS が提供する個別アプリの許可操作を行います。操作場所は macOS のバージョンにより異なり、システム設定の「プライバシーとセキュリティ」で案内されることがあります。
6. 起動と主要機能を確認し、次のバージョンへ ZIP 更新できることを[検証手順](verification.md)で確認します。

証明書の取り込みと、初回起動時の Gatekeeper の許可は別です。
証明書を取り込むだけで同じ証明書のすべてのアプリが自動的に起動を許可されるとは扱いません。
quarantine 属性を削除して検証を省略したり、Gatekeeper 全体を無効化したりしないでください。

`experimental/macos-system-policy-profile/` は、`com.apple.systempolicy.rule` による証明書単位の許可を調べるための実験です。
現行 macOS の実機で成立を確認していないため、この標準手順ではインストールしません。
構文が正しいプロファイルを作成できても、OS がそのルールを採用することの証明にはなりません。

## Windows

公開証明書 `certificate.cer` は DER 形式なので、PowerShell で計算したファイルの SHA-256 が中央設定の fingerprint に対応します。

```powershell
Get-FileHash -LiteralPath .\certificate.cer -Algorithm SHA256
```

1. 公開証明書の fingerprint、有効期限、発行先を確認します。
2. `scripts/certificates/install-windows-trust.ps1` を使い、公開証明書を Root と TrustedPublisher へ登録します。`-CertificatePath` に `certificate.cer`、`-Scope` に `CurrentUser` または `LocalMachine`、`-Fingerprint` に確認済みの SHA-1 fingerprint を指定します。
3. ブラウザーで対象 Release の WebSetup をダウンロードします。Mark of the Web を残したまま、デジタル署名の署名者と証明書を確認します。
4. WebSetup を実行し、初回導入を完了します。WebSetup が参照するダウンロード対象にもアクセスできることを確認します。
5. 次のバージョンへの更新が通常 NSIS を使うことを、更新ログとダウンロードしたファイルで確認します。

`CurrentUser` は現在の利用者だけ、`LocalMachine` は端末全体を対象にします。
`LocalMachine` への登録には管理者権限が必要です。
スクリプトの `-Fingerprint` は `fingerprint.txt` の `sha1_fingerprint` に対応する、区切りなしの 40 桁の値です。
中央の `config/signing.json` に登録する SHA-256 の値とは取り違えないでください。
同じ fingerprint がすでに登録されていれば再登録せず、表示名だけを使った証明書の代替検索は行いません。

Root と TrustedPublisher への登録は Authenticode の信頼を設定するためのものです。
SmartScreen の評価とは別のため、登録後も警告が残ることがあります。
Smart App Control が強制されている端末では、この自己署名方式は対象外です。
導入のために SmartScreen、Smart App Control、Windows の保護設定全体を無効化しないでください。

PowerShell の `Unblock-File` やファイルのプロパティでブロックを解除してから試すと、ブラウザーで取得した初回導入の検証になりません。
まず Mark of the Web を保持した状態で結果を記録します。

## 追加の端末と証明書更新

追加の PC では、同じ公開証明書の fingerprint を改めて照合し、その OS の初期設定と初回導入を繰り返します。
既存端末から秘密鍵をコピーする必要はありません。
新しい端末で発生した OS の警告も検証記録に残してください。

有効期限が近づいた証明書は、期限前に中央の管理者が更新計画を立てます。
同じ表示名で作成し直しても、別の証明書や秘密鍵は同じ署名として扱われるとは限りません。
特に macOS は同じ bundle ID、証明書、秘密鍵を使う更新経路を前提にしているため、証明書の置換後も既存アプリが更新できると仮定しないでください。

新しい公開証明書を別経路で照合し、端末へ導入したうえで、旧版からの更新を検証します。
移行に再インストールが必要な場合は、アプリの設定や利用者データを保持できる手順も確認します。
旧証明書の削除は、それを使うアプリが残っていないことを確認してから本人が行います。
更新の管理側の作業は[運用手順](operations.md)を参照してください。
