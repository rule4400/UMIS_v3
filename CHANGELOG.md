# Changelog

すべての重要な変更をこのファイルに記録します。バージョンはSemantic Versioningに従い、本番利用の承認状態と単なる実装完了を分離します。

## [Unreleased]

### Fixed

- 評価・タグ／フォルダリネームの説明文が画面の最小高さを過大化し、サイドバーと操作ボタンが表示範囲外へ消える不具合を修正。
- 下部ステータスに実際のレイアウト領域を確保し、取り込み／評価／リネームの下部操作が重ならないよう修正。小さいウインドウの取り込み画面はコンパクトな3ペイン配置へ切り替える。
- 評価・ファイル選択・ワークスペース切替などのコマンドを前面の対応ウインドウに限定し、別の設定ウインドウから背景の素材を誤操作しないよう修正。評価できない理由もメニューに表示。
- 検索・種類・素材一覧変更時に非表示の選択をモデル内で同期解除し、上部選択件数と評価対象件数の不一致を解消。
- 再生不可の動画／音声、代替アイコン、簡易プレビューを区別して案内を表示し、無説明の代替画像表示を改善。

### Added

- 取り込み済みアーカイブ専用の「評価・タグ」workspace。Adobe XMP BasicのReject／未評価／1〜5つ星と、既存の名前付きタグを保持するFinderカラー操作を追加。
- Adobe XMP Toolkit SDK v2025.03を固定したUniversal 2静的bridge、embedded safe update、Camera RAW sidecar、未認定形式の衝突回避sidecarと互換性警告。
- ファイル名／相対path検索、種類filter、表示件数、表示中だけの一括選択、tile上のrating／color／metadata警告表示、rating keyboard shortcut。
- 1x／2x displayでtile同士を正確に1物理pixel離すNSCollectionView layout。
- VoiceOverからのpreview実行、Return／Spaceでのkeyboard preview、エラー理由／互換性注意／相対pathの読み上げ。

### Changed

- 旧「選別」フォルダへの素材複製機能を削除。選別状態は原本を増やさないrating／Finder color metadataで扱う方針へ変更。
- metadata mutation前にpreview playbackとthumbnail／metadata pipelineを停止してquiescenceを確認し、完了後にvisible thumbnailを再要求。
- 検索／種類フィルタ後の非表示選択を一括変更から除外し、処理中は別workspaceへ移動しても進捗と安全な中止操作を下部statusに維持。
- Finderカラーは凍結rootから保持したexact file descriptorのFinderInfo label bitだけを更新し、他のFinderInfoと名前付きタグを保持。色の付与／変更／解除を`fsync`と同一descriptor読戻しで確認。
- 評価用scanを取り込みprojectのcategory設定から分離。PSD／GIF／M4V／DNG／全対応Camera RAW／HEIC／MXF／R3D等をCoreの単一format inventoryから必ず表示し、未知形式は件数とsample pathを明示。
- asset／filter／合計byteのrevision snapshot、toolbar状態の一括計算、NSCollectionViewのcontent／metadata revisionとselection差分反映を導入。selection-only更新では全asset再filter・辞書比較・diffable reloadを行わず、thumbnail再開もvisible＋near-visibleだけに限定。
- Rating／Finderカラーの一括結果反映をID index付きO(N) reducerへ変更し、成功1件ごとの配列全探索と大量の`@Published`通知を廃止。
- 20,000件級のシーン割り当て／明示除外を一括更新し、シーン別件数・除外確認一覧・容量を変更時に一度だけ計算するprojectionへ変更。
- thumbnail／prefetch／previewの要求pixelサイズを実表示point寸法×backing scaleで決定し、1x displayで不要な2x decode・cacheを避ける。
- review scanの部分的な読取失敗／走査中変更を件数と匿名化した代表例として保持し、partial gridから無言で欠落しないUIへ変更。
- LAN Scene Catalogの取得／適用状態を親AppModelへ伝播し、別windowを含む共通排他gateとbutton活性へ即時反映。監査レポートの開始／完了／失敗も履歴workspaceのstatusへ表示。

### Safety

