# 検証項目

静的検査、実際の GitHub Actions、実機での導入と更新を分けて記録します。
このリポジトリでは実際の証明書による署名・公開と、実機での起動・更新は未検証です。

## 静的検査と GitHub Actions

[verify ワークフロー](../.github/workflows/verify.yml)で format、lint、型、workflow、shell script、PowerShell script の構文を検査します。
静的検査の成功だけでは、OS の署名処理や GitHub Release への公開の成功を確認したことにはなりません。

実際の App と Secrets を使う確認は、検証用アプリと検証用 Release で行います。

| 確認対象 | 合格条件 |
| --- | --- |
| 対象リポジトリと入力 | repository と tag で実行でき、App の Selected repositories の範囲だけへアクセスできる |
| ソース固定 | macOS と Windows が同じ source SHA を checkout し、公開前に tag が移動していれば停止する |
| ビルド | source で frozen install、build、electron-builder が成功し、source の設定と hook が成果物へ反映される |
| macOS 署名 | electron-builder の署名が成功し、ZIP、blockmap、更新 metadata が生成される |
| Windows 署名 | electron-builder の署名が成功し、通常 NSIS、blockmap、channel に対応する root metadata、NSIS Web installer、`.nsis.7z` package が生成される |
| 成果物選択 | 余分な builder 出力を公開せず、必須 asset が一意に選ばれる |
| 更新 metadata | 実ファイルの参照、サイズ、Base64 の SHA-512、blockmap size、version が一致する |
| 公開先 | 既存かつ変更可能な Release だけを変更し、Release の本文などを編集しない |
| 上書き公開 | 同名ファイルを置換し、配布ファイルと blockmap の後に更新 metadata を公開する |
| 公開失敗と再実行 | 途中状態を確認し、同じ実行の署名済み成果物で修復できる |
| 後始末 | 一時的な P12、PFX、keychain、環境変数を削除し、処理と cleanup の両方の失敗を検出できる |

## macOS 実機

連続する二つのアプリ version を用意します。
初回導入はブラウザーで取得した ZIP を使い、quarantine 属性を保持します。

| 確認対象 | 合格条件 |
| --- | --- |
| 初回導入 | ZIP を展開してアプリを配置でき、OS の警告と本人による許可操作を記録し、起動と主要機能を確認できる |
| 内部コードと署名 | Framework、Helper、ネイティブモジュールを含む署名と必要な entitlements を確認できる |
| ZIP 更新 | 同じ bundle ID、証明書、秘密鍵の次 version へ更新し、再起動後の version を確認できる |
| 差分と全量取得 | 使用した更新方式をログで確認し、差分取得の失敗時にも全量取得で更新できる |
| 改変・別証明書 | 改変したアプリや異なる署名の更新に対する拒否と、停止した検証段階を記録できる |
| 追加の端末 | 公開証明書だけで端末を設定でき、秘密鍵の転送を要しない |

system policy profile は[独立した実験](../experimental/macos-system-policy-profile/README.md)として検証します。

## Windows 実機

連続する二つのアプリ version を用意し、Smart App Control の状態を記録します。
初回導入はブラウザーで取得したインストーラーを使い、Mark of the Web を保持します。

| 確認対象 | 合格条件 |
| --- | --- |
| 公開証明書の登録 | fingerprint を照合し、CurrentUser の Root と TrustedPublisher へ公開証明書だけを登録できる |
| 初回導入 | 通常 NSIS と NSIS Web の署名と導入を確認でき、NSIS Web が package を取得できる |
| 通常 NSIS 更新 | `disableWebInstaller=true` で通常 NSIS を取得し、再起動後の version を確認できる |
| 識別情報 | appId、GUID、publisher が継続し、重複導入されず、設定と利用者データを保持する |
| 差分と全量取得 | blockmap による取得と、差分取得の失敗時の全量更新をログで確認できる |
| 改変・別証明書 | 改変や期待しない署名への拒否と、停止した検証段階を記録できる |
| 追加の端末 | 公開証明書だけで端末を設定でき、秘密鍵の転送を要しない |

SmartScreen の警告が残る場合は、表示と本人が行った操作を記録します。
改変したアプリやインストーラーを通常の配布先へ公開しないでください。

## 記録する内容

実施日、実施者、OS と CPU、アプリ version、repository、tag、source SHA、Actions の実行 URL、公開証明書の fingerprint、取得したファイル名、結果とログの保存先を残します。
OS の警告、初回の許可操作、差分取得と全量取得の結果も記録します。
未確認の結果を成功とせず、実機で成立した手順と実装済みの処理を区別してください。
