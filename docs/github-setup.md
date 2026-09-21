# GitHub の初期設定

この作業は中央リポジトリと対象アプリを管理する本人が行います。
秘密鍵と GitHub App の秘密情報は中央だけに置き、利用者の端末へ配布するのは公開証明書だけにします。

## GitHub App とリポジトリの保護

1. GitHub App を作成し、Repository permissions の Contents を Read and write にします。Metadata の必須権限を除き、追加の権限は不要です。
2. App のインストール先を Selected repositories にし、対象アプリのリポジトリを選びます。この選択範囲が署名・公開を許可する対象です。
3. App ID と秘密鍵を、以下の表に従って中央へ登録します。
4. 中央の既定ブランチ `main` を保護し、ワークフロー、`config/`、署名と公開の実装の変更にレビューを要求します。
5. `macos-signing` の environment を作成し、承認者を設定して、デプロイ元を `main` に限定します。

| 種類と配置先        | 名前                             | 内容                       |
| ------------------- | -------------------------------- | -------------------------- |
| Repository variable | `SIGNING_APP_ID`                 | GitHub App の数値の App ID |
| Repository secret   | `SIGNING_APP_PRIVATE_KEY`        | GitHub App の PEM 秘密鍵   |
| Repository secret   | `MACOS_CERTIFICATE_P12_BASE64`   | P12 を base64 にした値     |
| Repository secret   | `MACOS_CERTIFICATE_PASSWORD`     | P12 のパスワード           |
| Repository secret   | `WINDOWS_CERTIFICATE_PFX_BASE64` | PFX を base64 にした値     |
| Repository secret   | `WINDOWS_CERTIFICATE_PASSWORD`   | PFX のパスワード           |

取得と package のジョブは repository の App 設定を使います。macOS と Windows の署名ジョブは repository secret の証明書を参照します。
package job には対象 repository の read token と、その OS の署名 secret を渡します。公開用 write token は publish job だけが使います。

macOS と Windows の署名 secret は中央の他の workflow や job からも参照でき、`macos-signing` の承認だけでは参照を制限できません。
中央へ書き込める利用者を信頼できる管理者に限定し、`main` の保護と変更レビューを必須にします。
`macos-signing` は macOS 署名ジョブの承認に使い、同名の environment secret は置きません。Windows 署名ジョブは environment 承認を待ちません。

App 自体には Contents write が必要ですが、取得用トークンは Contents read、公開用トークンは Contents write に制限して別々に発行します。
どちらも実行時に指定したリポジトリ一つだけを対象にし、ジョブ終了時に失効させます。
ワークフローは既定ブランチ以外からの実行を拒否します。
`macos-signing` の承認者は、対象リポジトリ、タグ、取得時に固定したコミットを確認してください。

## 証明書の準備

現在は macOS と Windows の公開設定と、[macOS の公開証明書](../config/certificates/macos.cer)、[Windows の公開証明書](../config/certificates/windows.cer)が登録済みです。
以下は証明書を新たに用意する場合の手順です。

macOS と Windows の証明書を、それぞれの OS で[証明書ツール](../scripts/certificates/README.md)から作成します。
リポジトリの外に本人だけがアクセスできる空の出力先を用意し、パスワードは対話入力します。
秘密鍵を含む成果物は macOS の `certificate.p12` と Windows の `certificate.pfx` です。
これらとパスワードを安全に保管し、表の Secrets へ登録します。
base64 にしても秘密情報のため、値をログや文書へ表示しないでください。

公開証明書の fingerprint と有効期限を確認し、`config/signing.json` の `macos` と `windows` に次の公開情報を指定します。

| 設定項目          | 内容                                                                      |
| ----------------- | ------------------------------------------------------------------------- |
| `certificatePath` | 中央リポジトリ内の公開証明書への相対パス                                  |
| `fingerprint`     | SHA-256 fingerprint。64 桁の 16 進数、または各バイトを `:` で区切った形式 |
| `displayName`     | 証明書の CN に対応する署名者の表示名                                      |

`certificatePath` へ置くのは公開証明書です。
P12、PFX、平文の秘密鍵をリポジトリへ追加しないでください。
公開証明書と fingerprint の変更はレビュー対象にします。
利用者がダウンロード先とは別の信頼できる経路で fingerprint を照合できるようにしてください。
署名の成否は Secrets に登録した証明書と electron-builder の結果で判定します。
publisher、GUID、icon、entitlements などのアプリ設定は対象ソースの electron-builder 設定を使います。

## 対象アプリと Release

対象アプリが[ソースの要件](source-requirements.md)を満たすことを確認し、タグに対応する GitHub Release をあらかじめ作成します。
中央は Release を新規作成せず、タイトル、本文、タグ、draft、prerelease の設定も変更しません。
draft と prerelease に中央独自の制限はありません。
Immutable Release は変更できないため、公開先には asset を追加・置換できる Release が必要です。

実行方法と同名ファイルの扱いは[運用手順](operations.md)、端末への公開証明書の導入は[端末の初期設定](device-setup.md)を参照してください。
