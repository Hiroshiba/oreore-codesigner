# 運用手順

この手順は中央リポジトリと対象アプリを管理する本人が行います。
端末側の導入は[端末の初期設定](device-setup.md)を参照してください。

## アプリを追加する

1. 対象アプリを[アプリ側の契約](app-contract.md)に合わせます。署名鍵を使わないビルドと更新クライアントの組み込みを、アプリ側で確認します。
2. GitHub App の Selected repositories に対象アプリを追加します。
3. `config/apps.json` に一意な `app_id` と対象リポジトリ、許可するタグ、ビルド方法、配布設定を登録します。
4. `config/signing.json` に設定した公開証明書の情報と、中央の署名用 Secrets が対応することを確認します。
5. 中央の設定検証を通し、設定変更をレビューします。
6. 連続する二つのバージョンを使って、初回導入と更新の実機検証を行います。結果が揃うまで、未検証の更新経路を利用可能と案内しません。

アプリごとに repository やコマンドを実行時入力で変更する機能はありません。
登録済みの設定を変更するときは、通常の中央設定の変更としてレビューします。
アプリ側のリポジトリが移動した場合も、取得先と更新先の両方を確認してください。

## Release を実行する

アプリのバージョンを上げ、そのソースへタグを付けます。
対象リポジトリへ、そのタグに対応する Release を先に作成します。
draft ではなく公開済みにし、`latest` は通常の Release、`beta` と `dev` は prerelease にします。
公開済み asset と衝突しないこと、GitHub App が対象へアクセスできることを確認します。
正式版では `replace_existing_assets=false` を使います。

中央リポジトリの Actions から `sign-release` を選び、既定ブランチで `app_id`、`tag`、`replace_existing_assets` を入力します。
`app_id` と `tag` は必須で、`replace_existing_assets` を省略した場合は `false` です。
GitHub CLI を使う場合は、中央リポジトリの作業ディレクトリから次のように実行します。
アプリ名とタグは登録した値へ置き換えてください。

```sh
gh workflow run sign-release.yml -f app_id=personal-tool -f tag=v1.2.3 -F replace_existing_assets=false
```

ワークフローはタグをコミット SHA に固定し、ソース取得、ビルド、署名、梱包、一式の検証を実行します。
署名と公開の承認者は、固定されたコミットと対象 Release を確認します。
承認対象の environment は `macos-signing`、`windows-signing`、`release-publish` です。
同じ `app_id` とタグのワークフロー、および同じ対象リポジトリとタグの各処理は concurrency で排他します。
進行中の処理は新しい実行によって自動キャンセルしません。
Actions の外から同じ Release を編集する操作まで排他できるわけではないため、公開中の手動編集は避けてください。

公開用 App token は、承認と依存準備が終わった後、公開処理の直前に発行します。
通常の公開処理の期限は開始から 40 分で、ロールバック用にさらに 10 分を確保します。
HTTP リクエストは一回あたり最大 300 秒とし、残り時間が少なければ短くします。
期限を超えて更新を続けず、復旧を完了できなければ後述の手動復旧へ移ります。

固定 SHA と検証結果は、Actions の実行ページから次の artifact をダウンロードして確認できます。
`run_id` は実行 ID、`app_id` は登録したアプリ名です。

| Actions artifact                                                             | 確認するファイルと内容                                                                                                |
| ---------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| `central-run_id-app_id-source`                                               | 固定した `source.tar`、`source-manifest.json`、取得時に確定した `release-contract.json`                               |
| `central-run_id-app_id-macos-build` と `central-run_id-app_id-windows-build` | 署名前のアプリ本体だけを含む `unsigned-app.tar`                                                                       |
| `central-run_id-app_id-macos-signed`                                         | 署名後に取得した `designated-requirement.txt`                                                                         |
| `central-run_id-app_id-release`                                              | `release-assets.tar`、`release-manifest.json`、`source-manifest.json`、`release-contract.json`、`build-manifest.json` |
| `central-run_id-app_id-publish-recovery`                                     | 公開ジョブ失敗時の復旧資料。保持期間は 90 日                                                                          |

`source-manifest.json` は repository、tag、sourceSha、commitTimestamp、configDigest を記録します。
`build-manifest.json` は repository、tag、sourceSha、version、configDigest、runUrl を記録します。
これらの manifest は Actions artifact に保存し、対象 Release へは配布用の asset だけを公開します。
公開ジョブはタグが固定 SHA から動いていないことを再確認し、`plan-publish --assets-directory` で実ファイルと更新 YAML を検証してから公開計画を実行します。
asset の変更前にも Release ID、タグ、公開状態を確認し、別の Release への置き換えや外部変更を検出した場合は停止します。

公開処理は DMG、ZIP、NSIS、WebSetup のダウンロード対象、blockmap などを先にアップロードし、更新メタデータを最後にアップロードします。
中央は Release のタイトル、本文、タグを変更しません。
終了後は対象 Release の asset と実行結果を確認し、実機で取得したログも検証記録へ追記します。
公開成功時の job summary には、repository、tag、source SHA、version、config digest、実行 URL と各 asset のサイズ・digest が載ります。

