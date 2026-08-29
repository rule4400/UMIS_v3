# Implementation status

更新日: 2026-08-29

この文書は「実装済み」「自動検証済み」「実機検証済み」「本番利用可能」を分離します。コードが存在するだけの機能を完成扱いにしません。

## 現在の検証基準

- Swift 6 / macOS 13 target
- 全target `swift build -j 1 -Xswiftc -warnings-as-errors`: 成功
- 全自動test: 286件実行、失敗0件、環境条件付き1件skip（`swift test --parallel`、Adobe XMP／Finderカラー／大量件数／適応的media sizing／cache隔離／撮影日時cancel／LAN排他・status統合／物理カードscan中抜去／network mount通知順序の最終tree）。skip対象のcase-sensitive APFS同stem衝突試験はcase-sensitive APFS disk image上で別途成功
- Universal 2 local build: arm64 / x86_64、両slice macOS 13.0
- arm64 native起動smoke: 成功
- x86_64 Rosetta起動smoke: 成功
- ad-hoc codesign + Hardened Runtime整合性: 成功
- Developer ID / notarization: `CHECK HOUSE, K.K. (FA43T8UK3P)` identityと`UMIS_NOTARY` profileをKeychainに導入済み。`0.2.0-alpha.4`はAccepted／staple／Gatekeeper検証成功。現行`0.2.0-alpha.5` feature buildはDeveloper ID署名済みだが、公証未送信
- 現行UIのarm64実行確認: JPEG／PNG／TIFF／PSD／MOVの5件でXMP 5つ星、明示0、Finderレッド／解除、再読込み／再スキャン後の保持、検索、写真／動画previewを隔離fixtureで確認済み

## 機能別状態

| 領域 | 実装 | 自動test | 実機／外部test | production |
|---|---|---|---|---|
| Swift package／Core・Media・Network境界 | 実装済み | build + tests成功 | Universal 2両arch起動済み | alpha |
| verified ingest／SQLite journal／resume | 実装済み | copy、cancel、同mount-session内resume、破損、電断境界test | 再起動後source rebind、実SD／実NAS未実施 | alpha制限 |
| duplicate handling | full SHA-256一致だけverified existing、異内容block | 成功 | 大規模archive未実施 | alpha |
| card erase gate | confirmed verify→retained claim→fresh identity→handle-bound token→one-shot backend→post-format probe／quarantine。root／items scan中もin-flight insertionを追跡し、結果公開とmedia resume前後にcurrent identityを再照合 | fake claim／identity／replay／TOCTOU／restart quarantine 21件＋scan中抜去／同mount差替えpolicy test成功 | native handle-bound formatterと実カード試験なし | production availability=false |
| safe eject | retained native object＋fresh identity＋process内quiesceを必須化、BSD名helperを禁止 | fake claim／I/O競合／BSD再利用test成功 | retained DADisk eject provider／実reader試験なし | production availability=false |
| folder Copy and Rename | copy-only、preview、root/group再走査、descriptor-relative commit、rollback state | commit／mkdir／parent fsync全boundary、companion、collision／連番test成功 | process-kill後のrecovery UI、実archive未実施 | alpha制限 |
| Adobe互換Rating／Finderカラー | Adobe XMP Toolkit v2025.03固定、対応形式のembedded safe update、RAW／未認定形式の衝突回避sidecar、exact file descriptorのFinderInfo label bit更新 | Rating読書、形式route、破損／競合／symlink／hardlink／同stem、名前付きFinderタグ／他FinderInfo byte保持test | 隔離fixtureのXMP／Finder書込みUI往復は確認済み。Adobe各製品との双方向確認、実RAW／動画corpus、Intel Mac実機は未実施 | alpha制限 |
| native thumbnail／preview／movie poster | ImageIO／QuickLookThumbnailing／AVFoundation／Core Image、progressive metadata、実表示寸法×backing scaleのbounded request | queue、coalescing、admission drain、cancel、1x／2x要求上限、HEIC、H.264、cache test成功 | JPEG／PNG／TIFF／PSD／MOVのthumbnailと写真／動画preview確認済み。実運用RAW／MXF等corpus未実施 | alpha |
| media cache | memory cost + memory pressure + SQLite incremental LRU + quota、全read admission停止後のquiescent clear | 再起動、破損DB隔離、LRU、queue投入前race、抜去隔離resume policy test成功 | 長時間負荷未実施 | alpha |
| Project v3／旧JSON移行／Trash復旧 | atomic fsync、known-good backup、read-only import | migration、破損分離、復旧test成功 | 実運用JSON variant未実施 | alpha |
| audit chain／履歴export | schema v6 trusted head、O(1) transaction append、全chain明示verify、path／raw errorを含まないschema v3 export、共通排他gateと履歴status | tamper／fork／legacy epoch／10,000追記／privacy test成功 | 外部anchor／署名checkpoint未実施 | alpha |
| LAN Scene Catalog | signed full snapshot、revision、tombstone、Keychain pairing、fresh TLS-PSK proof、explicit apply＋application lease/CAS、親AppModelへの操作状態伝播 | signature、rollback、split-brain、PSK rotation/session再開拒否、fetch/apply race／UI排他publication test成功 | 複数実Mac未実施 | 実験機能・production不可 |
| NAS／SMB／NFS destination | mount lifecycle authority＋generation＋volume/filesystem/device/inode署名を全I/O境界へ結線し、callback順と非同期handler完了順を直列化 | unmount／remount／通知遅延／stale event／非同期handler追越し防止／provider test成功 | 実share・切断・ACL・長時間試験なし | copy-gradeのみ |
| SD Management boundary | Disabled Gateway、canonical event、durable outbox | retry／idempotency／dead-letter test成功 | staging APIなし | adapterなし |
| Developer ID署名／公証 | Universal 2／Hardened Runtime／secure timestamp／DMG／notary／staple／Gatekeeper、最終DMG内appのread-only再検証、transactional artifact公開をfail-closed実行 | shell/plist/static検査、独立verifierによる既存公証版の再検証成功 | `0.2.0-alpha.4` Accepted、警告0、staple／Gatekeeper成功 | release manifestで個別判定 |
| Git／rollback | GitHub main基点、annotated bootstrap tag、hooks、worktree rollback | hook構文／tests成功 | remote push済み | 利用可能 |

