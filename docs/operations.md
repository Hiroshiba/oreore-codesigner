# 公開と再実行

この手順は中央リポジトリと対象アプリを管理する本人が行います。
初回は[GitHub の初期設定](github-setup.md)と[ソースの要件](source-requirements.md)を確認してください。

## 公開する

1. GitHub App の Selected repositories に対象リポジトリを含めます。
2. 対象アプリの README に更新方式と利用者向けの手順を記載し、公開するソースへ tag を付け、その tag の GitHub Release をあらかじめ作成します。初回公開は draft にします。既存 Release を使う場合は、同名ファイルが置換されることを確認します。
3. macOS と Windows の署名に使う repository secret が設定済みであることを確認します。
4. 中央リポジトリの Actions から `sign-release` を選び、既定ブランチで `repository` と `tag` を指定して実行します。
5. 両 OS の署名とアップロードが完了したら、対象リポジトリ、タグ、固定したコミット SHA、署名と配布する 8 件の asset を確認します。macOS は ZIP、blockmap、更新 metadata の 3 件、Windows は通常 NSIS、blockmap、更新 metadata、NSIS Web installer、`.nsis.7z` package の 5 件です。
6. 初回公開は draft のまま、管理者が ZIP と通常 NSIS をブラウザーで取得し、署名、実機導入、起動、バージョンと主要機能を確認します。NSIS Web installer の署名も確認します。
7. 管理者が Release を公開し、認証なしで全配布ファイルを取得できることと、NSIS Web installer による package の取得・導入を確認します。更新元がある場合は、採用した方式で旧版からの更新を[実機検証](verification.md)に沿って確認します。アプリ内更新では新タグの Release URL への到達と差分・全量更新を確認します。
8. 確認後に利用者への案内を始めます。初回の署名付き配布で更新元がない場合は「更新未確認」と記録し、次のバージョンで確認します。公開後の取得や導入・更新に失敗した場合は案内を停止し、原因の解消と修復、再確認を行います。

draft の間は、匿名での NSIS Web の package 取得やアプリ内更新を確認できません。
公開後も配布ファイル、更新 metadata と blockmap を認証なしで取得できる状態を維持します。
手動更新へ切り替える場合でも、既配布のアプリ内更新クライアントがあれば、更新先と利用者の移行手順を確認してから変更します。

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
初回公開の draft は運用上の手順であり、中央は draft を強制しません。公開済み Release の修復も対象です。
Immutable Release は変更できません。

同名ファイルは常に `gh release upload --clobber` で置換します。
新しい成果物と同名でない既存ファイルは削除しません。
配布ファイルと blockmap を先に、更新 metadata を最後に公開します。
macOS ZIP と通常 NSIS の更新 metadata が参照する実ファイルの名前、サイズ、Base64 の SHA-512、外部 blockmap、version は公開前に検証します。`blockMapSize` がある場合だけ実サイズも検証します。
NSIS Web の installer と package の hash や package の実サイズは中央で照合しません。検査範囲と実機での確認は[検証項目](verification.md)を参照してください。

## 失敗した公開を再実行する

GitHub Release の同名ファイル置換は、削除とアップロードに分かれます。
公開全体は原子的ではなく、途中で失敗するとファイルが欠けたり、旧版と新版が混在したりします。
更新 metadata を最後にしても、置換途中に旧 metadata が新しいファイルを参照する状態は防げません。

公開済み Release でも、配布ファイルが欠けたり取得・導入・更新に失敗したりした場合は利用者への案内を停止します。
取得権限やアプリの実装など、成果物の再アップロードで直らない原因は個別に解消します。
公開ジョブで失敗した場合は、次の順に修復します。

1. 失敗したジョブのログから、権限、Release の状態、tag の SHA、通信などの原因を確認します。
2. 同じ実行の署名済み artifact が残っていることを確認し、tag と公開先を維持したまま原因を解消します。
3. Actions の同じ実行で `Re-run failed jobs` を選びます。成功済みの package job の成果物を使い、配布ファイルから更新 metadata まで再アップロードします。
4. 再実行が成功した後、Release のファイルが揃い、macOS ZIP と通常 NSIS の更新 metadata の参照と hash が一致することを確認します。公開済みの場合は、認証なしでのファイル取得、NSIS Web の導入と採用した方式での更新を再確認してから案内を再開します。

CLI では同じ実行 ID を指定します。

```sh
gh run rerun RUN_ID --failed
```

新しい dispatch や `Re-run all jobs` はビルドと署名をやり直すため、別のファイルを生成することがあります。
同じ署名済み成果物で修復する場合は、失敗した job だけを再実行してください。
artifact が削除済みまたは保持期限切れの場合、同じ成果物を使う修復はできません。

## 成果物と記録

Actions artifact には OS ごとの署名済み成果物を保存します。
公開するファイルは artifact の `payload/` と `metadata/` にあります。
artifact の保持期間は 7 日です。

検証記録には repository、tag、固定した source SHA、アプリ version、Actions の実行 URL、取得したファイル名を残します。
秘密鍵、パスワード、GitHub App token をログや記録へ含めないでください。
記録する実機の条件は[検証項目](verification.md)を参照してください。

証明書を更新するときは、macOS または Windows の repository secret と、公開証明書、`config/signing.json` の対応を確認します。
同じ表示名の新しい証明書でも既存アプリから更新できるとは限らないため、配布前に旧版からの更新を実機で確認してください。
