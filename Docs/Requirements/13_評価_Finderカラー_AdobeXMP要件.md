# 評価・Finderカラー・Adobe XMP要件

更新日: 2026-08-29

## 1. 製品判断

Swift版UMISでは、旧「選別」フォルダを作成して素材を複製する機能を提供しません。選別、評価、他アプリとの連携は、原本の二重化ではなく次のメタデータで行います。

- Adobe XMP Basic `xmp:Rating`: Reject（`-1`）、未評価（`0`）、星1〜5
- macOS Finderカラー: Finderと同じlabel number `0...7`

FinderカラーとAdobe `xmp:Label`は別の仕組みです。UMISは両者を自動変換しません。既存の名前付きFinderタグは保持します。

Finderカラーの表示名と色は公開`NSWorkspace.fileLabels`／`fileLabelColors`から取得します。書込みはpath差し替えで別fileを変更しないよう、凍結rootから解決したfile descriptorの`com.apple.FinderInfo`にある3-bit label領域だけを更新します。他のFinderInfo byteと名前付きタグ`_kMDItemUserTags`は保持し、`fsync`後に同一descriptorから読み戻します。

## 2. 対象と安全境界

評価ワークスペースは取り込み元と独立したアーカイブ状態を持ちます。次の対象には書き込みません。

- `volumeIsRemovable == true`のSDカード等
- `volumeIsEjectable != false`、`volumeIsInternal != true`、または媒体種別を取得できないvolume
- 現在の取り込み元、またはその親／子folder
- read-only volume
- symbolic link、hard link、非regular file
- スキャン後にidentityが変わったfileまたはroot
- 検証済み取り込みreceiptが残り、カード初期化の可否が未確定の期間

評価用scanは次を凍結します。

- rootのcanonical URL、device、inode、volume UUID、local／internal／ejectable／removable／read-only状態
- 各assetの`SourceVolumeID`、device、inode、size、mtime
- removable／read-only状態

評価用scanの拡張子表は取り込みprojectのcategory有効／無効や旧設定から独立させ、Coreの`AdobeXMPRatingService.formatSupport`を単一の正本とします。JPEG／TIFF／DNG／PSD／PNG／GIF、MOV／MP4／M4V／M4A、全allowlist Camera RAW、HEIC／HEIF／MXF／R3Dに加え、従来表示していた主要動画・静止画・音声形式を全有効categoryへ分類します。安全に分類できないregular fileは黙って消さず、除外件数と最大20件のrelative pathをUIで示します。

読み書きの直前と直後にこれらを再取得し、mount pathが同じでもdevice、inode、volume UUID、媒体属性、file fingerprintのいずれかが異なればfail-closedにします。nilの媒体属性を安全側の`false`へ読み替えません。metadata mutationは凍結rootから`openat(O_NOFOLLOW)`で全ancestorを辿ったparent directory descriptorと単一leaf名だけをCoreへ渡し、path文字列を権限として使いません。

Adobe等の`NSFilePresenter`に対応する通常applicationとは`NSFileCoordinator`で同期します。embedded XMPは同一documentの論理内容更新なので通常のwrite intent、Finderカラーは`contentIndependentMetadataOnly`、RAW sidecarはmedia read intentと解決済みの既存／新規sidecar write intentを1回のcoordinate callにまとめます。内部実装がtemp+atomic swapでも、同一document内容の更新に`.forReplacing`を指定しません。Coordinatorが渡すURLがlive capabilityと一致しなければ、新しいpathへ追随せずfail-closedにし、accessor内でrouteとsidecar planを再計算します。

safe updateのatomic swap後も、旧originalまたは旧sidecarをすぐに削除しません。同一volume上の暗号学的random名の保護recovery directoryへ移し、更新後identityとRatingの上位読み戻しが成功するまで保持します。directoryは`0700`、pending／sealed／cleanup manifestとfresh replacement partialは作成時`0600`とします。replacementへ元metadataを複製した後のmodeは原本に一致し、保護した旧original artifactは同じinodeのままACL、permission、xattr等の元metadataを保持します。cleanup直前にtargetとrecovery fileのdevice、inode、size、mtime、ctime、link countを再検証し、noncritical artifactの後、旧originalを最後に削除します。旧original unlink後は、`manifest.cleanup.json`へ`committedOriginalRemoved`とcommitted witnessをdurableに記録し、sealed、pending、cleanup-state manifestの順で削除します。途中で停止した場合も、復元不能を示すcleanup状態を古いmanifestより長く保持します。

上位readback、target、recovery witnessのいずれかが不一致なら自動cleanupしません。旧originalがまだlink済みならstructured errorとして残りbatchを停止します。旧originalがunlink済みと証明され、cleanup manifest等のresidueだけが残る場合は、現在値をcommit済みsuccessとして返せますが、`recoveryAttentionRequired`警告を付けて同じく残りを停止します。Inspectorはcleanup、sealed、旧形式、pending manifestの順で確認し、復元可能なoriginalの有無を区別します。crash後の残留recoveryは次回scanで検出し、無言で無視または自動削除しません。