## Alphaで意図的に無効または制限する機能

### カード初期化

Required Set、全SHA-256、最終検証、retained claim、handle-bound token、post-format probeまでのCore設計とfake backend試験は実装済みです。ただし、このbuildには製品認定済みのnative formatterがないため、`DiskutilCardEraseBackend.isBundledProductionBoundaryAvailable == false`です。`UMIS_ENABLE_CARD_ERASE=1`を設定してもUIとproduction backendは解除されません。安全な取り出しも同じ理由でavailability=falseです。利用可能にする前に次が必要です。

- 外部reader／Quick Look／他アプリの読取を含む物理媒体排他契約（UMISの二重起動自体は拒否済み）
- retained DADiskに直接作用するnative eject provider
- 再利用可能なBSD名を権限にせず、retained opaque handleに直接結び付く製品認定formatter
- 実SDカード／複数reader／ExFAT互換試験
- コピー中kill、停電、抜去、diskutil timeout、post-format probe障害注入
- 実NAS利用時のdurability profile認定（現在はネットワーク保存先からのeraseをfail-closed）

このMacの実カード／readerをread-onlyで調べたところ、`RemovableMedia=true`／`Ejectable=true`／`OSInternalMedia=false`ですが`Internal=true`、かつ`MediaUUID`が得られませんでした。現在の実装はこの不確実な媒体を強いカードIDとして受け入れず、安全側に初期化／取り出しを無効化します。`VolumeUUID`を物理ID代わりにすると再formatで変化するため行いません。対応readerのIOKit topology／hardware ID規約と認定fixtureが必要です。

### LAN Scene Catalog

通信は実験的TLS 1.2 PSKです。各接続でPSKを再証明するためsession resumptionとsession ticketを無効化し、Ed25519署名、catalog fingerprint、短時間invite、SAS、Keychain、rollback high-waterも実装済みです。ただし、要件上のLAN CA、相互TLS、server/client leaf証明書、SPKI pin、端末失効は未実装です。起動ごとのoperator opt-inがなければlistener／Bonjour／fetchを開始しません。

### SD管理システム

引き継ぎ物は静的解析・再現試験に十分でしたが、UMIS専用integration APIはSD側にまだありません。現行のadmin APIへNative Appから直接接続しません。最低限、次が必要です。

- service authenticationとkey rotation
- stable external ID／version／optimistic concurrency
- event IDによるidempotent inboxと再送receipt
- `ingest_verified` と `ready_for_reuse` の状態分離
- staging URL、OpenAPI、error code、rate limit、timeout契約
- VPS現行source／image／DB／添付backup、restore drill

SD側の応答はカード初期化許可を作成・上書きできません。

## Release blocker／defense in depth

- アプリ再起動後の中断取り込みを、新mount-sessionと再走査証拠へ明示再結合するrecovery flowが未実装
- Copy and Renameのprocess-kill後resume／rollback UIが未実装
- 認定された物理SD hardware identity／reader policy、retained native eject／formatter、外部processを含む媒体排他契約が未実装
- NAS lifecycleはcopy-gradeで結線済みだが、実share障害試験と認定erase durability profileが未実施
- progressive inventory／bounded metadataは実装済みだが、10,000件級の実RAW／動画で長時間負荷を未検証
- 実運用movie／RAW／HEIC／MXF／MKV／AVI／MTS sample corpusが未提供
- Adobe Bridge／Lightroom Classic／Camera Raw／Photoshop／Premiere ProとのXMP双方向検証が未実施
- 実SD・NAS・SMB・ACL・大容量／低メモリ長時間試験が未実施
- 署名private key／notary credentialはこのMacのKeychainにのみ保存。releaseの継続性はKeychain backupとApple Developer側のcertificate管理に依存

秘密鍵、password、production DB、実利用者の個人情報をrepositoryへ追加しません。
