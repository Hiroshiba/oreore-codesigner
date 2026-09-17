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
ビルドジョブへ App の秘密鍵や公開用トークンを渡しません。

公開証明書の情報は `config/signing.json`、アプリの許可一覧は `config/apps.json` に置きます。
秘密情報はこれらのファイルに書きません。

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
両ツールとも `certificate.cer`、`certificate.p12`、`fingerprint.txt` を出力します。
macOS はさらに `certificate.pem` と `private-key.pem` を出力します。
`certificate.p12` は秘密鍵を含み、macOS の `private-key.pem` は暗号化されていない秘密鍵です。
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

初期状態ではアプリ一覧と証明書設定が空です。
この状態で公開を試しても動作しません。
実在のアプリを登録する前に[アプリ側の契約](app-contract.md)と[実機検証](verification.md)を確認してください。

## アプリ側で準備するもの

対象タグに対応する GitHub Release を、アプリ側のリポジトリへあらかじめ作成します。
中央ワークフローは Release を新規作成せず、タイトル、本文、タグを編集しません。
Release が存在しない場合は公開できません。

正式版は新しいバージョンとタグで公開します。
同名 asset の上書きを前提にしないでください。
Immutable Release を使用する場合は、その Release がまだ asset を追加できる段階で中央の公開を完了する運用が必要です。
変更できない Release を解除して公開を続ける処理はありません。

アプリの登録と実行は[運用手順](operations.md)、利用者の端末設定は[端末の初期設定](device-setup.md)を参照してください。
