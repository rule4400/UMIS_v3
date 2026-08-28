# Changelog

すべての重要な変更をこのファイルに記録します。バージョンはSemantic Versioningに従い、本番利用の承認状態と単なる実装完了を分離します。

## [0.2.0-alpha.4] - 2026-08-28

### Added

- ニューモーフィズムのUMIS正式アプリアイコン。macOS 13以降のICNS用continuous-curvature版と、将来のIcon Composer／システムマスク用unmasked版を分離。
- 1024px sRGB masterの幾何学検査、標準10解像度ICNSの決定的生成、既存assetの自動backup、build／release manifestへのSHA-256記録。
- 公証済みDMG、内包Universal 2 app、Developer ID、entitlements、dSYM、notary証跡、Git tagを後日でもread-onlyで再検証できる独立release verifier。

### Fixed

- `UMIS_ALLOW_ADHOC=1`がDeveloper ID導入済み環境でKeychain署名を自動選択していた問題を修正し、明示identityがないローカル検証では常にad-hoc署名を使用。
- Apple公証待機中に`dist`のappが別buildで差し替わると、DMG内appとrelease manifestが食い違い得る競合を解消。最終stapled DMG内をread-onlyで再検証し、その値だけを証跡化。
- DMG／dSYMの既存成果物backupとchecksumを自己完結させ、最終DMG・checksum・manifest公開途中の失敗時に直前の成果物へrollback。

### Distribution

- `CFBundleIconFile`からバンドル内ICNSを署名前に固定し、source／staged app／release DMGのicon hash一致をfail-closedで検証。
- このMacのKeychainに`Developer ID Application` certificate／private keyと`UMIS_NOTARY` profileを導入。資格情報とprivate keyはrepositoryおよびrelease artifactに含めない。

## [0.2.0-alpha.3] - 2026-08-26

### Fixed

- TLS 1.2 PSK接続でsession resumption／ticketを明示的に無効化し、PSK rotation後を含む各snapshot接続でfresh PSK proofを必須化。
- 高負荷の並列テストでもmetadata generator開始を回数制pollingに依存せず、continuation handshakeで決定的に検証。

## [0.2.0-alpha.2] - 2026-08-26

### Fixed

- Xcode 16／Swift 6.0系でもmedia cache容量の辞書リテラルを`Int64`として一意に型解決できるようにし、GitHub ActionsのmacOS 15 runnerとのtoolchain互換性を修正。

## [0.2.0-alpha.1] - 2026-08-26

### Added

