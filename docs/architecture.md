# 構成と信頼境界

このリポジトリを中央、署名対象アプリのリポジトリをソースと呼びます。
中央は署名鍵と公開権限を管理し、ソースの tag と commit SHA を固定します。
対象ソースと依存関係、ビルド hook は管理者が信頼する前提で、各 OS の同じジョブ内でビルド、署名、梱包を行います。
公開対象は GitHub App の Selected repositories で管理します。

## ジョブと受け渡すデータ

| ジョブ | 処理 | 使用する秘密情報と権限 |
| --- | --- | --- |
| `resolve-source` | 入力した repository と tag を検証し、tag を checkout して commit SHA を固定 | 対象リポジトリ一つの Contents read トークン |
| `package-macos` | 固定 SHA のソースで install、build、electron-builder による署名と ZIP 梱包を実行 | macOS environment の P12 とパスワード、Contents read |
| `package-windows` | 固定 SHA のソースで install、build、electron-builder による署名と NSIS 梱包を実行 | Windows environment の PFX とパスワード、Contents read |
| `publish-release` | 両 OS の成果物、version、更新 metadata、tag SHA、Release 状態を検証して公開 | 対象リポジトリ一つの Contents write トークン |

中央とソースの checkout はいずれも workflow 実行時の中央 SHA または `resolve-source` の固定 SHA を使います。
両 OS は同じ `source_sha` を checkout し、ソース側で `pnpm install --frozen-lockfile` と `pnpm run build` を実行します。
公開前に tag の現在 SHA が固定 SHA と一致することを確認します。
外部 Action はコミット SHA で参照します。

## ソース設定の扱い

electron-builder の appId、version、productName、GUID、publisher、icon、entitlements、artifactName、NSIS 設定、hook はソース側の設定を正本として直接使います。
中央で `package-input.json` や一時 package project を生成したり、ソース設定を再構築したりしません。
`electron-builder` の CLI には OS、x64、出力先、`forceCodeSigning`、Release の generic publish URL だけを渡します。

macOS は electron-builder に `CSC_LINK`、`CSC_KEY_PASSWORD` と必要な `CSC_NAME` を渡し、一時 keychain の作成と削除を任せます。
Windows は `WIN_CSC_LINK`、`WIN_CSC_KEY_PASSWORD` だけを使い、中央で SignTool を呼んだり `.dll` や `.node` を総当たりで再署名したりしません。
秘密値と一時署名ストアの後始末は各処理の終了時に行い、処理と cleanup の両方が失敗した場合は両方を報告します。

## 成果物と公開

macOS は ZIP、blockmap、更新 metadata を生成します。
Windows は通常 NSIS の installer、blockmap、更新 metadata と、NSIS Web の installer、7z package を生成します。
通常 NSIS の metadata は通常 installer を参照し、NSIS Web の成果物は初回導入に使います。
builder の余分な出力は公開対象へ選びません。

公開前に両 OS の version、asset の一意性、metadata が参照する実ファイルの存在、サイズ、Base64 の SHA-512、blockmap size を検証します。
既存かつ変更可能な Release だけを対象にし、配布ファイルと blockmap を先に、更新 metadata を最後に `gh release upload --clobber` で公開します。
公開処理は原子的ではないため、失敗時は同じ実行の署名済み artifact で再実行します。

初期設定は[GitHub の初期設定](github-setup.md)、アプリ側の準備は[ソースの要件](source-requirements.md)、公開中断時の操作は[運用手順](operations.md)を参照してください。
