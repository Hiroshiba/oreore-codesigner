# ソースの要件

対象は、リポジトリのルートで pnpm と electron-builder を使う Electron アプリです。
公開対象の範囲は GitHub App の Selected repositories で管理し、実行時に `repository` と `tag` を指定します。
ソースのコード、依存関係、ビルド hook は管理者が信頼する前提です。

## ビルドに必要なファイル

| ファイル | 必要な内容 |
| --- | --- |
| `package.json` | `name`、中央が採用するSemVerの `version`、exact `packageManager`、`build` script、electron-builder 26.16.1 の依存関係 |
| `pnpm-lock.yaml` | `pnpm install --frozen-lockfile` が通る依存関係 |
| `electron-builder.yml` または `electron-builder.yaml` | `appId`、`productName`、macOS と Windows の対象設定 |

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

ソースの README に、手動更新とアプリ内更新のどちらを提供するかと、利用者の更新手順を明記します。
ビルド、署名、成果物と更新 metadata の整合要件は、どちらの方式にも適用します。
手動更新でも blockmap と更新 metadata は生成・公開されますが、アプリ内更新の実装や動作を示すものではありません。
GitHub App の秘密鍵や中央の公開用 token をアプリへ埋め込んではいけません。

手動更新では、macOS は新版の ZIP でアプリを置換し、Windows は新版の通常 NSIS を実行します。
両 OS で配布元と署名を人手で確認し、旧版からの手動再導入後に version、起動、設定と利用者データの保持を[実機検証](verification.md)で確認してから利用者へ公開します。
初回署名版で旧版がない場合は更新検証を未確認として記録し、導入・起動の成功を更新成功とは扱いません。
同じアプリの自動更新クライアントを過去に配布していた場合は、手動更新へ切り替える前に旧版の配布履歴と更新経路を確認します。
旧版が新しい Release の metadata を読める場合があるため、既存利用者への影響と移行手順を確認してください。

アプリ内更新を提供する場合は、アプリ側へ `electron-updater` と更新先を組み込み、起動後の確認、ダウンロード、再起動時の適用を既存 UI とエラー処理へ接続します。
梱包時の generic publish URL は実行時の repository と tag の Release を指し、新しい tag の自動発見は保証しません。
旧版が新版を取得できる更新先の設定と更新経路を確認してください。
macOS の更新は ZIP、Windows の更新は通常 NSIS を使います。
Windows は `disableWebInstaller=true` を設定し、更新クライアントが NSIS Web を取得しないようにします。
NSIS Web の installer と 7z package は初回導入用です。

更新対象はインストール済みより大きいアプリバージョンにします。
旧版からのアプリ内更新、差分更新の成功、差分取得に失敗した場合の全量更新、改変・期待しない署名への拒否は、[実機検証](verification.md)で確認してから利用者へ公開してください。
