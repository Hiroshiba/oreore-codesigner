# 個人用 Electron アプリを中央で署名・公開する

自分で管理する Electron アプリを GitHub Actions でビルドし、自己管理の証明書で署名して、指定した GitHub Release へ公開するリポジトリです。
実行時に対象の `repository` と `tag` を指定します。
署名鍵と GitHub App の秘密鍵は、この中央リポジトリだけで管理します。

| OS      | 初回導入                   | 手動更新                  | アプリ内更新               |
| ------- | -------------------------- | ------------------------- | -------------------------- |
| macOS   | ZIP を展開してアプリを配置 | 新版の ZIP でアプリを置換 | ZIP と更新メタデータ       |
| Windows | 通常 NSIS または NSIS Web  | 新版の通常 NSIS を実行    | 通常 NSIS と更新メタデータ |

手動更新とアプリ内更新に対応し、対象アプリの README に更新方式を明記します。
アプリ内更新には、対象アプリでの `electron-updater` の組み込みと更新先の設定が必要です。
署名済みファイルを公開するだけでは、アプリ内更新は有効になりません。
手動更新のアプリでも blockmap と更新メタデータを生成・公開しますが、アプリ内更新の実装や動作を示すものではありません。

## 導入と公開

1. [GitHub の初期設定](docs/github-setup.md)に従い、GitHub App、署名証明書、repository secret を設定します。対象範囲は App の Selected repositories で管理します。
2. [ソースの要件](docs/source-requirements.md)を確認します。リポジトリのルートにある `package.json`、`pnpm-lock.yaml`、electron-builder の YAML 設定を使い、秘密情報を使わずに x64 のアプリ本体をビルドします。
3. 対象タグの draft Release をあらかじめ作成し、[運用手順](docs/operations.md)に従って `sign-release` を実行します。
4. [端末の初期設定](docs/device-setup.md)を行い、[検証項目](docs/verification.md)の公開前と公開後の区分に沿って初回導入と、対象アプリの方式で旧版からの更新を確認します。NSIS Web の package 取得と導入、最終タグの公開 URL を使うアプリ内更新は Release 公開後に確認し、結果を記録してから利用を案内します。手動更新の初回署名版で旧版がない場合は、更新を未確認として記録します。

中央の [config/signing.json](config/signing.json) には macOS と Windows の公開証明書と fingerprint を登録済みです。
macOS と Windows の署名ジョブは repository secret にある証明書を electron-builder へ渡し、署名の成否は electron-builder の結果で判定します。
このリポジトリには秘密鍵を含めません。

指定した Release の同名ファイルは常に上書きします。
配布ファイルを先に、更新メタデータを最後にアップロードしますが、公開全体は原子的ではありません。
公開が失敗した場合は、同じ Actions 実行の失敗したジョブを再実行し、保存済みの署名済み成果物で修復します。
詳しい制約は[公開と再実行](docs/operations.md)を参照してください。

## 権限と端末の信頼

ソース取得では対象リポジトリだけを読める GitHub App トークンを使い、タグをコミット SHA に固定します。
macOS と Windows は同じ SHA のソースを checkout し、各 OS のジョブ内で install、build、署名、梱包まで実行します。
アプリのコードと builder を動かすジョブには公開用 token を渡しません。
公開ジョブだけが、対象リポジトリへ書き込む別のトークンを使います。
詳しくは[構成と信頼境界](docs/architecture.md)を参照してください。

端末へ配布するのは公開証明書だけです。
自己署名は Apple の notarization や Windows の公的なコード署名の代替にはならず、OS の警告が残ることがあります。
保護設定全体を無効にする運用は行いません。
Smart App Control が強制されている Windows 端末は対象外です。

macOS で証明書単位の実行許可を試す [system policy profile](experimental/macos-system-policy-profile/README.md) は実験です。
現行 macOS の実機で規則の適用を確認するまでは、標準手順に含めません。

## 検証状況

このリポジトリではテストコードを実装しない方針です。
[verify ワークフロー](.github/workflows/verify.yml)で、format、lint、型、ワークフローとスクリプトの構文を静的に検査します。
[main の Actions 実行 35689941519](https://github.com/Hiroshiba/oreore-codesigner/actions/runs/35689941519)では全ジョブが成功し、実際の証明書による macOS と Windows の署名・公開を確認しました。
公開先の draft Release で 8 件の asset を確認しました。macOS と通常 NSIS の更新 metadata が参照する実ファイルについて、参照名、サイズ、hash が一致することを確認しました。
実機での起動と更新は未検証です。
アプリ内更新を提供するアプリでは、差分更新と、差分取得に失敗した場合の全量更新も実機確認が必要です。

証明書の生成方法は[証明書ツール](scripts/certificates/README.md)、実機で残す記録は[検証項目](docs/verification.md)を参照してください。
不具合は秘密情報を含めず、対象 OS、アプリのバージョン、失敗した操作とログを添えて [GitHub Issues](https://github.com/Hiroshiba/oreore-codesigner/issues)へ報告してください。
