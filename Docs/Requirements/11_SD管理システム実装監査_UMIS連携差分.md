# SD管理システム実装監査とUMIS連携差分（公開版）

更新日: 2026-08-26  
詳細なsource path、個別route、内部構成、脆弱性の再現手順は、public repositoryへは収録しません。

## 1. 結論

受領したSD管理システムのhandoffは、現行のデータモデル、業務フロー、実装境界を静的解析し、隔離環境でbuild／lint／smoke validationを行うためには十分でした。同じsource一式の再送は現時点で不要です。

一方、現行システムにはUMISネイティブアプリ向けのversioned integration APIがありません。browser用の認証済みrouteをSwiftアプリから模倣して呼ぶことは、認証、会場scope、再送、監査の境界を壊すため禁止します。専用APIとstaging契約が完成するまで、UMISのproduction buildは`DisabledSDManagementGateway`だけを使用します。

## 2. 確認できた範囲

- handoffのarchive／manifest／source整合性
- 隔離した一時環境でのbuild、lint、既存smoke test
- Card、撮影者、Scene、利用履歴の概念モデル
- 取り込み完了をSD管理側へ反映する将来adapterに必要な差分
- production secret／DB／uploadsがhandoffに含まれていないこと

本番VPSへのSSH、production URLへのAPI call、実DBへの接続、deploy、restore、destructive operationは実施していません。したがって、handoffの再現成功は「現在のVPSが健全」または「連携APIが完成」を意味しません。

## 3. production連携の必須blocker

### SDI-BLK-001: 専用service authentication

Native App用credentialの発行、会場／project scope、失効、rotation、監査、rate limitが必要です。管理者Cookieや個人accountのcredentialをアプリに格納しません。

### SDI-BLK-002: stable external identityとversion

Card、撮影者、Scene、利用recordに、名前や表示番号の変更で再利用されないopaque IDが必要です。responseにはentity version／revisionを含め、更新競合を検出します。

### SDI-BLK-003: idempotent inbox／receipt

UMISのlocal outboxはat-least-once送信です。serverは`eventID + payload digest`をdurableに保存し、同一eventの再送に同一結果を返す必要があります。timeout後の再送を不正操作として一括拒否するAPIは使用できません。

### SDI-BLK-004: `ingest_verified`と`ready_for_reuse`の分離

保存先への取り込み検証完了と、物理カードを再利用可能にする判定は別状態です。VPSのresponseがローカルerase tokenを発行したり、コピー検証を省略したりすることはできません。

### SDI-BLK-005: versioned contractとstaging

OpenAPI、error code、timeout、retry／`Retry-After`、batch上限、payload上限、clock skew、maintenance、backward compatibility期間を固定したstagingが必要です。contract testとfake server fixtureをSwift／serverの両側で共有します。

### SDI-BLK-006: migration／backup／restore証拠

integration tableとDB invariantはordered migrationで導入します。consistent DB／uploads backup、integrity check、restore rehearsal、restore epoch、rollback／forward-fix手順がない状態でproductionへdeployしません。

## 4. 一般化した重大監査結果

証拠付き詳細は非公開のsecurity review recordで管理します。public repositoryでは次の欠陥classだけを共有します。

- browser session向け境界とmachine-to-machine API境界の分離不足
- retry／ACK喪失／replayを安全に扱うdurable idempotency不足
- mutableな表示値／local IDとexternal identityの混同
- application検査だけに依存する業務不変条件とDB constraintの不足
- destructive／restore／undo操作の再認証、actor記録、改変検知、会場隔離の追加review必要
- backupの機密性／完全性／復元網羅性を証明するtest不足
- 開発／desktop配布経路とproduction VPS経路の安全条件の混同
- health、migration、disk capacity、outboxを含む運用監視の不足

これらは「UMIS連携を後づけで足せば解決する」問題ではありません。SD管理側のAPI／DB／認証／運用と、UMIS側adapterの両方を同じcontractで改修する必要があります。

## 5. UMIS側で現在実装する境界

```text
verified local ingest transaction
  -> canonical redacted event
  -> durable local outbox
  -> DisabledSDManagementGateway (productionの現状)
  -> future versioned adapter
  -> authenticated idempotent server inbox
```

- eventにlocal absolute path、filename、個別file hash、erase capabilityを含めません。
- Card Noは先頭zeroを保持し、product-controlledな正規化規約が確定するまで勝手に数値化しません。
- server停止中もlocal ingestをrollbackせず、outboxから再送します。
- auth失敗、schema mismatch、unknown responseはdead-letter／operator reviewへ移し、ローカル検証を成功扱いしません。
- LAN Scene CatalogとVPS Scene projectionは同時write authorityにしません。authority、revision、tombstone、external mappingを明示します。

## 6. 必要な追加資料と判断

実装再開に必要な回答は[12_SD管理連携_不足資料_判断チェックリスト.md](12_SD管理連携_不足資料_判断チェックリスト.md)で管理します。特に次が未確定です。

1. Card Noの文法、一意scope、ラベル交換／再利用規約
2. Sceneの正本authorityとLAN master／VPS間のprojection運用
3. `ingest_verified`後の業務状態と`ready_for_reuse`の決定者
4. service credentialのowner、rotation、revoke、incident response
5. staging URL、OpenAPI、fixture、error／retry契約
6. 現行VPSのconsistent backup、restore drill、migration方針
7. VPSへ保存してよいsummary、retention、監査閲覧権限

## 7. production受入条件

- 実secretを使わないfake server contract testが全て成功する。
- stagingでduplicate event、ACK喪失、timeout、rate limit、auth revoke、server restoreを再現する。
- 会場／project isolationをAPIとDBの両方で証明する。
- backupからのrestore後にepoch変更を検出し、clientが自動的に古いresponseを採用しない。
- SD連携が停止／破損／悪意的な状態でも、local copy verification、safe eject、card erase gateが弱まらない。
- security review、privacy review、restore rehearsal、運用runbook、rollback／forward-fixが承認される。

## 8. 公開情報境界

詳細監査はローカルのGit対象外`Artifacts/private-audit/`と、別途のaccess-controlledな証拠庫で保管します。ローカル`Artifacts/`だけはbackupではないため、製品責任者が保管先とretentionを決定する必要があります。

public repositoryには次を入れません。

- production URL／IP／domain、SSH情報、credential／private key
- production DB／uploads／backup実体、利用者の氏名／email／電話／撮影情報
- 個別routeの攻撃手順、未修正脆弱性の詳細な再現手順
- source archive、Git bundle、ローカル絶対パス

