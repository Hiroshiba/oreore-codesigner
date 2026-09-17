# 個人用アプリの中央署名基盤

複数の Electron アプリを、共通の自己署名証明書で署名して各アプリの GitHub Release へ公開するためのリポジトリです。
秘密鍵をここに集約し、ソースの取得、秘密情報を使わないビルド、署名、公開を別々のジョブで実行します。

macOS は DMG で初回導入し、ZIP で更新します。
Windows は WebSetup で初回導入し、通常の NSIS インストーラーで更新します。
更新にはアプリ側への `electron-updater` の組み込みが必要です。
署名済みファイルを公開するだけでは、自動更新は有効になりません。

自己署名は、OS の標準審査や公的なコード署名の代替にはなりません。
macOS では最初の端末操作が残り、Windows では証明書を信頼済みにしても SmartScreen の警告が残ることがあります。
Smart App Control が強制されている Windows は対象外です。
Gatekeeper や Windows の保護設定全体を無効にする手順は提供しません。

## 導入する順序

1. [構成と信頼境界](docs/architecture.md)を読み、対象端末と運用範囲を確認します。
2. [GitHub の初期設定](docs/github-setup.md)に従い、GitHub App、中央の Secrets、公開承認を設定します。
3. [アプリ側の契約](docs/app-contract.md)を満たすように対象アプリを準備します。
4. [運用手順](docs/operations.md)に従い、公開証明書情報とアプリを中央設定へ登録します。
5. [端末の初期設定](docs/device-setup.md)を行い、[検証項目](docs/verification.md)を実機で確認します。
6. 検証結果を確認してから、対象アプリの既存 Release へ署名済み成果物を公開します。

公開ワークフローは [.github/workflows/sign-release.yml](.github/workflows/sign-release.yml) です。
既定ブランチから実行し、入力は `app_id`、`tag`、`replace_existing_assets` だけです。
取得先リポジトリや実行コマンドは、中央の `config/apps.json` によって制限します。
公開先の Release はアプリのリポジトリにあらかじめ作成してください。
中央ワークフローは Release 自体を作成せず、タイトル、本文、タグも変更しません。
公開失敗時は変更のロールバックを試み、完了できない場合は復旧用 Actions artifact を使います。
復旧資料の保持期間は 90 日です。[運用手順](docs/operations.md)で確認方法を説明しています。

## 初期状態と検証状況

`config/apps.json` のアプリ一覧は空で、`config/signing.json` の証明書情報も未設定です。
証明書とアプリを登録するまで公開処理は実行できません。
調査例の `hiho-cli-audio` と `hiho-task-management-ai` は、現時点ではアプリ側の契約を満たしておらず、登録していません。
これらは登録に必要な作業を示す例で、アプリ側のソース変更はこのリポジトリの変更に含みません。

[verify ワークフロー](.github/workflows/verify.yml)には静的検証と単体テストを定義しています。
実際の GitHub Actions での verify と、実際の Secrets を使う署名・公開は未実施です。
ローカルの検証結果を、これらの実行成功とは扱いません。

macOS の自己署名 ZIP 更新、Windows のブラウザー経由で取得した WebSetup による初回導入、通常 NSIS による更新、両 OS の差分更新は実機未確認です。
blockmap を公開して差分更新を試みますが、実機ログで成功を確認するまでは差分更新を保証しません。
差分更新に失敗した場合は全量ダウンロードへ切り替わることが必要です。
rolling tag の asset 公開と、固定タグからの自動更新は別の機能です。
固定タグへ更新クライアントを接続する処理は中央に実装していないため、[アプリ側の契約](docs/app-contract.md)を確認してください。

証明書単位の Gatekeeper 許可を試す構成プロファイルは、`experimental/macos-system-policy-profile/` の実験です。
現行 macOS の実機で成立を確認するまで、標準の導入手順には含めません。