- removable／read-only／network archive、取り込み元とのpath重複、symlink／hardlink、scan後のroot／volume／file identity変更、カード初期化判定中の保存先変更をfail-closedで拒否。
- 同じstemを持つ複数Camera RAWが1つのAdobe sidecarを共有する場合は、誤ったrating共有を避けるためread／writeとも拒否。
- XMP safe updateで旧originalを上位読み戻し完了まで保持し、中断／cleanup異常時は暗号学的random名のdurable recoveryとして残す。次回scanと各一括書込み境界でアーカイブ全体を再検査し、復旧確認までRating／Finderカラーをfail-closedで停止。
- Adobe／Finderの通常writerとは`NSFileCoordinator`の1operationに必要なmedia／sidecar intentをまとめ、凍結rootからのdescriptor-relative capabilityと一致する場合だけ変更。
- recovery全root走査とlockをbatchごと1回に集約し、各assetは認可済みparent identityをO(1)で確認。Camera RAWの同stem衝突確認もdirectory全列挙を廃止し、フォルダ項目数に依存しないbounded descriptor lookupに変更。
- 評価／タグのscan・読込・書込中にカードの再接続を検出しても、取り込みUI状態を先に破棄せず安全境界の解除後まで再走査を保留。予期しない抜去の隔離世代は、新しいフルスキャンだけで解除。
- metadata operationがcommit後のreadback／fsync／cleanupでerrorを返した場合も、保持descriptor、parent、rootの事後identityを必ず検証し、境界違反を優先してfail-closed。
- Project削除を全workspace共通のexclusive-operation gateへ統合し、Rating／Finder保存、review scan、media quiescence、LAN同期、deferred card scan中の削除とUI上のno-op操作を拒否。
- file chooserが閉じた直後にexclusive-operation認可を再評価し、失敗する新review sourceの走査開始前に旧sourceの書込みcapabilityを失効。`/tmp`と`/private/tmp`の同一実体は検証済みの単一URL表記に固定する。
- 別windowの設定変更とmedia cache消去も全workspace共通のexclusive-operation gateに参加させ、review／media isolation／LAN／project処理との競合を拒否。
- media cache消去はfacade受付と全in-flight requestを停止してからmemory／disk／indexを消去し、停止状態のままAppModelへ返す。消去中にカード抜去や破壊操作の隔離世代が変わった場合は読取を再開せず、resumeのactor境界後にも再検証する。
- media pipelineの停止に単調revision tokenを発行し、遅れて完了した旧scanは自分が作った停止だけを条件付きで取り消す。後発のcache消去、review書込み、カード抜去隔離、または正常な新scanのresumeがrevisionを更新した場合は旧tokenを拒否する。
- 監査レポート書出しとcache消去中は自動カード再走査も保留し、modal panel後を含むすべての開始点で共通排他認可を再確認。
- 撮影日時のprogressive metadata解析中はcache消去をUI／実行境界の両方で保留。pipeline coordinator由来のcancelをmtime取得失敗として扱わず解析全体を中断し、取り込み計画時のfresh再抽出へ委ねる。
- cache消去開始時は表示中previewを閉じ、進捗／成功／失敗／隔離継続を設定画面内に表示。孤立したmedia隔離世代が残る不変条件違反でもresumeしない。
- cache使用量の非同期再計測をlatest-wins generationへ結び付け、消去前の遅い計測結果が消去後の表示を上書きしない。
- workspaceを切り替えても下部status barがcache消去、監査export、LAN処理を追跡し、spinner・処理名・最新LAN状態を表示する。
- 物理カードのscan中は公開用identityとは別のin-flight identity／scan世代で抜去通知を追跡する。scan結果の公開前と、抜去隔離後のmedia pipeline再開前後にDisk Arbitrationの現在identityと登録簿を再照合し、同一mount pathへの別カード差し替え、最終read直後の抜去、items scan中の抜去をfail-closedで隔離する。旧scanの非同期検証が遅れて返っても新scanをcancelせず、identity failure用の新隔離世代を最初のawait前に確立し、await後のstatus更新も所有世代が一致する場合だけ行う。隔離task自体が失敗した場合は「再起動が必要」という強い案内を後続の一般エラーで上書きしない。
- 抜去隔離を解消するfresh scanを中止しても、完全な隔離世代／taskを待つ「再スキャン」だけは再実行できる専用認可を追加。取り込み、初期化、Project変更、metadata更新等の一般操作は隔離中の禁止を維持。
- 表示phaseとは別に、実際にunwindしていない全ingest scan taskをID集合で追跡。中止直後の非同期scanner／volume activity残存中は通常操作と手動再scanを開かず、複数の旧scanが残る場合も最後のTaskが閉じるまでstatus barに「スキャン終了待機中」とspinnerを表示。メディア隔離taskの失敗もprocess-lifetimeの専用状態で保持し、遅れて到着したカードappearance／再抜去／一般scan errorが再起動必須の案内と隔離を解除しない。
- ユーザーが「評価なし」を選んだ場合は、sidecar未作成のRAW／未認定形式にも明示的な`xmp:Rating=0`を保存し、readbackのexplicit-rating flagまで検証。「未設定」と明示0の区別をembedded／sidecarの両方で保持。

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