macOS 13の公開APIには、保持中file descriptorのexact inodeを条件付きでunlinkする機能がありません。そのためcleanupの安全契約は、Coordinatorに従う通常applicationと、random recovery leafを推測・改変しない非悪意processを対象にします。同一user権限の悪意processがrandom leafを列挙し、検査とunlinkの間に入れ替える攻撃まで絶対に防ぐには、recovery backupを恒久保持するしかありません。これは容量・性能要件と両立しないため、対象外の脅威として明記します。

## 3. Adobe XMPの形式別方針

Adobe XMP Toolkit SDK `v2025.03`を完全コミットに固定し、DOMを無効化したUniversal 2静的XCFrameworkを純C ABI越しに利用します。公開ABIはversion 3、statusは`uint32_t`固定とし、C++例外はSwift境界へ出しません。pathを受け取るexportは互換試験用probe/readだけとし、mutationはparent directory FD+単一leafの`umis_xmp_write_embedded_rating_at`と、同じcapabilityを要求する二段階finalizerだけに限定します。

| 形式 | 初期方針 |
|---|---|
| JPEG、TIFF、DNG、PSD、PNG、GIF | Toolkitがsmart handler、embedded XMP、safe updateを確認できる場合だけ埋め込み |
| MOV、MP4、M4V、M4A | smart handler、safe update、空き容量、サイズ制限を全て満たす場合だけ埋め込み |
| CR2、CR3、NEF、ARW、RW2、ORF、RAF等 | media本体を変更せず`stem.xmp` sidecar |
| HEIC／HEIF、単体MXF、R3D、未知形式 | 認定したhandlerがない限り埋め込みを行わない。sidecarを使う場合は`filename.ext.xmp`で同stem衝突を避ける |

RAW+JPEGのように同じstemのprimaryが複数あっても、JPEGがRAW用`stem.xmp`を読み書きしてはなりません。複数のmanufacturer RAWが同じ`stem.xmp`を所有し得る場合も拒否します。case-sensitive volumeでは、allowlistされたRAW拡張子の全ASCII case variantだけをparent FDから`fstatat`し、directory全列挙に依存しない固定上限で`A900.CR3`と`A900.NEF`等を検出します。sidecar access前後で再検査し、保存方式を解決できない場合は一部互換と表示せずエラーにします。

embedded書込は`kXMPFiles_UpdateSafely`を必須とし、書込み後にfileと親directoryを同期し、再openしてRatingを読み戻します。元のXMP、Exif、IPTC、ACL、permission、無関係なxattrを保持します。

## 4. UIと性能

- 絞り込みと複数選択を維持し、「表示中を選択」は非表示assetを選択しない
- Reject、未評価、数字付き星1〜5を視覚的に区別する
- Finderカラー名と色は`NSWorkspace.fileLabels`／`fileLabelColors`から動的に取得する
- tileの横／縦間隔はdisplay backing scaleを使い、1物理pixelにする
- metadata読込は並列数を制限し、再読込の重複実行を禁止する
- metadata書込batchの直前にrecovery namespaceをrootから1回だけO(N)完全走査する。nonblocking exclusive advisory `flock`を凍結rootへ保持し、cleanかつ非truncated時だけ短命directory authorizationを発行する。batch中の各assetはO(1)のparent identity確認にし、任意のwrite／verify失敗またはcleanup warningでauthorizationを無効化して残りを停止する
- cancellationはstructured taskへ伝播し、旧generationの結果をUIに適用しない
- metadata異常はtileの警告とtooltipで理由を表示する
- thumbnail decode／previewとmetadata writeは分離し、書込み前にAVPlayerをitemからdetachしてasset loadingをcancelし、native media pipelineのquiescence完了を待つ。再開時は停止epochを更新してvisible thumbnailを再要求する
- source asset／検索filter／合計byteをrevision snapshotへ保持し、selection-only updateでは全assetの再filter、ID map再構築、巨大metadata collectionの同値比較を行わない
- NSCollectionViewはcontent revision時だけcontent map、metadata revision時だけstatus stateを更新し、selectionはAppKit実状態との差分だけを反映する。thumbnail世代変更時は全identifierをreloadせずvisible itemを再構成し、前後1画面だけprefetchする
- 一括書込み結果はasset ID indexを1回作ってO(N + result count)でreduceし、各published collectionを最大1回だけ反映する
- tile thumbnail／prefetchは実表示point寸法×backing scaleでrequest pixelサイズを決定し、previewも同じpolicyと上限で過剰decodeを防ぐ
- scanで一部fileが読み取れない、または走査中に変更された場合は、件数と最大20件の匿名化したrelative path／理由をpartial gridと並行表示する
- シーン別件数、除外確認一覧、除外容量はSwiftUI body評価ごとに全件走査せず、対象collection変更時のprojectionを再利用する

