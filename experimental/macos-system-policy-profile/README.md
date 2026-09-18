# macOS system policy rule 実験

このディレクトリは、現行macOSで証明書単位のsystem policy ruleを手動検証するための実験です。標準の証明書trust導入手順ではありません。

```sh
bash experimental/macos-system-policy-profile/generate-profile.sh CERTIFICATE_DER OUTPUT_PROFILE
```

入力はDER形式の自己署名Code Signing leaf証明書です。CA:TRUEの証明書は受け付けません。生成するdevice profileの `PayloadScope` は `System` です。

Apple公式schemaに照合した `com.apple.systempolicy.rule` payloadを含めます。

<https://github.com/apple/device-management/blob/release/mdm/profiles/com.apple.systempolicy.rule.yaml>

- `OperationType` は `operation:execute`
- `LeafCertificate` は入力DER証明書のbase64データ
- `Requirement` は `certificate leaf = H"SHA-1 fingerprint"`
- `Comment` には確認用のSHA-256 fingerprintを入れる

Requirementは証明書leafだけを識別し、bundle IDを限定しません。同じ証明書で署名した複数アプリを検証対象にします。

SHA-1は証明書を識別するための値であり、署名hashを指定するものではありません。自己署名leafをroot証明書として偽装しないため、`com.apple.security.root` payloadは生成しません。通常の証明書trust導入は別途、OSが提供する手順で判断します。

このプロファイルが構文検証を通っても、Gatekeeperがこのruleを採用することは保証しません。実機では次の順で確認してください。

1. プロファイルを手動でインストールし、受理内容を確認する
2. quarantine属性を残したブラウザー経由のダウンロードで署名済みアプリを起動する
3. 別の証明書で署名したnegative sampleが許可されないことを確認する
4. 同じ証明書で署名した別アプリと更新を確認する
5. プロファイルを削除し、削除後の挙動を確認する

Gatekeeper全体やquarantine検証を無効化する操作は行いません。現行macOS実機での成立確認が済むまで、標準導入手順にもCIにも組み込みません。
