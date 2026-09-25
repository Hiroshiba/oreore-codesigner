# ソースの要件

対象は、リポジトリのルートで pnpm と electron-builder を使う Electron アプリです。
公開対象の範囲は GitHub App の Selected repositories で管理し、実行時に `repository` と `tag` を指定します。
ソースのコード、依存関係、ビルド hook は管理者が信頼する前提です。
手動更新とアプリ内更新のどちらも対象とし、ビルド、署名、成果物の要件は共通です。

## ビルドに必要なファイル

| ファイル                                              | 必要な内容                                                                                                            |
| ----------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| `package.json`                                        | `name`、中央が採用するSemVerの `version`、exact `packageManager`、`build` script、electron-builder 26.16.1 の依存関係 |
| `pnpm-lock.yaml`                                      | `pnpm install --frozen-lockfile` が通る依存関係                                                                       |
| `electron-builder.yml` または `electron-builder.yaml` | `appId`、`productName`、macOS と Windows の対象設定                                                                   |

`packageManager` は `pnpm@10.30.2` のようにアプリが使う pnpm の exact spec を固定します。
`electron-builder` は `devDependencies` にだけ 26.16.1 を exact に指定し、`dependencies`、`optionalDependencies`、`peerDependencies` には配置せず、`scripts.build` を必須にします。
`electron-builder.yml` と `electron-builder.yaml` はどちらか一つだけを置き、`extends` と `package.json` の `build` フィールドは使いません。
root、`mac`、`win`、`nsis`、`nsisWeb` とその target の `publish` は設定しません。

root `package.json` の `version` が唯一の version 正本です。
stable version の channel は `latest`、prerelease は最初の identifier です。
たとえば `1.2.3-foo-mac.1` は `foo-mac` になります。

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

中央は出力先、x64、macOS ZIP、通常 NSIS、NSIS Web、root と platform の `forceCodeSigning`、現在の channel の更新 metadata、root の generic publish URL を CLI で指定します。
公開先、対象 tag、署名必須、version と channel は中央が所有し、source の app 設定を再構築しません。
`asar`、`asarUnpack`、`extraResources`、アプリ固有の hook、appId、productName、GUID、publisher、icon、entitlements、artifactName、NSIS 設定はソース側の builder が直接反映します。
ビルド時点で署名用秘密鍵や公開用 token をアプリへ埋め込まないでください。

## 署名と成果物

macOS のジョブは repository secret の P12 を `CSC_LINK`、パスワードを `CSC_KEY_PASSWORD` として electron-builder へ渡します。

Windows のジョブは PFX とパスワードを `WIN_CSC_LINK`、`WIN_CSC_KEY_PASSWORD` として electron-builder へ渡します。
署名 hash、publisher、GUID、NSIS 設定はソース側の設定を使います。

macOS は ZIP、外部 blockmap、channel に対応する `*-mac.yml` の更新 metadata を、Windows は通常 NSIS の installer、外部 blockmap、channel に対応する root の `.yml` と、NSIS Web metadataを基準に選ぶ installer、`.nsis.7z` package を生成できなければなりません。
通常 NSIS の更新 metadata は通常 installer を参照します。
余分なbuilder出力は無視し、artifactNameが下位directoryを含む場合はmetadata参照名から再帰的に一意な実fileを選んでRelease assetのbasenameへ集約します。

## 更新方式

対象アプリの README に、手動更新とアプリ内更新のどちらを採用するかと、利用者向けの更新手順を記載します。
手動更新の場合、`electron-updater` の組み込みは必須ではありません。
中央の CLI は更新方式や更新クライアントの実装を検査しないため、採用した方式に沿って[実機検証](verification.md)を行います。

すでにアプリ内更新を使うクライアントを配布している場合は、手動更新へ切り替える前に、既存クライアントの更新先、利用者への案内、設定と利用者データを保持する移行手順を確認します。
初回の署名付き配布で更新元がない場合は、導入を確認したうえで「更新未確認」と記録し、次のバージョンで更新を検証します。

### 手動更新

macOS はアプリを終了し、新しい ZIP を展開して既存のアプリを置き換えます。
Windows は新しい通常 NSIS インストーラーで既存アプリへ再導入します。
どちらも更新後の起動、バージョン、設定と利用者データの保持を確認します。

### アプリ内更新

この方式を採用するアプリは、`electron-updater` と更新先を組み込み、起動後の確認、ダウンロード、再起動時の適用を既存 UI とエラー処理へ接続します。
梱包時の generic publish URL は実行時の repository と tag の Release を指します。
この URL だけでは旧版から新しい tag を発見できないため、旧版が新タグの Release URL へ到達する経路をアプリ側で用意し、実機で確認します。
GitHub App の秘密鍵や中央の公開用 token をアプリへ埋め込んではいけません。

macOS の更新は ZIP、Windows の更新は通常 NSIS を使います。
Windows は `disableWebInstaller=true` を設定し、更新クライアントが NSIS Web を取得しないようにします。
NSIS Web の installer と 7z package は初回導入用です。

更新対象はインストール済みより大きいアプリバージョンにします。
差分更新の成功と、差分取得に失敗した場合の全量更新は、[実機検証](verification.md)で確認してください。