## 5. 相互排他とカード初期化

次は同時に実行しません。

- ingest scan／copy／verification
- folder Copy and Rename
- review scan／metadata read／metadata write
- preview playbackとmetadata write
- safe eject
- card erase preparation／final verification／erase
- Project作成／読込／削除、設定変更、media cache消去、監査レポート書出し
- LAN Scene Catalogの取得／適用／role変更

RatingやFinderカラーの変更は、取り込み成功の代わりになりません。カード初期化の許可は従来どおり、非空Required Set、全deliveryのSHA-256、durable receipt、最終全再読検証、物理媒体identity、一回限りtokenだけで判定します。

予期しないカード抜去後のfresh scanを利用者が中止した場合、隔離latchと隔離世代／taskはfail-closedで保持します。その状態では、完全な隔離世代／taskが存在し、他の排他操作や検疫がなく、先行scan taskが実際にunwindした場合に限り、隔離解消用のソース選択／drop／再スキャンを許可します。隔離task自体が失敗した場合はその起動中の永続失敗とし、遅れて到着したcard appearanceを公開または自動scan保留せず、再抜去で隔離処理を再試行せず、アプリ再起動まで全操作を禁止します。

## 6. 必須試験

- Rating `-1...5`の読み書き、未設定と0の区別
- sidecarが未作成のRAW／fallback形式へ明示0を指定した場合も`xmp:Rating=0`を新規保存し、`hasExplicitRating == true`のreadbackを必須とすること
- RAW+JPEG、RAW+HEIC、MOV+WAV、同stem異形式の保存先非衝突
- case-sensitive APFS実volumeで大文字／小文字RAW拡張子の同stem衝突を両方向に拒否し、2,048件以上の無関係siblingがあってもlookup回数が固定上限内であること
- 破損XMP、外部entity、過大packet、symbolic link、hard link
- partial差し替え、swap後target差し替え、ACL／Finderタグのctime変更、recovery cleanup競合
- crash後の`manifest.pending.json`／`manifest.sealed.json`／`manifest.cleanup.json`検出、自動削除禁止、`committedOriginalRemoved`時の復元不可表示、UI警告
- scan後のasset inode置換、root置換、同mount pathへの別volume再mount
- operation自身がerrorを返す経路でも、処理後のheld descriptor／parent／root検証が実行され、境界errorが優先されること
- 書込み直前のremovable／read-only変化
- Finder label `0...7`のexact-FD往復、FinderInfoのlabel以外全byte、既存の名前付きFinderタグ、file contentsの保持
- レビュー書込み中にingest／rename／eject／eraseが開始できないこと
- レビュー書込み中にProject削除／読込／新規作成が開始できず、削除成功後は新規project stateへ一貫して遷移すること
- 1x／2x displayでtile間隔が1物理pixelであること
- 20,000件以上でselection-only更新がcontent／metadata全件経路へ入らず、一括結果反映がO(N²)にならないこと
- 20,000件のシーン一括割り当て／明示除外がcollectionごとに最大1回だけpublishされ、シーン件数／除外一覧／容量projectionが正しいこと
- file chooserのevent loop中に別操作が開始した場合の再認可拒否、失敗する新source指定時の旧source capability失効、`/tmp`／`/private/tmp`の同一実体と異なるrootの識別
- assetを部分的に返すscan結果にissueを混在させ、件数／代表例の表示と次回scan開始時のclearを確認すること
- 1x／2xの実表示point寸法からthumbnail／preview request pixelサイズが決定され、異常値と上限がboundedであること
- LAN処理、監査export、media cache消去中は別windowの操作と自動カードscanを保留し、cache消去中の抜去世代を誤ってresumeしないこと
- 通常root scan／items scanの最終read後から結果公開までに物理カードを抜去した場合も、in-flight挿入世代、Disk Arbitration current identity、registry identityの不一致で結果公開を拒否すること
- 抜去隔離後のfresh scanで、media pipelineのresume前後にカードが消失・差し替えされた場合は旧隔離を解除せず、resume済みなら直ちに再停止して新しい隔離世代へ移行すること
- fresh scan中止後は、隔離latch／世代／taskが全て一致する場合だけ再スキャン操作に到達でき、一部状態、別操作中、検疫中、自動カードスキャン保留中は拒否すること
- Adobe Bridge、Lightroom Classic、Camera Raw、Photoshop、Premiere Proとの双方向確認
- Apple Silicon実機、Intel Mac実機、macOS 13以降、Developer ID署名／公証済みbuild

Adobe製品での実相互運用、実Intel Mac、実撮影素材corpusの検証が終了するまで、対応形式全体をproduction完了と表示しません。
