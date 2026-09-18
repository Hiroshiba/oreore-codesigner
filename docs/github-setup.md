# GitHub の初期設定

この作業は中央リポジトリと対象アプリを管理する本人が行います。
秘密鍵と GitHub App の秘密情報は中央リポジトリだけに置きます。
アプリ側のリポジトリには公開用トークンや署名鍵を登録しません。

## GitHub App とリポジトリの保護

1. GitHub App を作成し、Repository permissions の Contents を Read and write にします。Metadata の必須権限を除き、Issues、Pull requests、Actions などの権限は追加しません。
2. App のインストール先を Selected repositories にし、公開対象のアプリだけを選択します。新しいアプリを追加するときも選択範囲を明示的に増やします。
3. App ID と秘密鍵を中央リポジトリへ登録します。秘密鍵の内容をログ、設定ファイル、Release asset に載せないでください。
4. 中央の既定ブランチを保護し、ワークフロー、`config/`、署名と公開の実装の変更にレビューを要求します。CODEOWNERS でこれらの所有者を指定します。
5. 署名と公開に使う protected environment には承認者とデプロイ可能なブランチを設定します。署名鍵と公開権限を使う前に、対象アプリ、タグ、固定されたコミットを確認します。

App 自体は Contents write を持ちますが、ソース取得用トークンは Contents read に制限して発行します。
公開用トークンは Contents write にし、どちらもその実行の対象リポジトリ一つに限定します。
発行には SHA 固定した公式の `actions/create-github-app-token` を使い、ジョブ終了時にトークンを失効させます。
トークンはソース取得と公開のそれぞれ直前に発行し、公開承認やビルドの待ち時間には持ち越しません。
ビルドジョブへ App の秘密鍵や公開用トークンを渡しません。

公開証明書の情報は `config/signing.json`、アプリの許可一覧は `config/apps.json` に置きます。
秘密情報はこれらのファイルに書きません。

中央リポジトリの Settings から、次の名前で登録します。
名前は [.github/workflows/sign-release.yml](../.github/workflows/sign-release.yml) と一致させてください。

| 種類と配置先                            | 名前                             | 内容                                 |
| --------------------------------------- | -------------------------------- | ------------------------------------ |
| Repository variable                     | `SIGNING_APP_ID`                 | GitHub App の数値の App ID           |
| Repository secret                       | `SIGNING_APP_PRIVATE_KEY`        | GitHub App の PEM 秘密鍵             |
| `macos-signing` の environment secret   | `MACOS_CERTIFICATE_P12_BASE64`   | `certificate.p12` を base64 にした値 |
| `macos-signing` の environment secret   | `MACOS_CERTIFICATE_PASSWORD`     | P12 のパスワード                     |
| `windows-signing` の environment secret | `WINDOWS_CERTIFICATE_PFX_BASE64` | `certificate.pfx` を base64 にした値 |
| `windows-signing` の environment secret | `WINDOWS_CERTIFICATE_PASSWORD`   | PFX のパスワード                     |

Environment は `macos-signing`、`windows-signing`、`release-publish` の三つを作成します。
署名の二つには表の Secrets を置き、`release-publish` は公開前の承認に使います。
公開ジョブは repository に置いた `SIGNING_APP_ID` と `SIGNING_APP_PRIVATE_KEY` を参照するため、`release-publish` への同名設定の複製は不要です。
ソース取得ジョブも repository の App 設定を参照しますが、署名用 environment にはアクセスしません。
各 environment のデプロイ元を既定ブランチに制限し、承認者を設定してください。
ワークフロー自身も、既定ブランチ以外からの dispatch を拒否します。

base64 の作成方法は[証明書ツールの説明](../scripts/certificates/README.md)を参照してください。
base64 にしても秘密情報のため、値を端末のログや文書へ表示しないでください。

## 証明書の準備

