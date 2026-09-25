# 検証項目

静的検査、実際の GitHub Actions、実機での導入と更新を分けて記録します。
このリポジトリではテストコードを実装せず、CI の静的検査と以下の手動確認を行います。
[main の Actions 実行 35689941519](https://github.com/Hiroshiba/oreore-codesigner/actions/runs/35689941519)では全ジョブが成功し、実際の証明書による macOS と Windows の署名・公開を確認しました。
公開先の draft Release で 8 件の asset を確認し、macOS ZIP と通常 NSIS の更新 metadata の参照先、サイズ、hash が実ファイルと一致することを確認しました。
実機での起動・更新は未検証です。

対象アプリの README で更新方式と利用者向けの手順を確認します。
手動更新では置換・再導入を、アプリ内更新では新タグへの到達と差分・全量更新を検証します。
初回の署名付き配布で更新元がない場合は、初回導入の結果と「更新未確認」を記録し、次のバージョンで更新を確認します。
証明書を更新する場合は、[端末の初期設定](device-setup.md#追加の端末と証明書更新)に沿って新しい公開証明書の照合と信頼設定を確認し、旧版からの移行を別に検証します。アプリ内更新で移行できない場合は手動更新で確認します。

## 静的検査と GitHub Actions

[verify ワークフロー](../.github/workflows/verify.yml)で format、lint、型、workflow、shell script、PowerShell script の構文を検査します。
静的検査の成功だけでは、OS の署名処理や GitHub Release への公開の成功を確認したことにはなりません。

実際の App と Secrets を使う確認は、検証用アプリと検証用 Release で行います。

| 確認対象             | 合格条件                                                                                                                                                       |
| -------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 対象リポジトリと入力 | repository と tag で実行でき、App の Selected repositories の範囲だけへアクセスできる                                                                          |
| ソース固定           | macOS と Windows が同じ source SHA を checkout し、公開前に tag が移動していれば停止する                                                                       |
| source契約           | SemVer version、exact pnpm、electron-builder 26.16.1、build script、単一YAML、publish禁止、versionからのchannelが検証される                                    |
| ビルド               | source で frozen install、build、electron-builder が成功し、source の設定と hook が成果物へ反映される                                                          |
| macOS 署名           | electron-builder の署名が成功し、ZIP、blockmap、更新 metadata が生成される                                                                                     |
| Windows 署名         | electron-builder の署名が成功し、通常 NSIS、blockmap、channel に対応する root metadata、NSIS Web metadataに対応する installer、`.nsis.7z` package が生成される |
| 成果物選択           | metadataの参照名から下位directoryを含む成果物を一意に選び、余分な builder 出力を公開しない                                                                     |
| 更新 metadata        | macOS ZIP と通常 NSIS の実ファイルの参照、サイズ、Base64 の SHA-512、外部 blockmap、version が一致する。`blockMapSize` がある場合だけ実サイズも一致する        |
| 公開先               | 既存かつ変更可能な Release だけを変更し、Release の本文などを編集しない                                                                                        |
| 上書き公開           | 同名ファイルを置換し、配布ファイルと blockmap の後に更新 metadata を公開する                                                                                   |
| 公開失敗と再実行     | 途中状態を確認し、同じ実行の署名済み成果物で修復できる                                                                                                         |
| 後始末               | 一時的な P12、PFX、keychain、環境変数を削除し、処理と cleanup の両方の失敗を検出できる                                                                         |

NSIS Web は metadata の version と参照先を検証し、installer の size が metadata にある場合だけ実サイズと照合します。
中央は NSIS Web の installer と package の hash や package の実サイズを照合しないため、8 件すべてのサイズと hash が検証済みとは扱いません。

## 初回公開

アプリ内更新から手動更新へ切り替える場合は、新版の公開前に[ソースの要件](source-requirements.md#更新方式)に沿って旧版の実装と更新先 URL を確認し、新版の更新 metadata への到達と自動取得・適用の有無を判定します。

1. draft Release のまま、両 OS の署名、対象 tag と source SHA、配布する 8 件の asset の存在を確認します。macOS は ZIP、blockmap、更新 metadata の 3 件、Windows は通常 NSIS、blockmap、更新 metadata、NSIS Web installer、`.nsis.7z` package の 5 件です。
2. 管理者が draft Release からブラウザーで ZIP と通常 NSIS を取得し、以下の実機項目に沿って署名、導入、起動、バージョンと主要機能を確認します。NSIS Web installer の署名も確認します。
3. Release を公開し、認証なしで ZIP、通常 NSIS、NSIS Web installer と package、更新 metadata と blockmap を取得できることを確認します。NSIS Web は installer からの package 取得と初回導入まで確認します。
4. 更新元がある場合は採用した方式で更新を確認します。手動更新への切り替えでも、公開前の判定で旧版が自動適用する場合はその経路で実機更新を、しない場合は手動移行を確認します。アプリ内更新を使う経路では旧版から新タグの Release URL へ到達し、差分更新と差分取得に失敗した場合の全量更新ができることを確認します。
5. 確認後に利用者への案内を始めます。公開後の取得や導入・更新に失敗した場合は案内を停止し、[公開と再実行](operations.md)に沿って原因を解消し、修復と再確認を行います。

draft の間は匿名で NSIS Web の package やアプリ内更新のファイルを取得できないため、これらの成功は公開後に確認します。

## macOS 実機

更新を検証するときは、連続する二つのアプリ version を用意します。
初回導入はブラウザーで取得した ZIP を使い、quarantine 属性を保持します。
共通項目と、採用した更新方式および旧版からの移行に使う方式の項目を確認します。

| 確認対象                     | 合格条件                                                                                                                       |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| 初回導入                     | ZIP を展開してアプリを配置でき、OS の警告と本人による許可操作を記録し、起動、バージョンと主要機能を確認できる                  |
| 内部コードと署名             | Framework、Helper、ネイティブモジュールを含む署名と必要な entitlements を確認できる                                            |
| 更新の共通項目               | 同じ bundle ID の次 version へ更新して起動でき、version、設定と利用者データの保持を確認できる                                  |
| 手動更新                     | 対象 Release から新しい ZIP を取得し、展開したアプリの署名者と証明書を確認してから、アプリを終了して既存アプリを置き換えられる |
| アプリ内更新                 | 旧版が新タグの Release URL へ到達し、同じ証明書と秘密鍵で署名された新版の ZIP を取得して再起動時に適用できる                   |
| アプリ内更新の差分と全量取得 | 差分更新の成功をログで確認し、差分取得の失敗時にも全量取得で更新できる                                                         |
| 改変・別証明書               | 改変や期待しない署名のアプリに対する OS の検証結果と、アプリ内更新を使う経路では更新拒否と停止した検証段階を記録できる         |
| 追加の端末                   | 公開証明書だけで端末を設定でき、秘密鍵の転送を要しない                                                                         |

system policy profile は[独立した実験](../experimental/macos-system-policy-profile/README.md)として検証します。

## Windows 実機

更新を検証するときは、連続する二つのアプリ version を用意します。
Smart App Control の状態を記録します。
初回導入はブラウザーで取得したインストーラーを使い、Mark of the Web を保持します。
共通項目と、採用した更新方式および旧版からの移行に使う方式の項目を確認します。

| 確認対象                     | 合格条件                                                                                                                               |
| ---------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| 公開証明書の登録             | fingerprint を照合し、CurrentUser の Root と TrustedPublisher へ公開証明書だけを登録できる                                             |
| 初回導入                     | 通常 NSIS と NSIS Web の署名、導入、起動、バージョンと主要機能を確認でき、公開後は NSIS Web が認証なしで package を取得できる          |
| 更新の共通項目               | appId、GUID、publisher が継続して重複導入されず、更新後に起動でき、version、設定と利用者データの保持を確認できる                       |
| 手動更新                     | 対象 Release から新しい通常 NSIS インストーラーを取得し、デジタル署名の署名者と証明書を確認してから既存アプリへ再導入できる            |
| アプリ内更新                 | 旧版が新タグの Release URL へ到達し、`disableWebInstaller=true` で通常 NSIS を取得して、再起動時に適用できる                           |
| アプリ内更新の差分と全量取得 | blockmap による差分更新の成功と、差分取得の失敗時の全量更新をログで確認できる                                                          |
| 改変・別証明書               | 改変や期待しない署名のアプリ・インストーラーに対する OS の検証結果と、アプリ内更新を使う経路では更新拒否と停止した検証段階を記録できる |
| 追加の端末                   | 公開証明書だけで端末を設定でき、秘密鍵の転送を要しない                                                                                 |

SmartScreen の警告が残る場合は、表示と本人が行った操作を記録します。
改変したアプリやインストーラーを通常の配布先へ公開しないでください。

## 記録する内容

実施日、実施者、OS と CPU、アプリ version、repository、tag、source SHA、Actions の実行 URL、公開証明書の fingerprint、取得したファイル名、更新方式、更新元と更新先、結果とログの保存先を残します。
OS の警告、初回の許可操作、設定と利用者データの保持、draft 中と公開後の確認結果も記録します。
アプリ内更新を使う経路では、新タグの Release URL への到達経路、差分取得と全量取得の結果も記録します。
手動更新への切り替えでは、旧版が新版の更新 metadata へ到達して自動取得・適用するかの公開前の判定と、実機で確認した移行経路も記録します。
証明書更新時は、新旧の fingerprint、端末での信頼設定と旧版からの移行結果を分けて記録します。
未確認の結果を成功とせず、実機で成立した手順と実装済みの処理を区別してください。
