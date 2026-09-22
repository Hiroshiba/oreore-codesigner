# 構成と信頼境界

このリポジトリを中央、署名対象アプリのリポジトリをソースと呼びます。
中央は署名鍵と公開権限を管理し、ソースの tag と commit SHA を固定します。
対象ソースと依存関係、ビルド hook は管理者が信頼する前提で、各 OS の同じジョブ内でビルド、署名、梱包を行います。
公開対象は GitHub App の Selected repositories で管理します。

## ジョブと受け渡すデータ

| ジョブ | 処理 | 使用する秘密情報と権限 |
| --- | --- | --- |
| `resolve-source` | 入力した repository と tag を検証し、tag を checkout して commit SHA と source 契約の version、channel、builder config を固定 | 対象リポジトリ一つの Contents read トークン |
| `package-macos` | 固定 SHA のソースで install、build、electron-builder による署名と ZIP 梱包を実行 | Repository secret の P12 とパスワード、Contents read |
| `package-windows` | 固定 SHA のソースで install、build、electron-builder による署名と NSIS 梱包を実行 | Repository secret の PFX とパスワード、Contents read |
| `publish-release` | 両 OS の成果物、version、更新 metadata、tag SHA、Release 状態を検証して公開 | 対象リポジトリ一つの Contents write トークン |

中央とソースの checkout はいずれも workflow 実行時の中央 SHA または `resolve-source` の固定 SHA を使います。
両 OS は同じ `source_sha` を checkout し、ソース側で `pnpm install --frozen-lockfile` と `pnpm run build` を実行します。
公開前に tag の現在 SHA が固定 SHA と一致することを確認します。
外部 Action は 40 桁の完全なコミット SHA で参照します。

## ソース設定の扱い

electron-builder の appId、productName、GUID、publisher、icon、entitlements、artifactName、NSIS 設定、hook はソース側の設定を正本として直接使います。
中央は対象ソースの設定を再構築せず、ソース側の electron-builder 設定を直接読み込ませます。
`electron-builder` の CLI には version、channel、OS、x64、出力先、macOS ZIP、通常 NSIS、NSIS Web、root と platform の署名強制、現在の channel だけの更新 metadata、root の対象 Release 用 generic publish URLを指定します。
source の builder 設定にある app 固有値は中央へ転記せず、中央が所有する公開先と署名必須だけを CLI で上書きします。
source の root、platform、target の publish は契約で禁止し、公開先の優先順位を source 側へ残しません。

macOS は electron-builder に `CSC_LINK` と `CSC_KEY_PASSWORD` を渡し、一時 keychain の作成と削除を任せます。
electron-builder は `security find-identity -v` で有効な identity だけを探すため、署名の前に公開証明書を runner の admin 信頼設定へ `codeSign` 用途で登録します。
自己署名は信頼設定がないと有効な identity として扱われず、`forceCodeSigning` によって署名が失敗します。
登録対象は使い捨ての runner だけで、証明書を作る本人の端末の信頼設定は変更しません。
信頼させた公開証明書と `CSC_LINK` の P12 に入っている証明書が同じであることを、署名の前に DER の一致で確認します。
Windows は `WIN_CSC_LINK`、`WIN_CSC_KEY_PASSWORD` だけを使い、中央で SignTool を呼んだり `.dll` や `.node` を総当たりで再署名したりしません。
秘密値と一時署名ストアの後始末は各処理の終了時に行い、処理と cleanup の両方が失敗した場合は両方を報告します。

## 成果物と公開

macOS は ZIP、外部 blockmap、channel に対応する root の `*-mac.yml` 更新 metadata を生成します。
Windows は通常 NSIS の installer、外部 blockmap、channel に対応する root の更新 metadata と、`nsis-web` 配下の metadata を基準に選ぶ installer、`.nsis.7z` package を生成します。
通常 NSIS の metadata は通常 installer を参照し、NSIS Web の成果物は初回導入に使います。
builder の余分な出力は公開対象へ選びません。artifactName が出力先の下位 directoryを含む場合も、metadata の参照名を使って再帰的に一意な実 file を選び、Release assetのbasenameへ集約します。

resolve-source が検証した root `package.json` の version、channel、builder config を両 OS jobへ同じ値として渡し、各 job は生成 metadataがその versionを参照することを検証します。

公開前に両 OS の version、asset の一意性、metadata が参照する実ファイルの存在、サイズ、Base64 の SHA-512、外部 blockmap を検証します。
metadata に `blockMapSize` がある場合だけ外部 blockmap の実サイズも照合します。
既存かつ変更可能な Release だけを対象にし、配布ファイルと blockmap を先に、更新 metadata を最後に `gh release upload --clobber` で公開します。
公開処理は原子的ではないため、失敗時は同じ実行の署名済み artifact で再実行します。

初期設定は[GitHub の初期設定](github-setup.md)、アプリ側の準備は[ソースの要件](source-requirements.md)、公開中断時の操作は[運用手順](operations.md)を参照してください。
