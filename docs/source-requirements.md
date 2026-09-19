# ソースの要件

対象は、リポジトリのルートで pnpm と electron-builder を使う Electron アプリです。
公開対象の範囲は GitHub App の Selected repositories で管理し、実行時に `repository` と `tag` を指定します。
ソースのコード、依存関係、ビルド hook は管理者が信頼する前提です。

## ビルドに必要なファイル

| ファイル | 必要な内容 |
| --- | --- |
| `package.json` | `name`、SemVer の `version`、版を固定した `packageManager`、`build` script、electron-builder の依存関係 |
| `pnpm-lock.yaml` | `pnpm install --frozen-lockfile` が通る依存関係 |
| `electron-builder.yml` または `electron-builder.yaml` | `appId`、`productName`、macOS と Windows の対象設定 |

`packageManager` は `pnpm@10.30.2` のようにアプリが使う pnpm の exact spec を固定します。
アプリ側の `electron-builder` と `electron-updater` の版は各アプリの依存関係で管理します。
builder 設定を YAML に置く場合は、`package.json` の `build` フィールドとの二重定義を使いません。

両 OS のジョブは同じ `source_sha` を checkout し、ソースのルートで次を実行します。

```text
pnpm install --frozen-lockfile
pnpm run build
```

その後、ソース側の electron-builder を次の相当する引数で実行します。

```text
electron-builder --mac zip --x64 --publish never
electron-builder --win nsis nsis-web --x64 --publish never
```

中央は出力先、root と platform の `forceCodeSigning`、更新 metadataを現在のchannelだけにする設定、root と platform・target の generic publish URL だけを CLI で上書きします。
macOSのZIP targetには `zip.publish` も指定するため、source側のtarget publishより中央の公開先が優先されます。
NSIS Web の `appPackageUrl` は中央の target publish 設定から package 名を補うため `null` に上書きします。
`asar`、`asarUnpack`、`extraResources`、アプリ固有の hook、appId、version、productName、GUID、publisher、icon、entitlements、artifactName、NSIS 設定はソース側の builder が直接反映します。
ビルド時点で署名用秘密鍵や公開用 token をアプリへ埋め込まないでください。

## 署名と成果物

macOS のジョブは environment secret の P12 を `CSC_LINK`、パスワードを `CSC_KEY_PASSWORD` として electron-builder へ渡します。
中央の `config/signing.json` で macOS の表示名を設定している場合は `CSC_NAME` にも使い、自己署名 identity を選びます。

Windows のジョブは PFX とパスワードを `WIN_CSC_LINK`、`WIN_CSC_KEY_PASSWORD` として electron-builder へ渡します。
署名 hash、publisher、GUID、NSIS 設定はソース側の設定を使います。

macOS は ZIP、blockmap、channel に対応する `*-mac.yml` の更新 metadata を、Windows は通常 NSIS の installer、blockmap、channel に対応する root の `.yml` と、NSIS Web metadataを基準に選ぶ installer、`.nsis.7z` package を生成できなければなりません。
通常 NSIS の更新 metadata は通常 installer を参照します。
余分なbuilder出力は無視し、artifactNameが下位directoryを含む場合はmetadata参照名から再帰的に一意な実fileを選んでRelease assetのbasenameへ集約します。

## アプリ内更新

アプリ側へ `electron-updater` と更新先を組み込み、起動後の確認、ダウンロード、再起動時の適用を既存 UI とエラー処理へ接続します。
梱包時の generic publish URL は実行時の repository と tag の Release を指します。
GitHub App の秘密鍵や中央の公開用 token をアプリへ埋め込んではいけません。

macOS の更新は ZIP、Windows の更新は通常 NSIS を使います。
Windows は `disableWebInstaller=true` を設定し、更新クライアントが NSIS Web を取得しないようにします。
NSIS Web の installer と 7z package は初回導入用です。

更新対象はインストール済みより大きいアプリバージョンにします。
差分更新の成功と、差分取得に失敗した場合の全量更新は、[実機検証](verification.md)で確認してください。
