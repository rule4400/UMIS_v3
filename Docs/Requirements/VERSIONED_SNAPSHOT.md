# Requirements snapshot

このdirectoryは2026-08-26時点のUMIS現行解析・Swift再設計・SD管理連携要件を、実装commitと一緒にversion管理するsnapshotです。

- 元資料: `workspace/UMIS_Swift_再設計_解析`
- 実装は要件IDとtest名を可能な範囲で対応させます。
- 要件変更はコード変更と同じpull requestでreviewし、release tag時点のsnapshotを保持します。
- 文書内の`legacy-source/`等は非公開証拠への論理参照です。GitHub上に個人の絶対パスやlink先source archiveを同梱しません。
- production secret、Apple署名秘密鍵、VPS credential、production DBは要件snapshotへ含めません。
