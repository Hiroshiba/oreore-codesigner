# 検証項目

静的検査、実際の GitHub Actions、実機での導入と更新を分けて記録します。
このリポジトリではテストコードを実装せず、CI の静的検査と以下の手動確認を行います。
[main の Actions 実行 35689941519](https://github.com/Hiroshiba/oreore-codesigner/actions/runs/35689941519)では全ジョブが成功し、実際の証明書による macOS と Windows の署名・公開を確認しました。
公開先の draft Release で 8 件の asset を確認し、更新 metadata の参照先、サイズ、hash が実ファイルと一致することを確認しました。
実機での起動・更新は未検証です。

## 静的検査と GitHub Actions

[verify ワークフロー](../.github/workflows/verify.yml)で format、lint、型、workflow、shell script、PowerShell script の構文を検査します。
静的検査の成功だけでは、OS の署名処理や GitHub Release への公開の成功を確認したことにはなりません。

実際の App と Secrets を使う確認は、検証用アプリと検証用 Release で行います。

| 確認対象 | 合格条件 |
| --- | --- |
| 対象リポジトリと入力 | repository と tag で実行でき、App の Selected repositories の範囲だけへアクセスできる |
| ソース固定 | macOS と Windows が同じ source SHA を checkout し、公開前に tag が移動していれば停止する |
| source契約 | SemVer version、exact pnpm、electron-builder 26.16.1、build script、単一YAML、publish禁止、versionからのchannelが検証される |
| ビルド | source で frozen install、build、electron-builder が成功し、source の設定と hook が成果物へ反映される |
| macOS 署名 | electron-builder の署名が成功し、ZIP、blockmap、更新 metadata が生成される |
| Windows 署名 | electron-builder の署名が成功し、通常 NSIS、blockmap、channel に対応する root metadata、NSIS Web metadataに対応する installer、`.nsis.7z` package が生成される |
| 成果物選択 | metadataの参照名から下位directoryを含む成果物を一意に選び、余分な builder 出力を公開しない |
| macOS と通常 NSIS の更新 metadata | 実ファイルの参照、サイズ、Base64 の SHA-512、外部 blockmap、version が一致する。`blockMapSize` がある場合だけ実サイズも一致する |
| NSIS Web の成果物 | metadata の参照名に一致する installer と `.nsis.7z` package が存在する。installer の size が記載されていれば実サイズが一致する。package の実サイズと hash の照合は中央の検証に含まれない |
| 公開先 | 既存かつ変更可能な Release だけを変更し、Release の本文などを編集しない |
| 上書き公開 | 同名ファイルを置換し、配布ファイルと blockmap の後に更新 metadata を公開する |
| 公開失敗と再実行 | 途中状態を確認し、同じ実行の署名済み成果物で修復できる |
| 後始末 | 一時的な P12、PFX、keychain、環境変数を削除し、処理と cleanup の両方の失敗を検出できる |

## Release 公開前と公開後

公開前は draft Release で、対象タグと source SHA、8 件の asset、macOS と通常 NSIS の更新 metadata の整合、アプリとインストーラーの署名を確認します。
macOS ZIP と通常 NSIS の初回導入、起動、主要機能と、提供する方式の更新も以下の実機検証で確認します。ただし、最終タグの公開 URL を使うアプリ内更新は公開後に確認します。手動更新の初回署名版で旧版がない場合は、更新を未確認として記録します。
NSIS Web は installer と `.nsis.7z` package の存在と名前、installer の署名、取得先が最終タグの Release URL を指す設計を公開前に確認します。
NSIS Web は認証なしで package を取得しますが、draft Release は push 権限のある利用者だけが閲覧できるため、本番 URL からの取得と導入は draft 中に確認できません。

Release 公開後は、GitHub 認証なしの実機で NSIS Web の package 取得、導入、起動と主要機能を確認します。
アプリ内更新を提供する場合、最終タグの公開 URL を使う更新経路も、公開後に旧版からの更新、差分取得と全量取得を確認します。
検証用 Release の成功を、最終タグの URL から取得できることの保証にはしません。
公開した時点で URL を知る利用者は取得できるため、これらは公開前の検証完了には含めません。公開後の確認、利用案内と Latest 指定、失敗時の対応は[運用手順](operations.md)に従います。

## macOS 実機

連続する二つのアプリ version を用意し、ソースの README に記載した更新方式の行と共通の行を確認します。
手動更新の初回署名版で旧版がない場合は、更新に関する項目を未確認として記録します。
初回導入はブラウザーで取得した ZIP を使い、quarantine 属性を保持します。

| 確認対象 | 合格条件 |
| --- | --- |
| 初回導入 | ZIP を展開してアプリを配置でき、OS の警告と本人による許可操作を記録し、起動と主要機能を確認できる |
| 内部コードと署名 | Framework、Helper、ネイティブモジュールを含む署名と必要な entitlements を確認できる |
| 手動更新 | 新版の ZIP の配布元と展開したアプリの署名を人手で確認し、旧版を終了してアプリを置換した後、version、起動、設定と利用者データの保持を確認できる |
| アプリ内更新の ZIP 更新 | 旧版から同じ bundle ID、証明書、秘密鍵の次 version へ更新し、再起動後の version を確認できる |
| アプリ内更新の差分と全量取得 | 使用した更新方式をログで確認し、差分取得の失敗時にも全量取得で更新できる |
| アプリ内更新の改変・別証明書 | 改変したアプリや異なる署名の更新に対する拒否と、停止した検証段階を記録できる |
| 追加の端末 | 公開証明書だけで端末を設定でき、秘密鍵の転送を要しない |

system policy profile は[独立した実験](../experimental/macos-system-policy-profile/README.md)として検証します。

## Windows 実機

連続する二つのアプリ version を用意し、ソースの README に記載した更新方式の行と共通の行を確認します。
手動更新の初回署名版で旧版がない場合は、更新に関する項目を未確認として記録します。
Smart App Control の状態を記録します。
初回導入はブラウザーで取得したインストーラーを使い、Mark of the Web を保持します。

| 確認対象 | 合格条件 |
| --- | --- |
| 公開証明書の登録 | fingerprint を照合し、CurrentUser の Root と TrustedPublisher へ公開証明書だけを登録できる |
| 通常 NSIS の初回導入 | 公開前に署名、導入、起動と主要機能を確認できる |
| NSIS Web の初回導入 | 公開前に installer の署名を確認でき、公開後に GitHub 認証なしで最終タグの package を取得し、導入、起動と主要機能を確認できる |
| 手動更新 | 新版の通常 NSIS の配布元と署名を人手で確認し、旧版を終了してインストーラーを実行した後、version と起動を確認できる |
| アプリ内更新の通常 NSIS 更新 | 旧版から `disableWebInstaller=true` で通常 NSIS を取得し、再起動後の version を確認できる |
| 識別情報 | appId、GUID、publisher が継続し、重複導入されず、設定と利用者データを保持する |
| アプリ内更新の差分と全量取得 | blockmap による取得と、差分取得の失敗時の全量更新をログで確認できる |
| アプリ内更新の改変・別証明書 | 改変や期待しない署名への拒否と、停止した検証段階を記録できる |
| 追加の端末 | 公開証明書だけで端末を設定でき、秘密鍵の転送を要しない |

SmartScreen の警告が残る場合は、表示と本人が行った操作を記録します。
改変したアプリやインストーラーを通常の配布先へ公開しないでください。

## 記録する内容

実施日、実施者、OS と CPU、アプリ version、更新方式、repository、tag、source SHA、Actions の実行 URL、公開証明書の fingerprint、取得したファイル名、Release 公開前か公開後か、認証の有無、結果とログの保存先を残します。
OS の警告、初回の許可操作、手動更新では配布元と署名の人手確認、アプリ内更新では差分取得と全量取得の結果も記録します。
手動更新へ切り替える場合は、過去の自動更新クライアントの配布有無、旧版の更新経路と既存利用者への影響、移行手順を記録します。
手動更新の初回署名版で旧版がない場合は、その理由と更新未確認を記録し、導入・起動の成功を更新成功とは扱いません。
未確認の結果を成功とせず、実機で成立した手順と実装済みの処理を区別してください。
