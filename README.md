# RINKAN UMIS for macOS

Flet／Python版RINKAN UMISを、macOS向けにSwift 6で再構築するプロジェクトです。

## 開発

```sh
swift test
swift build
```

ローカル検証用の`.app`は次で作成します。

```sh
UMIS_ALLOW_ADHOC=1 Scripts/build_app.sh
```

配布ビルドはKeychain内の`Developer ID Application` identityを自動検出します。identityがない場合は失敗し、ad-hocへ自動fallbackしません。

## 安全境界

- コピー完了とカード初期化許可は別状態です。
- カード初期化はRequired Set全件のsource／destination再読SHA-256、durability、同一物理mediaの再確認を通過したone-shot tokenだけで実行できます。
- SD管理システムやLANからの応答は、ローカルのコピー検証や初期化条件を弱めません。
- production SD APIが未実装の間、release buildは`DisabledSDManagementGateway`だけを使用します。
