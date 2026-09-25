# 公開と再実行

この手順は中央リポジトリと対象アプリを管理する本人が行います。
初回は[GitHub の初期設定](github-setup.md)と[ソースの要件](source-requirements.md)を確認してください。
更新方式を対象アプリの README で確認し、共通要件と、その方式の要件を[検証項目](verification.md)の公開前と公開後の区分に沿って確認します。

## 公開する

1. GitHub App の Selected repositories に対象リポジトリを含めます。
2. 公開するソースへ tag を付け、その tag の GitHub Release を draft であらかじめ作成します。公開前の検証は draft Release で行います。既存 Release を使う場合は、公開状態と同名ファイルが置換されることを確認します。
3. macOS と Windows の署名に使う repository secret が設定済みであることを確認します。
4. 中央リポジトリの Actions から `sign-release` を選び、既定ブランチで `repository` と `tag` を指定して実行します。
5. 両 OS の署名とアップロードが完了したら、対象リポジトリ、タグ、固定したコミット SHA、8 件の asset、macOS と通常 NSIS の更新 metadata、署名と[公開前の実機検証](verification.md)を確認します。NSIS Web は installer と package の存在と名前、installer の署名と最終タグの取得 URL を確認します。更新方式と検証結果を記録し、手動更新の初回署名版で旧版がない場合は更新未確認を明記します。
6. 公開前の確認が完了したら、`gh release edit TAG --repo OWNER/REPO --draft=false --latest=false` で Latest にせず Release を公開します。この時点で URL を知る利用者は取得できます。
7. GitHub 認証なしの実機で、最終タグの NSIS Web の package 取得、導入、起動と主要機能を確認します。該当するアプリ内更新も最終タグの公開 URL で確認します。結果を記録してから利用を案内し、Latest にする版では `gh release edit TAG --repo OWNER/REPO --latest` を実行します。

手動更新へ切り替える場合は、実行前に過去の自動更新クライアントの配布履歴と更新経路を確認します。
手動更新でも更新 metadata は公開されるため、旧版がそれを取得する場合の影響と移行手順を記録してください。

GitHub CLI では、中央リポジトリの作業ディレクトリから次のように実行します。
`owner/personal-tool` と `v1.2.3` は対象の値へ置き換えてください。

```sh
gh workflow run sign-release.yml -f repository=owner/personal-tool -f tag=v1.2.3
```

`resolve-source` は tag を checkout して一度だけ source SHA を確定します。
macOS と Windows は同じ SHA を checkout し、両方の package job が成功したときだけ公開へ進みます。
公開直前に tag の現在 SHA が同じであることを再確認するため、実行中は tag を移動しないでください。
同じ repository と tag の実行は concurrency で排他し、進行中の処理は新しい実行によって自動キャンセルしません。
Actions の外から行う編集まで排他できないため、公開中の Release の手動編集は避けてください。

中央は指定 tag の既存 Release へファイルをアップロードします。
Release の新規作成や、タイトル、本文、tag、draft、prerelease の編集は行いません。
Immutable Release は変更できません。

同名ファイルは常に `gh release upload --clobber` で置換します。
新しい成果物と同名でない既存ファイルは削除しません。
配布ファイルと blockmap を先に、更新 metadata を最後に公開します。
macOS と通常 NSIS の更新 metadata が参照する実ファイルの名前、サイズ、Base64 の SHA-512、外部 blockmap、version は公開前に検証します。`blockMapSize` がある場合だけ実サイズも検証します。
NSIS Web の package は参照名と存在を確認しますが、中央では実サイズと hash を照合しません。最終タグの URL からの取得と導入は Release 公開後に確認します。

## 失敗した公開を再実行する

GitHub Release の同名ファイル置換は、削除とアップロードに分かれます。
公開全体は原子的ではなく、途中で失敗するとファイルが欠けたり、旧版と新版が混在したりします。
更新 metadata を最後にしても、置換途中に旧 metadata が新しいファイルを参照する状態は防げません。

公開ジョブで失敗した場合は、次の順に修復します。

1. 失敗したジョブのログから、権限、Release の状態、tag の SHA、通信などの原因を確認します。
2. 同じ実行の署名済み artifact が残っていることを確認し、tag と公開先を維持したまま原因を解消します。
3. Actions の同じ実行で `Re-run failed jobs` を選びます。成功済みの package job の成果物を使い、配布ファイルから更新 metadata まで再アップロードします。
4. 再実行が成功した後、Release のファイルが揃い、更新 metadata の参照と hash が一致することを確認します。

CLI では同じ実行 ID を指定します。

```sh
gh run rerun RUN_ID --failed
```

新しい dispatch や `Re-run all jobs` はビルドと署名をやり直すため、別のファイルを生成することがあります。
同じ署名済み成果物で修復する場合は、失敗した job だけを再実行してください。
artifact が削除済みまたは保持期限切れの場合、同じ成果物を使う修復はできません。

## Release 公開後の検証に失敗した場合

NSIS Web の取得・導入やアプリ内更新に失敗した場合は、公開後の障害として扱い、利用案内と Latest 指定を止めます。
公開日時、公開 URL と取得可能だった範囲、失敗した操作とログを記録します。Latest にしなくても取得を防げるわけではありません。
原因を解消してから最終タグの公開 URL で再確認し、成功を記録します。ファイルのアップロードを修復する場合は、上の再実行手順に従います。
修復できない場合は、配布停止の方法と、既に取得した利用者への案内・復旧対応を決めて実施します。

## 成果物と記録

Actions artifact には OS ごとの署名済み成果物を保存します。
公開するファイルは artifact の `payload/` と `metadata/` にあります。
artifact の保持期間は 7 日です。

検証記録には repository、tag、固定した source SHA、アプリ version、更新方式、Actions の実行 URL、取得したファイル名を残します。
秘密鍵、パスワード、GitHub App token をログや記録へ含めないでください。
記録する実機の条件は[検証項目](verification.md)を参照してください。

証明書を更新するときは、macOS または Windows の repository secret と、公開証明書、`config/signing.json` の対応を確認します。
同じ表示名の新しい証明書でも既存アプリから更新できるとは限らないため、[検証項目](verification.md)の公開前と公開後の区分に従い、対象アプリの方式で旧版からの更新を実機で確認してから利用を案内してください。
