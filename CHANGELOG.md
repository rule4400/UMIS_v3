# Changelog

すべての重要な変更をこのファイルに記録します。バージョンはSemantic Versioningに従い、本番利用の承認状態と単なる実装完了を分離します。

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
- Developer ID Application certificate/private keyとnotary Keychain profileがこのMacにないため、配布用署名とApple公証は未実施です。

## [0.1.0-bootstrap] - 2026-08-26

- Swift Package、GitHub repository、CI、versioning/rollbackのbootstrap。
