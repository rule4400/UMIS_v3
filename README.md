# RINKAN UMIS for macOS

Flet／Python版RINKAN UMISを、macOS向けにSwift 6で再構築するプロジェクトです。

## 開発

初回は開発環境検証とGit hook設定をまとめて行えます。

```sh
Scripts/bootstrap_development.sh
```

通常のbuild／test:

```sh
swift test
swift build
```

ローカル検証用の`.app`は次で作成します。

```sh
UMIS_ALLOW_ADHOC=1 Scripts/build_app.sh
```

配布ビルドはKeychain内の`Developer ID Application` identityを自動検出します。identityがない場合は失敗し、ad-hocへ自動fallbackしません。

Developer ID、公証、staple、Universal 2、DMGまでを行う配布buildは、先に`notarytool`のKeychain profileを作成してから実行します。

```sh
UMIS_NOTARY_PROFILE=UMIS_NOTARY Scripts/build_release.sh
```

`Developer ID Application` identityまたはnotary profileがない場合、このscriptは成果物を配布可能と誤表示せずに停止します。

証明書とKeychain profileの導入手順は [Docs/SIGNING_AND_RELEASE.md](Docs/SIGNING_AND_RELEASE.md) を参照してください。

## 安全境界

- コピー完了とカード初期化許可は別状態です。
- カード初期化はユーザーの最終確認後に、Required Set全件のsource／destination再読SHA-256、durability、同一Secure Digital媒体、保存先独立性を再確認し、retained media claim取得後のopaque handleに結び付けた一回限りcapabilityをその場で生成・消費する設計です。確認画面を開いている間の検証結果は初期化権限として利用しません。
- 初期化と安全な取り出しの間はプレビュー開始をラッチし、同一process内のsource I/Oを排他停止します。destinationはroot descriptorから`openat(O_NOFOLLOW)`系で追跡し、各ファイルと親directoryを同期してからreceiptを発行します。
- 単一アプリprocessはLaunch Servicesと`fcntl`ロックで強制します。現在のbuildには、BSD名を再解決せず保持中のnative media handleそのものへ作用する製品認定formatter／eject providerがありません。このためカード初期化と安全な取り出しはCoreとUIの両方で利用不可にしており、環境変数だけでは解除できません。検証フローは決定的fake backendで試験しますが、実カードに対する破壊操作は行いません。
- 結果不明の初期化は物理カード単位でSQLiteへ永続隔離し、新しいmount sessionやアプリ再起動でも、最初の読み取り前に拒否します。
- 既存同名ファイルは内容一致をSHA-256で確認できた場合だけ検証済み重複として扱い、異なる内容を上書きしません。
- フォルダCopy and Renameは元ファイルを変更せず、全root／companion groupを実行直前に再走査し、一時ファイル・fsync・SHA-256・atomic commit・journalを使用します。
- 動画／写真本体とXMP・XML・THM等の付随ファイルは、取り込み・選別・Copy and Renameの全経路で同じシーン、連番、出力stem、保存先へ一括配送します。曖昧な対応関係は計画時点で拒否します。
- NAS／SMB／NFSは、NSWorkspaceのmount lifecycle、volume UUID、filesystem、device、root inodeをprocess-local authorityへ結び付けたcopy-grade保存先として扱います。再mount時は世代を更新し、ネットワーク保存先からのカード初期化は認定durability profileがないため拒否します。
- SD管理システムやLANからの応答は、ローカルのコピー検証や初期化条件を弱めません。
- production SD APIが未実装の間、release buildは`DisabledSDManagementGateway`だけを使用します。

## 実装済みの主な構成

- `UMISCore`: stable ID、versioned project、SQLite WAL journal、再開、SHA-256検証、rename transaction、retained-handle erase/eject gate、O(1)監査追記
- `UMISMedia`: ImageIO、QuickLookThumbnailing、AVFoundation、Core Imageによるnative thumbnail／preview／poster／metadata、優先度queue、request coalescing、source-read admission／quiescence、memory pressure、SQLite LRU cache
- `UMISNetwork`: Ed25519署名済みscene snapshot、rollback／split-brain防止、Keychain pairing、durable SD outbox境界
- `RinkanUMIS`: SwiftUI、NSCollectionView virtualized grid、カード監視、3-pane ingest、履歴、旧JSON移行、復旧可能なProject Trash

LAN通信は現在TLS 1.2 PSKの実験実装です。署名検証、SAS、Keychain、明示適用は実装済みですが、LAN CA／相互TLS／端末証明書失効が完成するまでUI上でもproduction不可として扱います。

中断取り込みは同じmount insertionと現在の凍結計画を再検証できる間は再開できます。アプリ再起動後に別のmount-session IDへ安全に再結合するrecovery UI、Copy and Renameのcrash-recovery UIは未実装のため、現時点でそれらを完成機能とは扱いません。

初回スキャンは基本inventoryを先に表示し、撮影日時metadataはbounded background taskで段階的に補完します。コピー計画を確定するときだけ元の正確なroot／items範囲を全件再走査し、必要な撮影日時とfingerprintを凍結します。

詳細な現行解析、要件、重大欠陥と受入条件は [Docs/Requirements/README.md](Docs/Requirements/README.md)、実装と検証の正確な状態は [Docs/IMPLEMENTATION_STATUS.md](Docs/IMPLEMENTATION_STATUS.md) を参照してください。