macOS と Windows の証明書は別々に作成します。
作成ツールは `scripts/certificates/create-macos-certificate.sh` と `scripts/certificates/create-windows-certificate.ps1` です。
リポジトリの外に本人だけがアクセスできる空のディレクトリを用意し、それぞれの OS の対話端末から実行します。
次のパス、表示名、有効期間は自分の値へ置き換えてください。

```sh
bash scripts/certificates/create-macos-certificate.sh /path/to/empty/macos-certificate "Personal App Signing" 3650
```

```powershell
./scripts/certificates/create-windows-certificate.ps1 -OutputDirectory C:\path\to\empty\windows-certificate -Subject "CN=Personal App Signing" -Years 10
```

パスワードは対話入力します。
macOS は `certificate.cer`、`certificate.pem`、`certificate.p12`、`fingerprint.txt` を出力します。
Windows は `certificate.cer`、`certificate.pfx`、`fingerprint.txt` を出力します。
秘密鍵を含む最終成果物は macOS の `certificate.p12` と Windows の `certificate.pfx` です。
macOS の平文秘密鍵は作成用の一時ディレクトリで扱い、最終出力に `private-key.pem` は残しません。
これらの出力ディレクトリをリポジトリへ追加したり、共有ストレージへ公開したりしないでください。
作成に使った秘密鍵と、CI へ登録するパスワード付きの秘密鍵ファイルは、本人だけが取り出せる場所へ保管します。
端末へ配布するのは公開証明書だけです。

公開証明書の fingerprint と有効期限を確認し、中央の公開設定に登録します。
fingerprint を載せる設定変更はレビュー対象にします。
証明書のダウンロード先とは別に、信頼できる経路で fingerprint を確認できるようにしてください。
証明書の実体を差し替える際は、Secrets と公開設定の対応も更新します。

`config/signing.json` の `macos` と `windows` をそれぞれ設定します。
初期値の `configured: false` を `true` にし、次の公開情報を追加します。

| 設定項目          | 内容                                                                                            |
| ----------------- | ----------------------------------------------------------------------------------------------- |
| `certificatePath` | 中央リポジトリ内の公開証明書への相対パス                                                        |
| `fingerprint`     | `fingerprint.txt` の `sha256_fingerprint`。64 桁の 16 進数、または各バイトを `:` で区切った形式 |
| `displayName`     | 対象の署名証明書を識別する表示名                                                                |
| `timestampUrl`    | Windows の署名で使う HTTPS の timestamp server。Windows 側だけに設定する                        |

公開証明書は `certificatePath` の場所へ保存します。
このパスへ P12、PFX、秘密鍵を置かないでください。
macOS の `displayName` は P12 内の leaf 証明書の CN に合わせます。
Windows の `displayName` は証明書の publisher と、各アプリの `windows.publisherName` に一致させます。

初期状態ではアプリ一覧と証明書設定が空です。
この状態で公開を試しても動作しません。
実在のアプリを登録する前に[アプリ側の契約](app-contract.md)と[実機検証](verification.md)を確認してください。

## アプリ側で準備するもの

対象タグに対応する GitHub Release を、アプリ側のリポジトリへあらかじめ作成します。
中央ワークフローは Release を新規作成せず、タイトル、本文、タグを編集しません。
Release が存在しない場合は公開できません。
公開ジョブは draft Release を受け付けません。
`latest` は通常の公開済み Release、`beta` と `dev` は公開済みの prerelease にします。

正式版は新しいバージョンとタグで公開します。
同名 asset の上書きを前提にしないでください。
Immutable Release へ新しい asset を追加する運用には対応していません。
draft へ asset を追加してから Release を公開する処理も実装していないため、中央から新規公開する先には変更可能な Release が必要です。
変更できない Release を解除して公開を続ける処理はありません。

アプリの登録と実行は[運用手順](operations.md)、利用者の端末設定は[端末の初期設定](device-setup.md)を参照してください。
