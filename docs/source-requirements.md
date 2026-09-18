# ソースの要件

対象は、リポジトリのルートで pnpm と electron-builder を使う Electron アプリです。
公開対象の範囲は GitHub App の Selected repositories で管理し、実行時に `repository` と `tag` を指定します。
アプリごとの中央用設定ファイルをソースへ追加する必要はありません。

## ビルドに必要なファイル

| ファイル                                              | 必要な内容                                                                     |
| ----------------------------------------------------- | ------------------------------------------------------------------------------ |
| `package.json`                                        | `name`、SemVer の `version`、版を固定した `packageManager`、`build` スクリプト |
| `pnpm-lock.yaml`                                      | `pnpm install --frozen-lockfile` が通る依存関係                                |
| `electron-builder.yml` または `electron-builder.yaml` | `appId`、`productName` を含む設定をどちらか一つ                                |

`packageManager` は `pnpm@10.30.2` のようにアプリが使う pnpm の版を固定します。
アプリ側の `electron-builder` と `electron-updater` の版は、各アプリの依存関係で管理します。
中央の依存バージョンへ統一する必要はありません。
builder 設定は YAML にまとめ、`package.json` の `build` フィールドとの二重定義は使えません。

中央は固定したソースから依存をインストールし、`pnpm run build` の後にソース側の electron-builder を `--dir --x64 --publish never` で実行します。
macOS は `.app` 一つ、Windows は `win-unpacked` 一つを署名前の成果物として取得します。
両 OS とも x64 を対象にします。
`asar`、`asarUnpack`、`extraResources`、アプリ固有のフックはソース側の builder がこの段階で反映します。
ビルドには署名鍵、GitHub App の秘密鍵、取得・公開用トークンを使えません。

ソースは Git metadata を含まない archive で渡されます。
`SOURCE_DATE_EPOCH` には取得したコミットの日時を渡します。

## 署名と梱包へ引き継ぐ設定

中央はソース設定とアプリ本体を照合し、必要な静的値だけを `package-input.json` へ抽出します。
これは実行中の受け渡し用ファイルで、アプリ側で作成するものではありません。
署名環境では中央のコードを実行し、ソース側のスクリプトや builder フックは実行しません。

共通の `name`、`version`、`appId`、`productName` に加え、対応する `artifactName` を引き継ぎます。
macOS は entitlements と署名に必要な静的設定、Windows は実行ファイル名、NSIS の GUID、インストール方法やショートカットなどの静的設定を使います。
ソースの builder 設定全体を署名環境へ渡すことはありません。
entitlements はソース内の通常ファイルを指定してください。

Windows の `publisherName` を指定する場合は、中央の `config/signing.json` の `windows.displayName` と一致させます。
通常 NSIS と NSIS Web の GUID を指定する場合も、両者で一致させます。
更新を継続するアプリは、macOS の bundle ID と署名証明書、Windows の appId、GUID、publisher を維持してください。

## アプリ内更新

アプリ側へ `electron-updater` と更新先を組み込み、起動後の確認、ダウンロード、再起動時の適用をアプリの既存 UI とエラー処理へ接続します。
梱包した本体に必要な `app-update.yml` を含め、実際に公開する Release を取得できることを確認してください。
中央の `--prepackaged` による梱包は、本体内の更新先を変更しません。
GitHub App の秘密鍵や中央の公開用トークンをアプリへ埋め込んではいけません。

macOS の更新は ZIP、Windows の更新は通常 NSIS を使います。
Windows は `disableWebInstaller=true` を設定し、更新クライアントが NSIS Web を取得しないようにします。
NSIS Web が取得するパッケージの URL は、実行時に指定した repository と tag の Release を指します。
端末から Release asset を取得できることを、アプリの配布先と認証方式に合わせて確認してください。

更新対象はインストール済みより大きいアプリバージョンにします。
タグの参照先や同名ファイルを更新するだけでは、アプリが新しいバージョンと認識するとは限りません。
差分更新の成功と、差分取得に失敗した場合の全量更新は、[実機検証](verification.md)で確認してください。