- Flet/Python版を完全に分析したmacOSネイティブSwift 6アーキテクチャと要件セット。
- 安定UUIDモデル、versioned Project Store、SQLite WAL操作journal、履歴、旧JSON read-only migration、復旧可能なProject Trash。
- `.umis-partial` + fsync + source/destination全再読SHA-256 + no-replace atomic commitによる検証付き取り込み。
- 内容一致をfull hashで証明した場合だけのduplicate skip。
- 既存folderからのCopy and Rename、preview、companion/sidecar group、実行直前全root再scan、rollback/recovery state。
- Disk Arbitration/IOKitによるカード監視、strong physical identity、safe eject、確認後の最終全再読検証から開始するカード初期化安全境界。
- 利用者が除外するfileと空folderの理由、担当者、確認時刻証跡。
- ImageIO、QuickLookThumbnailing、AVFoundation、Core Imageを使うnative thumbnail/preview/movie poster/playback/metadata pipeline。
- priority queue、request coalescing、bounded concurrency、memory pressure対応、SQLite LRU cache。
- EXIF `DateTimeOriginal + OffsetTimeOriginal`、TIFF DateTime、QuickTime creation date、mtime fallbackの厳密な撮影日時解決。
- SwiftUI 3-pane workspace、virtualized `NSCollectionView` grid、movie/audio preview、Finder drag and drop、操作履歴。
- Ed25519署名Scene Catalog、revision/high-water、tombstone、Keychain pairing、SAS、Bonjour + TLS-PSK実験transport。
- SD管理システムのdisabled production gateway、canonical event、durable outboxと将来adapter境界。
- Universal 2 local build、Developer ID/notarizationをfail-closedで実行するrelease script、GitHub Actions、Git hooks、checkpoint/worktree rollback tooling。
- 公開repository用の証拠path匿名化、private-key／credential signature検知hook、immutable SHA固定GitHub Action。
- Launch Services + advisory file lockによる単一アプリプロセス境界、単一media workspace window。
- destination root descriptor、`openat(O_NOFOLLOW)`／`renameatx_np(RENAME_EXCL)`によるsymlink差替え耐性、child／parent directory fsync。
- 結果不明の初期化をwhole-media証拠へ結び付け、SQLiteへ永続化する再起動横断カード隔離。
- transaction内のcanonical audit-chain append、payload digest、tamper検証、redacted exportへの検証結果同梱。
- 取り出し／初期化前のメディアアクセスラッチと、AVPlayer／native media pipelineの二段階quiescence確認。
- native media requestの受付世代とin-flight admissionを追跡し、queue投入前のrequestも含めてquiescence完了を待つ線形化。
- 基本inventoryを先に表示し、撮影日時を優先度付きbounded taskで補完し、計画時だけ正確なscopeを全再走査するprogressive scan。
- 取り込み／選別／Copy and Renameで共通のprimary＋sidecar group契約と、primary撮影日時を基準にした安定連番。
- NAS／SMB／NFSのmount lifecycle authority、世代、volume／filesystem／device／root inode署名と全destination再検証境界。
- LAN snapshot適用時のversion CASとapplication lease。Project保存済みcandidateとUI反映を一つの排他処理へ固定。
- SQLite audit schema v6のtrusted head／CASにより、安全な通常追記をO(1)化し、10,000件追記と外部connection変更fallbackを検証。
- 監査export schema v3でaudit payloadに加えてsession title／detail／path／raw errorを既定除外。
- disappearance後の再appearanceでは同じreader／カードでも必ず新しいSourceVolumeIDとarrival generationを発行。
- retained media claim取得後にfresh identityを再確認し、opaque handleへ結び付けたtokenだけを直後consumeする破壊操作protocol。

### Fixed from the legacy implementation

- 並べ替え後にscene割り当てが別fileへ移るindex identity破損。
- 既存同名fileを無検証で成功扱いし、原本カード初期化を許す欠陥。
- `verify_checksum` settingが実際のcopy pathで使われない欠陥。
- destination partial/collision/rollback/resumeと履歴の不整合。
- card label/display nameを物理media identityとして使う誤消去risk。
- eject完了前にUI modelと割り当てを消す問題。
- 設定Cancel、会場名rename、select cancel、history filter、file drag and drop等の表示と実装の不一致。
- unsigned/unhashed updaterによる現行program置換・実行risk。

### Safety restrictions

- 実カード破壊試験、複数reader、停電／抜去、NAS durabilityの実機受入試験に加え、製品認定済みretained native formatter／eject providerが未実装のため、カード初期化と安全な取り出しはproduction availability=falseです。環境変数だけでは解除できません。
- このMacのreaderでは再format後も不変なwhole-media UUIDを取得できず、強いカードID、安全な取り出し、初期化をfail-closedしています。認定reader／hardware identity規約が必要です。
- アプリ再起動後の中断取り込みrebindと、Copy and Rename／選別コピーのcrash-recovery UIは未実装です。NAS lifecycleはcopy-gradeのみで、実share試験とerase durability認定は未実施です。
- LAN共有はTLS 1.2 PSKの実験機能です。mTLS、LAN CA、device certificate/revocationが完成するまでproduction不可です。
- SD管理VPS側にversioned integration APIがないため、現行browser/admin APIへは接続しません。
- `0.2.0-alpha.1`作成時点ではDeveloper ID Application certificate/private keyとnotary Keychain profileが未導入でした。現在の署名／公証状態は各release manifestを正本とします。

## [0.1.0-bootstrap] - 2026-08-26

- Swift Package、GitHub repository、CI、versioning/rollbackのbootstrap。
