# Adobe XMP Toolkit integration

このディレクトリは、UMIS が Adobe 互換の `xmp:Rating` を読み書きするための、固定バージョンの Adobe XMP Toolkit、純 C ABI ブリッジ、Universal 2 静的 XCFramework、再現ビルド資料を管理します。

## 構成

- `AdobeXMPBridge.xcframework`: SwiftPM から利用する macOS 用静的 XCFramework。単一スライスの static framework 形式で `arm64` と `x86_64` を含みます。
- `Bridge/`: C++ 例外を ABI 境界の外へ出さない純 C API と module map。
- `Scripts/build_xcframework.sh`: 固定した一次配布元を取得し、SHA-256 を検証してビルドします。
- `Scripts/verify_xcframework.sh`: XCFramework の必須ファイル、Universal 2、`Artifacts.sha256` を検証します。
- `SourceInputs.sha256`: bridge、public header、module map、patch、build/release scriptのreview済み入力を固定します。
- `Patches/`: v2025.03 に対する、現在の Apple SDK と macOS 13 を対象にするための最小パッチ。
- `Licenses/`: 使用した一次配布物に収録されているライセンス原文。
- `DEPENDENCIES.md`: バージョン、取得元、SHA、配布上の位置付け。
- `BUILDING.md`: 再構築と検証の手順、コンパイル条件。
- `SAFETY.md`: safe update、ファイル同一性、形式別フォールバックの境界。

## 重要な境界

この XCFramework は、ファイル拡張子だけを根拠に「対応」を宣言しません。読み書きの都度、Adobe の smart handler が実ファイルを受理すること、埋め込み XMP の handler であること、`CanPutXMP` が成功すること、および safe update が利用できることを確認します。満たさない場合はエラーを返し、UMISCore が形式と容量に応じて sidecar を選択します。

公開 C ABI の status 型は `uint32_t` に固定しています。Adobe の macOS 静的ライブラリとの ABI を合わせるため bridge translation unit は `-fshort-enums` でコンパイルされるので、関数の返り値を C enum にすると Swift 側と bridge 側で幅がずれる可能性があります。status 定数は匿名 enum、関数の引数・返り値は固定幅の `UMISXMPStatus` として分離しています。

公開ABIは現在version 3です。アプリが使用する `umis_xmp_*_at` は、借用した親directory FDと単一leaf名を受け取り、Adobeの公式static-build `OpenFile(XMP_IO *)` に接続します。media、safe-update temp、readbackの権限はすべて同じdirectory capabilityに固定され、表示用pathをmutation権限として再解決しません。pathを受け取る公開関数は互換試験用のprobe/readだけで、path権限によるmutation exportは存在しません。

ABI v3のdescriptor writeは二段階commitです。bridgeは暗号学的randomなmode-`0700` recovery directoryを作り、mode-`0600`のpending／sealed／cleanup manifestをdurableに管理します。新しいreplacement partialはmode-`0600`で排他的に作成してから元metadataをdescriptor間で複製し、swapでrecovery側へ移った旧original inodeは元のmode、ACL、xattrを保持します。Swift/Coreが同じparent FD+leafで`xmp:Rating`とpost-fingerprintを独立にreadbackした後だけ、`umis_xmp_finalize_recovery_at`がnoncritical artifact、旧originalの順でcleanupします。旧original unlink後は`manifest.cleanup.json`の`committedOriginalRemoved`状態を同期し、sealed、pending、cleanup-state manifestの順で消すため、途中で停止しても最も正確な状態を最後までInspectorへ残します。これにより旧originalが残る失敗と、commit済みだがcleanup residueだけが残る警告を区別できます。全てのnonzero tokenは成功・失敗を問わず1回だけconsumeします。

アプリ側はrating batchごとに凍結rootへ非blocking exclusive `flock`を保持し、recovery namespaceを1回O(N)走査します。cleanな完全scanだけが短命authorizationを発行し、各assetはO(1)でparent identityを確認します。書込み・検証失敗またはcleanup warning後は残りを停止し、次回はfresh root scanから再開します。case-sensitive volumeのRAW衝突検出は、allowlistされた拡張子の全ASCII case variantだけを`fstatat`する固定上限方式です。

通常の外部applicationとは、Appの単一operation内で`NSFileCoordinator`とdescriptor capabilityを併用します。embedded XMPは同一documentへの通常write intent、Finder colorは`contentIndependentMetadataOnly`、sidecarはmedia readと既存／新規sidecar writeの複数intentを一括coordinateします。Finder colorはpathや`/dev/fd` URLではなく、exact held FDの`com.apple.FinderInfo`を`fgetxattr`／`fsetxattr`して3-bit label領域だけ変更し、`fsync`と同一FD readbackを行います。より詳細な脅威モデル、cleanup状態、形式別の非保証範囲は`SAFETY.md`を参照してください。

静的アーカイブは `AdobeXMPBridge.framework/AdobeXMPBridge` という static framework ペイロードで XCFramework に収録しています。これは SwiftPM/XCBuild で Universal 2 バイナリを安定してリンクするためのパッケージ形式であり、dynamic framework に変換したものではありません。

チェックイン済み artifact は v2025.03 と下記の固定依存物から、macOS 13 を deployment target として作成されています。入力は固定していますが、Xcode、Apple SDK、clang、ar/libtool の差により別ホストの出力が bit-for-bit 同一になるとは限りません。配布対象として採用した実 artifact の同一性は `Artifacts.sha256` で固定します。

## クイック検証

リポジトリのルートから実行します。

```sh
Vendor/AdobeXMP/Scripts/verify_xcframework.sh
```

再ビルドする場合は、既存 artifact を置き換える処理を含むため、差分を確認できる作業ブランチで実行してください。

```sh
Vendor/AdobeXMP/Scripts/build_xcframework.sh
Vendor/AdobeXMP/Scripts/verify_xcframework.sh
```

再ビルド後は `Artifacts.sha256` を意図的に更新し、新旧の hash、ビルド環境、依存物、パッチ差分をレビューしてください。verifierはartifact hashだけでなく、source/artifact headerのbyte一致、ABI v3、arm64/x86_64各sliceの必須C symbol、固定commit/SHA、DOM無効・macOS 13 policy、`SourceInputs.sha256` も検証します。