## 失敗と再実行

| 停止した段階                   | 確認すること                                                  | 再実行時の扱い                                  |
| ------------------------------ | ------------------------------------------------------------- | ----------------------------------------------- |
| 設定検証、ソース取得           | 登録内容、タグ、Release の存在、App の対象範囲                | 原因を直し、同じ入力を使えるか確認する          |
| ビルド、署名、梱包、一式の検証 | 固定 SHA、アプリ契約、公開証明書設定、該当ジョブのログ        | 公開開始前なら Release asset は変更されていない |
| 公開                           | 失敗内容、ロールバックの結果、復旧用 artifact、現在の Release | 復旧結果を確認してから再実行する                |

正式版は追加のみで、同名で内容が異なる asset を上書きしません。
同名で digest が一致する asset は再アップロードせず、まだ存在しない asset の公開へ進めます。
同じソースを再ビルドしても署名時刻などで内容が変わることがあるため、同じ入力の再実行だけで復旧できるとは限りません。
公開処理や公開後の検証が失敗した場合は、その実行が作成したと確認できる asset を削除し、置換した旧 asset をバックアップから復元します。
正式版でも、その実行で新しく追加した asset の取り消しは行います。
復旧に成功した場合も元の公開処理は失敗として終了するため、ログと実際の Release を確認してから再実行します。
利用者が取得できる状態の正式版を、確認せず削除して作り直さないでください。
Immutable Release は変更できません。

rolling development release だけは、中央設定が置換可能で、実行時入力も `replace_existing_assets=true` の場合に既存 asset を置換します。
どちらか片方だけでは置換しません。
GitHub の asset 置換は削除後のアップロードであり、途中で失敗すると asset が欠けた状態になります。
更新メタデータを最後に公開しても、この途中状態や旧メタデータからの参照を完全には防げません。
応答が曖昧で作成した asset ID を確定できない場合、外部変更と競合した場合、復旧中に期限や権限の問題が起きた場合は、ロールバックを完了できないことがあります。
その場合は同名ファイルを推測で削除せず、復旧用 artifact を使って手動で確認します。

1. 失敗した Actions 実行から `central-run_id-app_id-publish-recovery` を取得します。90 日の保持期限を待たず、必要な復旧資料を保管してください。artifact の保存自体に失敗していないことも確認します。
2. archive 内の `recovery-info.txt` と、生成されていれば `rollback-result.txt` を読みます。処理が進んだ段階に応じて、`operation-journal.jsonl`、`initial-release-state.json`、`initial-remote-assets.json`、`publish-plan.json` が残ります。
3. 現在の Release ID とタグを、初期状態と journal の `expectedReleaseId` に照合します。別の Release に変わっていたら、その Release へ復元処理を行わないでください。
4. 現在の各 asset の ID、名前、digest、サイズと journal を照合し、この実行の変更と他の変更を区別します。`backups/番号.asset` の元の名前と digest は、対応する `backups/番号.json` に記録されています。
5. バックアップの digest とサイズを検証し、復元対象が確定したファイルだけを元の名前で戻します。配布ファイルを先に戻し、それらを参照する更新メタデータを最後に戻します。

復旧資料を自動で再適用するコマンドはありません。
ロールバックが未完了のまま再実行して状態を重ねず、管理者が復旧後の Release set を確認してから公開を再開します。

rolling tag を新しいコミットへ移したときも、アプリのバージョンを上げます。
実行中にタグを動かすと公開直前の照合で停止するため、その実行が終わるまで待ちます。
同じタグ名を使うことと、同じアプリバージョンを使うことは別です。
その実行で固定した SHA とバージョンを記録し、旧版から更新対象と判定されることを確認します。
`dev.yml` と `dev-mac.yml` の公開だけでは、固定 rolling tag から自動更新できるとは限りません。
中央には固定タグ用の更新 provider 設定がないため、[アプリ側の契約](app-contract.md)にある制約も確認します。

## 秘密情報と証明書を更新する

GitHub App の秘密鍵を更新するときは、中央の Secret を入れ替え、対象リポジトリ一つに制限した読み取りと公開ができることを確認します。
アプリ側のリポジトリへ秘密鍵を複製しません。

署名用証明書は有効期限より前に移行を計画します。
Secrets の P12 または PFX とパスワード、`config/signing.json` の公開情報、端末へ配布する公開証明書を対応させます。
証明書を変更しただけで既存アプリの更新が成功するとは扱いません。
別の証明書で署名した更新がどう処理されるかを隔離した検証環境で確認し、更新できる経路または再導入手順を確定します。

秘密鍵が漏えいした疑いがある場合は、その鍵を使った公開を停止します。
置き換える公開証明書を信頼できる経路で通知し、影響する端末とアプリを確認してから再開します。
自己署名証明書の信頼を端末から削除する操作は、他の利用中アプリへの影響を確認して本人が行います。
