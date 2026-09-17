# アプリ側の契約

中央へ登録する前に、対象アプリ自身がこの契約を満たす必要があります。
中央は任意のリポジトリや任意のコマンドをワークフロー入力から受け取りません。
対象リポジトリ、ビルド方法、配布設定は `config/apps.json` で管理します。

`applications` オブジェクトのキーが、ワークフロー入力の `app_id` です。
小文字の kebab-case で指定し、Electron アプリの `identity.appId` とは区別します。
各アプリの設定に必要な項目は次のとおりです。

| 設定項目                                                          | 内容                                                           |
| ----------------------------------------------------------------- | -------------------------------------------------------------- |
| `repository`                                                      | 取得と公開の対象を `owner/name` で指定する                     |
| `workingDirectory`                                                | ソース内の作業ディレクトリ。ルートなら `.` を指定する          |
| `packageName`                                                     | 対象の `package.json` の `name` と一致させる                   |
| `pnpmVersion`                                                     | ソースの `packageManager` と一致する exact version             |
| `buildScripts.macos`、`buildScripts.windows`                      | `package.json` にある、署名なしでアプリ本体を作るスクリプト名  |
| `identity.appId`、`identity.productName`                          | 配布するアプリの識別子と表示名                                 |
| `macos.runner`、`macos.architecture`                              | macOS の runner と `x64` または `arm64`                        |
| `macos.entitlements`、`macos.entitlementsInherit`                 | 中央リポジトリ内の entitlements ファイルへの相対パス           |
| `windows.runner`、`windows.architecture`                          | Windows の runner と `x64`                                     |
| `windows.executableName`、`windows.guid`、`windows.publisherName` | 実行ファイル名、NSIS GUID、証明書に対応する publisher 名       |
| `release.tagStrategy`                                             | `versioned` とタグの `prefix`、または `rolling` と固定の `tag` |
| `release.channel`                                                 | `latest`、`beta`、`dev` のいずれか                             |
| `release.assetPolicy`                                             | `append-only` または `replaceable`                             |

`versioned` は `latest` または `beta` と組み合わせ、`append-only` にします。
`rolling` は `dev` と `replaceable` にします。
`versioned` のタグは `prefix` と `package.json` のバージョンを連結した文字列に完全一致させます。
例えば `prefix: "v"` とバージョン `1.2.3` ならタグは `v1.2.3` です。
`latest` に prerelease version は使えず、`beta` は `1.2.3-beta.1` のように先頭の prerelease 識別子を `beta` にします。
macOS の runner は `macos-14` または `macos-15`、Windows は `windows-2022` または `windows-2025` です。
同じリポジトリと作業ディレクトリの組み合わせ、`identity.appId`、Windows GUID を重複登録できません。

## ビルドと配布設定

ソースのルートにある `package.json` の `packageManager` を `pnpm@<exact version>` に固定し、ルートの `pnpm-lock.yaml` をコミットします。
`electron-builder` は `26.16.1`、`electron-updater` は `6.8.9` を範囲記号なしで指定します。
対象の `workingDirectory` にある `package.json` で、`electron-updater` は `dependencies` に置きます。
`electron-builder` は `dependencies` と `devDependencies` のどちらでも指定できます。
再現性のため、CI で使う版とアプリが要求する版を揃えてください。

ビルドスクリプトは署名鍵、公開用トークン、開発端末にしかないファイルを使わずに実行できる必要があります。
ビルドはアプリ本体を作るところまでにし、署名と Release 公開は中央に任せます。
`CENTRAL_PREPACKAGED_DIR` は署名前のアプリ本体を受け渡すためのディレクトリです。
中央から指定されたパスを使い、ビルド元の絶対パスを成果物へ埋め込まないようにします。

macOS は初回導入用 DMG と更新用 ZIP を作れる構成にします。
同じ bundle ID、証明書、秘密鍵を継続して使います。
アプリ本体だけでなく、Framework、Helper、ネイティブモジュールなどの内部コードにも同じ証明書で署名します。
既存の entitlements がある場合は中央登録時にも保持し、署名後の起動とアプリ固有機能を実機で確認してください。

Windows は初回導入用 WebSetup と、更新用の通常 NSIS を作れる構成にします。
両者で appId、NSIS GUID、publisherName を揃え、更新で変更しません。
初回導入用 WebSetup がダウンロードするパッケージも Release set に含めます。
更新メタデータが WebSetup を参照しないことを確認してください。
`publisherName` の照合は証明書の fingerprint 固定とは異なります。
同じ表示名を持つ別の証明書が端末で信頼されている場合も、必ず拒否されるとは扱いません。

パッケージ内に `app-update.yml` が必要です。
GitHub の公開先が対象アプリのリポジトリを指し、公開する channel と更新クライアントの設定が一致していることを確認します。
端末の WebSetup と更新クライアントから Release asset を取得できることも必要です。
認証が必要な配布先は、クライアントの認証方式を別途設計して検証します。
中央の GitHub App の秘密鍵や公開用トークンをアプリへ埋め込んではいけません。
手作業で生成する場合も、実際に梱包されたファイルを検査してください。
中央が生成する配布ファイル、blockmap、更新メタデータは同じバージョンで揃えます。

## 更新処理の組み込み

アプリのメインプロセスで、起動後に更新を確認します。
最小限の接続例は次のとおりです。
既存の更新 UI やエラーロギングがあるアプリでは、その構成に合わせて組み込みます。

```ts
import { app } from "electron";
import { autoUpdater } from "electron-updater";

app.whenReady().then(async () => {
  autoUpdater.disableWebInstaller = true;
  await autoUpdater.checkForUpdatesAndNotify();
});
```

この例だけでアプリの更新体験が完成するわけではありません。
ダウンロード失敗、再起動時の適用、利用者への通知をアプリの既存の仕組みに接続します。
エラーを無視せず、どの Release とファイルを取得したか追跡できるようにします。
更新対象のバージョンは、インストール済みのバージョンより大きくしてください。
rolling tag の指すコミットだけを変えても、同じバージョンでは更新として認識されないことがあります。

差分更新は blockmap を利用して試みます。
差分ダウンロードに失敗した際、全量ダウンロードで更新できることを合格条件にします。
実機ログで確認するまで「差分更新対応済み」や「差分更新を保証」とは扱いません。

## 調査したアプリの例

| アプリ                    | 調査時点                                   | 中央へ登録するために必要な対応                                                                                                           |
| ------------------------- | ------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `hiho-cli-audio`          | `32d6734bf3ddbfe094a85403c8d48acd6fffd62b` | macOS の更新用 ZIP、Windows の通常 NSIS、`electron-updater` の組み込み、更新メタデータの公開が必要。既存の macOS entitlements を保持する |
| `hiho-task-management-ai` | `f558e1cffc750f881f496a1b77a7374cf67b6e3a` | macOS は DMG と ZIP がある。Windows の通常 NSIS、`electron-updater` の組み込み、更新メタデータの公開が必要                               |

調査時点では両アプリとも Windows は NSIS Web のみで、更新クライアントと更新メタデータの公開がありません。
このリポジトリの導入だけでは不足は解消しません。
対象アプリへの変更はここには含めず、初期の許可一覧にも登録しません。

登録作業は[運用手順](operations.md)、更新経路の合格条件は[検証項目](verification.md)を参照してください。
