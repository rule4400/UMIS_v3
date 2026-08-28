# Implementation status

更新日: 2026-08-28

この文書は「実装済み」「自動検証済み」「実機検証済み」「本番利用可能」を分離します。コードが存在するだけの機能を完成扱いにしません。

## 現在の検証基準

- Swift 6 / macOS 13 target
- 全target `swift build -j 1 -Xswiftc -warnings-as-errors`: 成功
- 全自動test: 172件成功、失敗0件（availability UI結線後の最終統合treeで再実行済み）
- Universal 2 local build: arm64 / x86_64、両slice macOS 13.0
- arm64 native起動smoke: 成功
- x86_64 Rosetta起動smoke: 成功
- ad-hoc codesign + Hardened Runtime整合性: 成功
- Developer ID / notarization: `CHECK HOUSE, K.K. (FA43T8UK3P)` identityと`UMIS_NOTARY` profileをKeychainに導入済み。`0.2.0-alpha.3`はAccepted／staple／Gatekeeper検証成功

## 機能別状態

| 領域 | 実装 | 自動test | 実機／外部test | production |
|---|---|---|---|---|
| Swift package／Core・Media・Network境界 | 実装済み | build + tests成功 | Universal 2両arch起動済み | alpha |
| verified ingest／SQLite journal／resume | 実装済み | copy、cancel、同mount-session内resume、破損、電断境界test | 再起動後source rebind、実SD／実NAS未実施 | alpha制限 |
| duplicate handling | full SHA-256一致だけverified existing、異内容block | 成功 | 大規模archive未実施 | alpha |
| card erase gate | confirmed verify→retained claim→fresh identity→handle-bound token→one-shot backend→post-format probe／quarantine | fake claim／identity／replay／TOCTOU／restart quarantine 21件成功 | native handle-bound formatterと実カード試験なし | production availability=false |
| safe eject | retained native object＋fresh identity＋process内quiesceを必須化、BSD名helperを禁止 | fake claim／I/O競合／BSD再利用test成功 | retained DADisk eject provider／実reader試験なし | production availability=false |
| folder Copy and Rename | copy-only、preview、root/group再走査、descriptor-relative commit、rollback state | commit／mkdir／parent fsync全boundary、companion、collision／連番test成功 | process-kill後のrecovery UI、実archive未実施 | alpha制限 |
| native thumbnail／preview／movie poster | ImageIO／QuickLookThumbnailing／AVFoundation／Core Image、progressive metadata | queue、coalescing、admission drain、cancel、HEIC、H.264、cache test成功 | 実運用RAW／MXF等corpus未実施 | alpha |
| media cache | memory cost + memory pressure + SQLite incremental LRU + quota | 再起動、破損DB隔離、LRU test成功 | 長時間負荷未実施 | alpha |
| Project v3／旧JSON移行／Trash復旧 | atomic fsync、known-good backup、read-only import | migration、破損分離、復旧test成功 | 実運用JSON variant未実施 | alpha |
| audit chain／履歴export | schema v6 trusted head、O(1) transaction append、全chain明示verify、path／raw errorを含まないschema v3 export | tamper／fork／legacy epoch／10,000追記／privacy test成功 | 外部anchor／署名checkpoint未実施 | alpha |
| LAN Scene Catalog | signed full snapshot、revision、tombstone、Keychain pairing、fresh TLS-PSK proof、explicit apply＋application lease/CAS | signature、rollback、split-brain、PSK rotation/session再開拒否、fetch/apply race test成功 | 複数実Mac未実施 | 実験機能・production不可 |
| NAS／SMB／NFS destination | mount lifecycle authority＋generation＋volume/filesystem/device/inode署名を全I/O境界へ結線 | unmount／remount／通知遅延／stale event／provider test成功 | 実share・切断・ACL・長時間試験なし | copy-gradeのみ |
| SD Management boundary | Disabled Gateway、canonical event、durable outbox | retry／idempotency／dead-letter test成功 | staging APIなし | adapterなし |
| Developer ID署名／公証 | Universal 2／Hardened Runtime／secure timestamp／DMG／notary／staple／Gatekeeper、最終DMG内appのread-only再検証、transactional artifact公開をfail-closed実行 | shell/plist/static検査、独立verifierによる既存公証版の再検証成功 | `0.2.0-alpha.3` Accepted、警告0、staple／Gatekeeper成功 | release manifestで個別判定 |
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
- Copy and Rename／選別copyのprocess-kill後resume／rollback UIが未実装
- 認定された物理SD hardware identity／reader policy、retained native eject／formatter、外部processを含む媒体排他契約が未実装
- NAS lifecycleはcopy-gradeで結線済みだが、実share障害試験と認定erase durability profileが未実施
- progressive inventory／bounded metadataは実装済みだが、10,000件級の実RAW／動画で長時間負荷を未検証
- 実運用movie／RAW／HEIC／MXF／MKV／AVI／MTS sample corpusが未提供
- 実SD・NAS・SMB・ACL・大容量／低メモリ長時間試験が未実施
- 署名private key／notary credentialはこのMacのKeychainにのみ保存。releaseの継続性はKeychain backupとApple Developer側のcertificate管理に依存

秘密鍵、password、production DB、実利用者の個人情報をrepositoryへ追加しません。
