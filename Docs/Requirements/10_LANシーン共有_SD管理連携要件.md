# LANシーン共有・SD管理システム連携要件

## 1. 結論

LAN内のScene Catalog共有には`Network.framework + Bonjour`を使用します。ただしBonjourは同一LAN上のマスター候補を発見する手段だけです。マスターの権威、端末信頼、暗号化、revision、競合解決はアプリケーション層で管理します。

受領したVPS上のSD管理システムはNext.js／Prisma／SQLiteのbrowser applicationで、現行routeはCookie／Origin前提です。UMIS向けversioned external API、service auth、server idempotencyは未実装なので、既存browser APIをSwiftから直接流用しません。`SDManagementGateway`、ローカルassignment cache、永続outboxの背後へ隔離し、取り込みcore、Scene Catalog、カード初期化serviceを変更せずadapterだけを差し替えられる構成にします。

現行実装の根拠、重大欠陥、必要なserver差分は[11_SD管理システム実装監査_UMIS連携差分.md](11_SD管理システム実装監査_UMIS連携差分.md)、未確定の業務判断は[12_SD管理連携_不足資料_判断チェックリスト.md](12_SD管理連携_不足資料_判断チェックリスト.md)を正本とします。

絶対条件:

1. LAN masterやVPSは、ローカルのcopy verificationやerase可否を決定しない。
2. Card Noという業務IDと、現在挿入されている物理media identityを分離する。
3. 1 projectにつきScene Catalogの正本は1つにする。
4. 自動master選挙、last-write-wins、表示名一致による統合を行わない。
5. network更新は実行中のimmutable `IngestPlan`を変更しない。

## 2. Authority matrix

| 情報／判断 | 正本／最終決定者 |
|---|---|
| Scene Catalog | projectごとに明示した1台のLAN master |
| client表示 | 最後に署名検証成功したsnapshot |
| asset→scene assignment | 取り込み開始時のlocal immutable plan |
| コピーの正しさ | local Ingest EngineのSHA-256 receipt |
| card erase可否 | local Erase Gate |
| 挿入mediaの実体 | Disk Arbitration中心のlocal Volume Monitor |
| Card No／業務assignment | SD管理システム＋local operator confirmation |
| ingest実績 | local journalが一次事実、VPSはmirror |
| SD管理status delivery | durable outbox＋remote acknowledgement |

VPSを将来Scene Catalog正本へ変更する場合は、project単位のauthority mode migrationとして扱います。LAN masterとVPSを同時に書込み正本にしません。

process内の可変ownerも`SceneCatalogStoreActor`一つに限定します。`Project`は`catalogID`、`authorityMode`、採用中`CatalogVersionRef`だけを持ち、`ProjectStoreActor`、UI、sync actorがscene rowを直接更新できない型境界にします。client側は署名検証済みsnapshotのread-only cacheだけを持ちます。

## 3. 共有するdataと共有しないdata

### 3.1 初版で共有する

`SceneCatalogSnapshot`:

- project ID
- catalog ID
- schema version
- scene ID
- day index／day label
- scene number／code
- scene display name
- sort order
- active／archived／tombstone
- catalog revision
- published time
- publisher authority

必要なら同じsnapshot familyに、会場名や撮影日label等の`SharedProductionProfile`を追加できます。ただしfieldごとにschemaと共有scopeを明示します。

### 3.2 共有しない

- 各Macのdestination path／security-scoped bookmark
- local cache path／cache data
- UI size、window state、thumbnail size等のlocal preference
- Apple／VPS credential
- card erase token
- copy journal／個別file hash
- file path／filename／media content
- operator login name
- clientの実行中selection
- private diagnostic log

Scene Catalog共有は小容量metadata同期です。動画、写真、thumbnail、proxyをMac間転送する機能ではありません。

# Part A：LAN Scene Catalog

## 4. Transport

### 4.1 Native stack

| Role | API |
|---|---|
| discovery | `NWBrowser`＋Bonjour descriptor |
| advertise／listen | `NWListener`＋Bonjour service |
| connection | `NWConnection` |
| encryption | `NWProtocolTLS.Options` |
| identity／trust | Security framework＋Keychain |
| state isolation | `SceneCatalogSyncActor`／`SceneTransport` protocol |

service type暫定値:

```text
_umis-scene._tcp
```

AppleのNetwork frameworkはBonjour serviceの広告・検索とTLS listenerを提供します。[NWBrowser Bonjour descriptor](https://developer.apple.com/documentation/network/nwbrowser/descriptor-swift.enum) / [NWListener Service](https://developer.apple.com/documentation/network/nwlistener/service-swift.struct)

### 4.2 Bonjourの責務制限

Bonjour TXT recordへ含めてよいもの:

```text
protocolMajor=1
role=master
pairing=open|closed
capability=snapshot
```

含めないもの:

- project／会場／scene／photographer名
- Card No
- token／certificate／key
- file path／filename
- ingest status
- detailed host information

Bonjour instance name、Mac名、IP addressはidentityやtrust rootにしません。同名serviceを偽装できる前提で設計します。

### 4.3 Discovery failure

別VLAN、client isolation、mDNS禁止、VPN等ではBonjour discoveryが失敗し得ます。

- LAN-TRANS-001: discovery failureとconnection failureを区別する。
- LAN-TRANS-002: discovery不能でもlocal ingestを継続できる。
- LAN-TRANS-003: 将来、招待file／QR／manual hostを追加可能にする。
- LAN-TRANS-004: manual endpointでもTLS fingerprint検証を省略しない。
- LAN-TRANS-005: 初版でpeer-to-peer Bonjourを自動有効にしない。

### 4.4 Wire envelope

custom length-prefixed message over TLSの初期案:

```text
WireEnvelope
  magic
  protocolMajor／Minor
  messageType
  requestID
  signedPayloadBytes
  detachedSignature { algorithm, keyID, signatureBytes }

SignedPayloadBytes（canonical encoding）
  domainSeparator = "RINKAN-UMIS-SCENE-CATALOG-V1"
  protocolMajor／Minor
  messageType
  projectID／catalogID
  authorityID／authorityEpoch／revision
  payloadLength
  payloadSHA256
  payloadBytes
```

初版のsnapshot `payloadBytes`はRFC 8785 JCSでcanonicalizeしたUTF-8 JSON（BOM／末尾改行なし）へ固定します。`SignedPayloadBytes`のcanonical bytesは、domain separatorの固定ASCII 28 bytes、UInt16 big-endianのprotocol major／minor／message type、各16-byte UUIDのRFC 4122 network order、UInt64 big-endian revision、UInt32 big-endian payload length、32-byte `payloadSHA256`、`payloadBytes`をこの順で連結したものです。encodingやfield widthの変更はprotocol major更新を必要とします。

`payloadSHA256 = SHA256(payloadBytes)`を唯一のsnapshot payload digestとします。digest fieldは`payloadBytes`の外側にあり、署名対象のheaderへ含まれるため自己参照しません。受信側はlength確認、payload全byteのSHA-256再計算、digest一致、detached signature検証、schema decodeの順に処理します。

- maximum message 1MiBを初期値とする。
- length、array count、string length、UTF-8、enumをparse前に検査する。
- protocol major不一致は`upgradeRequired`。
- minorはcapability negotiation。
- handshake、read、write、idle timeoutを設定する。
- slow client、巨大message、接続stormへ上限を設ける。
- signatureは上記`SignedPayloadBytes`のcanonical exact bytesへ掛け、signature field自身を署名対象へ含めない。domain separatorとcontext fieldにより別message／projectへの再利用を拒否する。
- 初版catalog署名algorithmはCryptoKitのEd25519（`Curve25519.Signing`）へ固定し、algorithm negotiationによるdowngradeを許可しない。変更はprotocol major更新とmigrationを必要とする。

### 4.5 固定test vector

encoder、digest、Ed25519実装の言語間差異を検出するため、次をprotocol v1の固定vectorとします。test private seedは`00 01 ... 1f`の32 bytesで、test bundle以外へ入れません。

```text
protocolMajor = 1
protocolMinor = 0
messageType = 1
projectID bytes = 11 × 16
catalogID bytes = 22 × 16
authorityID bytes = 33 × 16
authorityEpoch bytes = 44 × 16
revision = 1
payloadLength = 312
payloadBytes（次の1行をUTF-8、末尾改行なし）:
{"authorityEpoch":"44444444-4444-4444-4444-444444444444","authorityID":"33333333-3333-3333-3333-333333333333","catalogID":"22222222-2222-2222-2222-222222222222","generatedAt":"2026-01-01T00:00:00Z","projectID":"11111111-1111-1111-1111-111111111111","protocolVersion":1,"revision":1,"scenes":[],"schemaVersion":1}
payloadSHA256 = 4a8243c7296e82c59586b64403a609180c29b816b677183ca0415ee3780b2e45
Ed25519 public key = 03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8
detached signature = 0e9939e5cc01b5e6cb56737c5a81fed9ba7fdbd288a2097eff9a4ef2bfbd650efd2226a47e1c4f77a6bceec91005da062482a627a537b2142a992bffe67d0001
```

Swift側と独立test verifierの双方が、同じcanonical bytes、digest、signatureを生成／検証することをrelease gateにします。1 byte変更、field順変更、UUID endian変更、digest差替えは必ず失敗させます。

## 5. Scene data model

```text
SceneRecord
  projectID UUID
  sceneID UUID
  dayIndex Int
  dayLabel String
  sceneNumber String
  name String
  sortKey String
  entityVersion UInt64
  lifecycle active|archived|tombstone
```

- LAN-DATA-001: scene IDは改名、移動、並べ替え、day変更後も不変。
- LAN-DATA-002: scene名／番号をidentityにしない。
- LAN-DATA-003: 削除はtombstoneとしてrevision historyに残す。
- LAN-DATA-004: active ingestは開始時のscene display snapshotを保持する。
- LAN-DATA-005: clientのlocal assignmentはstable Scene IDを参照する。
- LAN-DATA-006: unknown Scene IDを名前一致で自動統合しない。

## 6. Master authority

```text
CatalogAuthority
  projectID
  authorityID
  authorityEpoch UUID
  masterDeviceID
  publicKeyFingerprint
  revision UInt64
```

- `authorityEpoch`: master交代／災害復旧ごとに新規UUID。
- `revision`: 同一epoch内で単調増加。
- wall-clock時刻で新しいmasterを決めない。
- epoch UUIDの大小で勝者を決めない。
- 初版はprojectごとに1台の明示master、clientはcatalog read-only。

### 6.1 Snapshot

```text
SceneCatalogSnapshotPayload
  protocol version
  schema version
  projectID／catalogID
  authorityID／authorityEpoch
  revision
  generatedAt
  scenes[]
```

snapshot payload自身にdigest fieldを入れません。前節のcanonical `payloadBytes`を`SignedPayloadBytes`へ格納し、`payloadSHA256`と`DetachedSignature`を外側に置きます。内部表現を変更する場合はprotocol major、canonical encoder、test vectorを同時に更新します。

実行履歴でsnapshotを一意に指す共通値型:

```text
CatalogVersionRef
  projectID
  catalogID
  authorityID
  authorityEpoch
  revision
  payloadDigest
```

`CatalogVersionRef.payloadDigest`は対応するwire envelope外側の`payloadSHA256`と同じ32 bytesです。`IngestPlan`、各`sceneSnapshot`、`AssignmentResolution`、`CanonicalIngestEvent`、snapshot publish audit、handoff certificateはこの値をcopyしてfreezeし、必要なsceneには`sceneID + entityVersion`も保存します。revision単独では別epochの同番号を区別できないため使用しません。

clientは次の場合にfull snapshotを要求します。

- initial pairing
- revision gap
- cache破損
- outer `payloadSHA256`不一致
- schema migration
- authority epoch変更
- delta retention範囲外

snapshot適用はSQLite transactionでatomicに行い、半分だけ新しいcatalogをUIへ公開しません。

clientはcacheとは別のsecurity databaseへ、少なくとも次のhigh-water markを永続化し、Keychain内のdevice-scoped checkpointでDB recordをanchorします。

```text
projectID／catalogID
acceptedAuthorityID／authorityEpoch
highestRevision
acceptedPayloadDigest
trustedCatalogKeyID
acceptedHandoffChainDigest
```

`acceptedPayloadDigest`もouter `payloadSHA256`と同じ定義です。同一epochの低revision、同revision異digest、unknown keyを拒否します。epoch変更は旧authorityが署名したhandoff chain、または管理者の明示re-pairingなしに受理しません。app再起動、snapshot cache purge、backup restoreでもhigh-water markを消さず、security state resetは警告付きre-pairing操作に限定します。

### 6.2 Publish transaction

masterのscene編集はsingle-writer actorで直列化します。

```text
validate command
→ update scene rows
→ revision +1
→ audit event
→ snapshot／change record
→ one SQLite transaction commit
```

`commandID`を永続重複排除し、ACK消失後の同じcommand再送で変更を二重適用しません。

初版clientはread-onlyですが、将来proposalを追加する場合は`baseRevision`と`expectedEntityVersion`を必須にし、stale commandを競合として返します。last-write-winsは使用しません。

## 7. Pairing／TLS／trust

Bonjourで見つけただけの端末を信頼しません。

初版のnormative pairingは、master画面のQRまたは同じ内容の署名付き招待fileを利用者がclientへ明示importするout-of-band方式とします。

1. masterで短時間の`pairing open`を利用者が開始。
2. project ID、authority ID、catalog signing key fingerprint、LAN CA fingerprint、master TLS SPKI fingerprint、one-shot nonce、expiryを含む招待を生成。
3. clientはQR scanまたは利用者が明示選択した招待fileから招待を読む。短いcodeだけの入力方式を初版に使わない。
4. Bonjour endpointへ接続し、catalog／credentialを送受信する前に実際のTLS peer SPKIと招待fingerprintをconstant-timeで一致確認する。
5. nonceとTLS transcriptへbindしたhuman-verifiable SASを双方に表示し、利用者が一致を確認する。
6. master側でも接続中clientとproject scope／roleを明示承認する。nonceは短寿命、一回限り、試行回数／接続rateを制限する。
7. client device identity／certificateを登録する。
8. 以後の全trusted device接続はmTLSを必須とし、TLS 1.3優先／最低TLS 1.2、`projectID + catalogID + authorityID + authorityEpoch + Catalog signing key`、LAN CA fingerprint、master server leaf SPKI、project scope、role、revocationをそれぞれ検証する。
9. nonceを即失効する。

AppleはNetwork.frameworkでlocal network TLS identityをKeychainから設定する方法を案内しています。[Creating an Identity for Local Network TLS](https://developer.apple.com/documentation/network/creating-an-identity-for-local-network-tls)

禁止:

- 任意self-signed certificateを常に許可
- silent TOFU
- Bonjour名／IP／Mac名を本人性の根拠にする
- 全端末共通password
- certificate validation callbackで無条件success
- pairing codeをTXTへ広告
- 独自暗号algorithm

### 7.1 Key hierarchy／rotation

次の鍵を完全に分離し、相互流用しません。

| Key | 用途 | 保存／管理 |
|---|---|---|
| Developer ID Application private key | app／XPC／helperの配布code署名 | release用Keychain／CI。LAN protocolから参照不能 |
| Catalog authority signing key | snapshot／handoff／audit checkpointのEd25519署名 | master Keychain、project authority scope |
| LAN CA issuing key | project内TLS leaf certificateの発行／revocation。CA key usageだけ | master Keychain、project CA scope。TLS handshakeへ使用不能 |
| master TLS server leaf key | masterのTLS server authentication。`serverAuth`だけ | master Keychain、LAN CA署名、短期certificate／rotation管理。certificate発行不能 |
| client TLS leaf key | client authentication。`clientAuth`だけ | 各client Keychain、device／project scope、LAN CA署名。certificate発行不能 |

- 各recordへ`keyID`、用途、created／notBefore／expires／revoked、replacement keyを保存する。
- catalog key rotationは旧keyが新keyと有効開始revisionを署名し、client high-water markへcommitする。
- LAN CAはCA certificateの`keyCertSign／cRLSign`用途だけ、master leafは`serverAuth`だけ、client leafは`clientAuth`だけとし、証明書chainとKey Usage／Extended Key Usageの双方を検証する。CA private keyをserver handshakeへ、leaf private keyをcertificate発行へ使えない型／Keychain ACLにする。
- CA、server leaf、client leafのrotationはcatalog authorityとは独立し、重複有効期間とrevoke listを持つ。
- handoff／災害復旧時の鍵継承可否を鍵種別ごとに明示し、Developer ID keyをexportしない。
- private keyはKeychainから平文exportせず、backup policyはSection 11で鍵種別ごとに定義する。

trusted device record:

```text
deviceID
certificateFingerprint
displayName
role owner|editor|viewer
projectScope
pairedAt／lastSeenAt／revokedAt
```

private key、certificate identity、招待secretはKeychainへ保存します。Appleはpasswordやcryptographic key等の小さな秘密をKeychainへ保存するよう案内しています。[Keychain Services](https://developer.apple.com/documentation/security/keychain-services/) / [Storing Keys in the Keychain](https://developer.apple.com/documentation/security/storing-keys-in-the-keychain)

## 8. Local Network privacy

macOS 15以降はlocal network privacyを考慮します。AppleのTN3179ではBonjour登録、browse、resolveがlocal network access対象です。[TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)

Info.plist:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>同じ会場のMac間でシーン情報を共有するため、ローカルネットワーク上のRINKAN UMISを検索・接続します。</string>
<key>NSBonjourServices</key>
<array>
  <string>_umis-scene._tcp</string>
</array>
```

要件:

- 一般的なpermission query APIがあると仮定しない。`NWBrowser.stateUpdateHandler`の`waiting／failed` errorに含まれるpolicy deniedと、`NWConnection` path／stateのlocal-network denialを`permissionDenied`状態へ正規化する。
- LAN共有はprojectごとの明示設定で有効化する。
- 初回network operation前に用途をapp内で説明する。
- permission拒否を無限spinner／crashにしない。
- system settings案内と`LANなしで続行`を提供する。
- refusalでscan／copy／hash／erase gateを無効化しない。
- root helper等でprivacy permissionを迂回しない。
- Developer ID署名、固定Bundle ID、公証をLAN機能の前提にする。
- `NSLocalNetworkUsageDescription`と`NSBonjourServices`はentitlementではなくInfo.plist privacy declarationであり、非sandbox直接配布でも必要とする。
- 開発時も固定Team／Bundle IDの安定したdevelopment署名を使い、clean standard userでallow、deny、System Settingsからの再許可、同一署名update後を試験する。release時はDeveloper ID／公証済みartifactで同じmatrixを再実行する。

## 9. Offline behavior

- 最後に署名検証成功したsnapshotをread-only cacheとして利用可能。
- UIに`online／offline`、authority fingerprint、epoch、revision、取得時刻、stale ageを表示。
- snapshotがないclientはoffline時に共有sceneを推測生成しない。
- snapshot expiryは業務policyとし、期限超過時はwarningまたはoperator confirmation。
- active ingestはscene revisionと表示snapshotをplanへfreezeする。
- copy中にmasterで改名／削除してもpath／manifestを変更しない。
- 完了後にcatalog変更をreconciliation notificationとして表示。

初版clientはcatalogを編集しません。将来offline proposalを導入する場合、provisional IDで保存し、master acceptance前は正本へ昇格させません。

## 10. Split-brain／handoff／recovery

split-brain条件:

- 同一epoch／revisionでouter `payloadSHA256`が異なる。
- 信頼chainなしの別epochが同projectを名乗る。
- 同じauthorityを名乗る異なるpublic key。
- planned handoff完了後も旧masterがwrite可能状態を広告。

対応:

- catalog edit／sync applyを停止。
- 自動で一方を選ばない。
- fingerprint、epoch、revisionを利用者へ表示。
- 既にfreezeしたlocal ingestは継続可能。
- erase gateはnetworkから独立して評価。

planned handoff:

1. 旧masterがconsistent backup／signed audit checkpointを作る。
2. 新master上で、新しいCatalog authority signing key、新しいLAN CA issuing key、新しいmaster TLS server leaf key／certificate、新しいauthority ID／epochを生成し、用途分離を検証する。
3. 旧masterを`quiescing`へし、scene commandだけでなくpairing、role変更、revoke変更、旧CAによる新規certificate発行も停止する。その時点のtrusted device ID、project scope、role、client certificate serial／SPKI／fingerprint、revocation stateをfinal handoff stateへfreezeする。
4. final revisionをcommitし、旧masterの永続fence recordを先にdurable commitする。
5. final `CatalogVersionRef`、new Catalog public key、new LAN CA public certificate／fingerprint、new master server leaf SPKI、new authority／epoch、fence record、frozen trusted-device state digest、旧CA／server／client leafの移行期限を束ねたtrust-root rollover付きhandoff certificateを旧Catalog authority keyで署名する。
6. clientは旧Catalog pinからhandoff署名chainを検証し、new Catalog key、new CA、new server leaf SPKIを一つのatomic security-state updateとして受理する。chainを受理できないclientは自動TOFUせず明示re-pairingする。
7. 新masterがcertificateを検証しnew epochをactivation commitしてからadvertiseする。
8. client移行に必要な旧LAN CAのpublic certificate、final revocation state、frozen trusted-device recordだけを移す。旧LAN CA private key、旧Catalog private key、旧server／client leaf private keyは一切転送しない。
9. 移行猶予中、新masterは旧CAをlegacy `clientAuth`検証にだけ使用し、frozen listのserial、SPKI、fingerprint、device ID、project scope、role、未失効状態が全一致する既存clientだけを一時認証する。旧CAをserver trust、certificate発行、list外client、変更済みroleへ使用しない。
10. 各既存clientは新しいclient leaf private keyを自端末Keychain内で生成し、旧client keyで署名したCSR／proof-of-possessionを旧certificateで認証済みのtranscript、device ID、project scope、one-shot nonceへbindして新masterへ送る。new LAN CA署名の`clientAuth` certificateを受領し、private keyを端末外へ出さずKeychainへ保存する。
11. clientがnew leafによるmTLS再接続に成功し、新masterがdevice ID、project scope、role、new serial／SPKI／fingerprint、旧leaf失効を一transactionでdurable commitした後だけ、そのclientを`migrated`とする。以後そのclientの旧leafを拒否する。
12. 全必須clientの移行完了、または管理者が事前告知したcutoff到達後にlegacy旧CA trustを終了し、旧CA、旧server leaf、未移行の旧client leafを失効状態へ確定する。cutoffまでofflineだったclientは自動TOFUせず、new trust rootsを用いた明示re-pairingを要求する。
13. 旧masterは永久read-onlyとなり、再起動しても旧epochでwriteへ戻らない。

planned handoffは秘密鍵export方式にしません。abort可能なのは、handoff certificate／activation capabilityを新masterへ一度も発行・送信していない準備段階だけです。certificateを発行した後はnetwork partition下で「未activation」を証明できないため、旧masterは永久にfencedのままとし、新masterのrecoveryまたはさらに新しい明示handoffを必要とします。activation後は旧masterへ戻しません。各durable境界でcrash／network partitionを試験し、同時writerを0件にします。

unplanned recovery:

- 管理者がverified backupから復元。
- new authority key／epoch。
- 全clientへ災害復旧を明示。
- admin confirmationまたは再pairing。
- 自動leader election／最大revision端末の自動昇格なし。

## 11. Master audit／backup

audit event:

```text
eventID
auditSequence UInt64
projectID
authorityEpoch／revision
previousEventHash
occurredAtUTC
actorDeviceID／commandID
action／targetEntityID
beforeHash／afterHash
catalogVersionRef／outerPayloadDigest（snapshot publish／handoff時）
result／reason
```

記録:

- scene追加、改名、day変更、並べ替え、archive、restore
- pairing、revoke、role変更
- handoff／recovery
- backup／restore
- conflict
- invalid signature／auth failure／rate limit

`previousEventHash`だけでなく、単調`auditSequence`とcatalog authority keyによる定期signed checkpointを必須にし、checkpointを暗号化backup／別媒体へ外部化します。DB全体とhash chainを同時改竄しても、外部checkpointとの不一致を検出できるようにします。

SQLite WALを単純file copyせず、online backup APIまたはconsistent checkpointを使います。backup bundleは認証付き暗号化を行い、schema、epoch、revision、DB hash、audit tail hash／sequence、signed checkpointを含め、restore前に全署名とhashを検証します。

鍵ごとの初版backup policy:

- Developer ID private key: 含めない。
- Catalog authority private key: 初版backupへ含めず、planned handoffでもexportしない。旧masterが稼働中に旧keyでnew trust rootsを署名する。復旧時はnew key／epochと全clientの明示re-pairingを必須にする。
- LAN CA private key: 初版backupへ含めず、planned handoffでもexportしない。旧CAのpublic certificate／revocation stateだけを移行可能とし、災害復旧後は全client再pairingを必須にする。
- master TLS server leaf private key: 含めず、handoff／recovery先でnew CAから新規発行する。
- client device key: master backupへ含めない。

災害復旧用のprivate-key escrowを将来求める場合は、planned handoffとは完全に別のOwner／security policy、鍵ごとのhardware-backed wrapping、multi-party approval、rotation、失効、restore drillを設計し、独立security reviewを通すまで実装しません。

古いbackupをrestoreしてもclient high-water markがrollbackを拒否すること、CA keyなしのrecoveryで全client再pairingになることを受入試験へ含めます。

## 12. LAN受入試験

| ID | Scenario | 合格条件 |
|---|---|---|
| LAN-AT-001 | clean macOS 15でallow／deny | 説明後prompt、denyでもlocal ingest可 |
| LAN-AT-002 | fake same-name Bonjour service | trust前にcatalog／業務dataを開示しない |
| LAN-AT-003 | MITM／unknown CA／revoked cert | 接続拒否、auditあり |
| LAN-AT-004 | snapshot途中でmaster crash | oldかnewの完全snapshotだけ |
| LAN-AT-005 | same commandを100回retry | revision／audit変更1回 |
| LAN-AT-006 | 24時間offline | verified cache利用、stale表示 |
| LAN-AT-007 | copy中にscene改名／削除 | active path／manifest不変 |
| LAN-AT-008 | same revision、different hash | split-brain、auto selectionなし |
| LAN-AT-009 | planned handoff | new epoch、old master read-only |
| LAN-AT-010 | backupを別Macへrestore | explicit recovery、new epoch |
| LAN-AT-011 | invalid length／1MiB超／slow client | bounded memory、timeout、UI応答 |
| LAN-AT-012 | mDNS blocked／別VLAN | discovery error明示、local機能可 |
| LAN-AT-013 | two masters advertise | edit停止、operator resolution |
| LAN-AT-014 | revision rollback attempt | client拒否 |
| LAN-AT-015 | revoked viewer reconnect | auth拒否 |
| LAN-AT-016 | app再起動／snapshot cache purge | high-water mark維持、低revision拒否 |
| LAN-AT-017 | unknown epoch／old backup restore | handoff chain／re-pairingなしに受理しない |
| LAN-AT-018 | handoff各durable境界でcrash／partition | 同時writer 0、activation後に旧master復帰0 |
| LAN-AT-019 | catalog／TLS／device／Developer ID key混同 | 用途違いkeyを全拒否 |
| LAN-AT-020 | CA keyなしbackupからrecovery | new epoch、全client再pairing |
| LAN-AT-021 | CA private keyをserver handshakeへ使用 | key usage／型境界で拒否 |
| LAN-AT-022 | master／client leafでcertificate発行 | `keyCertSign`なし、発行不能／chain拒否 |
| LAN-AT-023 | protocol v1固定test vector | exact canonical bytes、outer digest、Ed25519 signatureがSwift／独立verifierで一致 |
| LAN-AT-024 | trust-root rollover付きhandoff | new Catalog key／CA／server SPKIをatomic採用。既存clientがlocal生成new keyのnew clientAuth leafへ再発行され、新leafでmTLS成功、移行済み旧leaf拒否。cutoff後は旧CA／全旧leaf拒否、offline未移行clientは明示re-pairing |
| LAN-AT-025 | handoff chainを検証できないclient | 自動pin更新なし、明示re-pairing |

# Part B：SD管理システム連携

## 13. Domain boundary

```swift
protocol SDManagementGateway {
    func capabilities() async throws -> GatewayCapabilities
    func resolveAssignment(
        _ query: CardResolutionQuery
    ) async throws -> AssignmentResolution
    func publish(
        _ events: [CanonicalIngestEvent]
    ) async throws -> PublishReceipt
}
```

実装variant:

- `DisabledSDManagementGateway`
- `MockSDManagementGateway`
- `HTTPBasedSDManagementGateway`
- `RinkanSDHTTPGateway`（integration API実装後）

`IngestEngine`はgatewayを直接呼びません。`CardAssignmentResolver`と`SDManagementSyncActor`が境界になります。VPS停止、API変更、認証期限切れでもlocal copy journalを継続できます。

現行SD側にintegration APIが実装される前のrelease buildで到達可能なのは`DisabledSDManagementGateway`だけです。`Mock`、fake server、staging endpointはDEBUG／test targetへcompile-timeで隔離し、production artifactから選択／設定／reflectionで到達不能にします。`RinkanSDHTTPGateway`はSD側のversioned endpoint、contract／security test、device認証、環境固定、Product Owner承認済みfeature gateの後にだけ有効化し、現行browser URLや推測したJSONで送信しません。

## 14. Card Noとphysical mediaの分離

```text
CardNo
  business identifier
  String（先頭zero保持）
  tenant／event／project scope

MediaHardwareFingerprint
  available hardware／IORegistry attributesのversioned digest
  attributeProvenance（card／reader／unknown）
  identityStrength strongForCurrentInsertion|weak|unknown

VolumeInstanceID
  filesystem UUID等。formatで変更可能

MountSessionID
  insertionからremovalまでの一回のsession UUID
```

- CARD-001: `"01"`をinteger `1`へ変換しない。
- CARD-002: 同じCard Noと別projectの同番号を分ける。
- CARD-003: Volume UUID／BSD名を永続Card Noとみなさない。
- CARD-004: 同じCard Noでもphysical fingerprintが変わればoperator confirmation。
- CARD-005: format前後のVolumeInstanceIDをbinding historyへ記録。
- CARD-006: volume labelからCard Noを無条件推定しない。
- CARD-007: hardware serial原文をVPSへ送らない。
- CARD-008: reader serial／IORegistry属性だけで異なるSDを同じmediaと判定しない。
- CARD-009: remove eventでfingerprint一致に関係なくMountSessionID、current binding confidence、全EraseAuthorizationTokenを即失効する。
- CARD-010: weak／unknown identityの再挿入では過去token／verified runを復活させず、新binding確認と新verified ingestを要求する。

04の`Project.cardNoDefinitions[]`は業務上のCard No候補／規則、`SourceVolumeID`は一挿入sessionのlocal sourceを表します。`CardNo`、`MediaHardwareFingerprint`、`VolumeInstanceID`、`MountSessionID`を相互代用しません。

`CardBinding`:

```text
bindingID
cardNo
mediaFingerprintDigest
mediaIdentityStrength／attributeProvenance
volumeInstanceID
mountSessionID
confirmationMethod／confirmedBy
confidence
validFrom／validUntil
serverRevision
previousBindingID
```

Card No検出providerの候補は、実運用方法と匿名化sampleの確認後に順位を決めます。現行SD側が持つのは会場内一意の業務`Card.label`であり、volume／physical mediaとのbinding dataはありません。

- card上のsigned manifest／marker file
- card reader／media metadataとserver mapping
- volume label pattern
- operator入力
- QR／barcode等の外部入力

検出が複数候補、期限切れ、binding変更の場合は自動開始しません。

## 15. Photographer／scene resolution

名前文字列ではなくstable remote IDをmapします。

```text
RemotePhotographerID → LocalPhotographerID
RemoteSceneID → LocalSceneID
```

resolution:

```text
resolutionID
cardNo／bindingID
photographerID
sceneIDs
catalogVersionRef
source remote|cache|manual
serverRevision
fetchedAt／validUntil
isStale
confidence
operatorOverrideReason
```

- exact stable ID mappingだけauto-prefill。
- source／revision／ageをUIへ表示。
- unknown、multiple、conflictではoperator confirmation。
- manual overrideに理由とactorを記録。
- active ingest開始後のremote変更はplanへ反映しない。
- unknown remote Scene IDをnameだけでlocal sceneへbindしない。
- LAN masterをScene Catalog authority、VPSをCard No→assignment authorityとする初期案。

## 16. Canonical ingest status

SD側integration APIへmappingするcanonical domain event:

```text
eventID
eventSchemaVersion
jobID／jobSequence
projectID
cardNo／cardBindingID
photographerID／sceneIDs／catalogVersionRef
eventType
fileCount／totalBytes
verificationAlgorithm／verificationResult
occurredAtUTC
privacyProfile
```

event候補:

- `cardDetected`
- `assignmentResolved`
- `ingestPlanned`
- `ingestStarted`
- `ingestVerified`
- `ingestFailed`
- `ingestCancelled`
- `eraseStarted`
- `eraseSucceeded`
- `eraseFailed`
- `cardReadyForReuse`

初版はerase eligibility／authorizationをVPSへ送信しません。将来必要でも`localEraseEligibilityObserved`等の「local判定結果の通知」とし、remoteで再利用可能な認可ではないことをschemaへ固定します。実際の`EraseAuthorizationToken`、token digest、nonce、authenticatorをOutbox／networkへserializeしません。

現行SD側の`ingested`は単なるcopy verifiedではなく、カードを直ちに再利用可能へ戻す状態です。したがって`ingestVerified`を直接`ingested`へmapしません。SD側へ`IngestAttempt`相当を追加し、post-format write/read probe成功または理由付きoperator release後の`cardReadyForReuse`だけを既存`ingested`へ対応させます。

defaultで送信しない:

- absolute／relative file path
- filename一覧
- media content
- file別hash一覧
- hardware serial原文
- login name
- local IP／MAC address

## 17. Durable outbox

`OperationStoreActor`がlocal job state、canonical outbox event、local audit eventを同じSQLite database／transactionでcommitします。DBを分けず、`SDManagementSyncActor`はcommit済みrowをclaim／送信するだけです。

```text
domain state transition
  + outbox event
  + local audit event
= one transaction
```

送信順:

1. local state確定。
2. outboxへ保存。
3. transaction commit。
4. background workerがVPSへ送信。
5. ACK／receiptを別transactionで保存。

VPS errorでlocal verified stateをrollbackしません。

outbox state:

```text
pending
inFlight
acknowledged
retryScheduled
pausedForAuth
deadLetter
```

要件:

- deliveryはat-least-once。
- `eventID`は生成時から永久に不変。retry、manual retry、dead-letter再送、backup restoreでも同じIDを使う。
- local unique constraintを`eventID`へ設定し、canonical payload digestも保存する。同じeventID＋異payloadを生成／送信しない。
- serverもeventIDを重複排除。
- job内`jobSequence`単調増加。
- `inFlight` rowは`attemptID`、`claimedAt`、`leaseUntil`を持ち、process kill／lease expiry後は同じeventIDで`pending`へ回収する。
- `PublishReceipt`はeventIDごとに`accepted／duplicate／retryable／permanent`とserver receipt／correlation IDを返す。batchのpartial successで未ACK eventまで一括ACKしない。
- exponential backoff＋full jitter。
- `Retry-After`尊重。
- timeout、network、retryable 5xx／429を再試行。
- 401はcredential refreshを一回試み、失敗時`pausedForAuth`。
- permanent validation errorはdead letterへ置き、黙って削除しない。
- UIにpending、last success、auth paused、dead letterを表示。
- manual retry／redacted diagnostic exportを提供。
- exactly-once deliveryとは表現しない。
- production有効化前に、serverのeventID dedupe retentionがlocal Outbox retention＋backup replay期間以上であることを契約化する。

## 18. Authentication／privacy

実API次第でOAuth 2.0／OIDC、device flow、mTLS、short-lived token、組織SDK等を`CredentialProvider`の背後へ置きます。固定API keyをappへ埋め込みません。

- token、private key、client certificateはKeychain。
- UserDefaults、project JSON、log、URL queryへsecretを入れない。
- HTTPS／ATSを維持し、平文HTTP fallbackなし。
- `NSAllowsArbitraryLoads`なし。
- minimum scope、device revoke、credential rotation。
- auth failureでlocal ingestを停止しない。
- Authorization header／cookie／token responseをlogしない。
- certificate pinningは運用可能なrotation planがない限り安易に追加しない。

## 19. Local safety precedence

- VPS `completed`＋local hash failure → erase不可。
- LAN online＋copy未検証 → erase不可。
- same Card No＋different physical identity → erase不可。
- network offline＋local verified → local policyに従ってerase判定可能。
- outbox pendingは初期化安全proofではない。別statusとして表示。
- remote erase commandは初版で実装しない。
- remote responseは`EraseAuthorizationToken`を生成できない。
- organizational policyとしてremote ACKを必須にする場合、local safety条件へ追加の制限を掛けるだけとし、local条件を弱化しない。

## 20. SD管理受入試験

| ID | Scenario | 合格条件 |
|---|---|---|
| SDM-AT-001 | VPS完全停止で10 run | local完了、outbox消失なし |
| SDM-AT-002 | reconnectしてdrain | 全event ACK、業務効果重複なし |
| SDM-AT-003 | server処理後ACK lost | same eventIDでduplicate-safe |
| SDM-AT-004 | 401／refresh失敗 | pausedForAuth、event保持、local完了維持 |
| SDM-AT-005 | 429／Retry-After | 指定時間尊重、tight loopなし |
| SDM-AT-006 | 5xx／network flap | jitter retry、UI stallなし |
| SDM-AT-007 | permanent validation error | dead letter visible |
| SDM-AT-008 | same volume nameのcard 2枚 | distinct media identity |
| SDM-AT-009 | same Card Noを別mediaへbind | confirmationなしにerase不可 |
| SDM-AT-010 | formatでVolume UUID変更 | before／after binding history |
| SDM-AT-011 | 同姓同名photographer | stable IDなしでauto resolveしない |
| SDM-AT-012 | 同名scene複数 | Scene IDで区別 |
| SDM-AT-013 | stale assignment cache | age表示、policyどおり確認 |
| SDM-AT-014 | VPS complete、local hash fail | erase tokenなし |
| SDM-AT-015 | VPSがremote erase命令 | service call不能 |
| SDM-AT-016 | packet／log inspection | secret、path、hardware serial原文なし |
| SDM-AT-017 | DB commit各境界でkill | job／outbox／audit不整合なし |
| SDM-AT-018 | inFlight claim後にprocess kill | lease expiry後、同じeventIDでpendingへ回収 |
| SDM-AT-019 | batchの一部だけaccepted | accepted itemだけACK、残り保持 |
| SDM-AT-020 | same eventID＋different payload | local unique constraintで生成／送信拒否 |
| SDM-AT-021 | dead-letter manual retry／backup restore | eventID永久不変、server効果重複なし |
| SDM-AT-022 | release buildでMock／staging探索 | code path／endpoint設定が到達不能 |

## 21. 現行コード解析後も、server実装前に確定するAPI契約

1. REST／GraphQL／WebSocket／SDK等の接続方式。
2. development／staging／production base URL。
3. protocol／API versioning。
4. authentication、token lifetime、rotation。
5. tenant／organization／event／project階層。
6. Card Noのformat、scope、再利用、重複、check digit。
7. Card No検出source。
8. hardware identityをserverが必要とするか。
9. photographer／sceneのstable ID。
10. LAN Scene Catalogとのauthority分担。
11. assignment cacheの有効期限。
12. ingest status state machine。
13. job単位／file単位のstatus粒度。
14. file count、bytes、hash等の送信必要性。
15. idempotency key scope／retention。
16. same eventID＋different payloadの扱い。
17. event ordering／late arrival。
18. rate limit／batch上限／Retry-After。
19. retryable／permanent error taxonomy。
20. receipt／correlation ID。
21. proxy／VPN／certificate rotation。
22. data retention／delete／privacy／audit。
23. server outage運用。
24. local manual overrideのserver表現。
25. disaster recovery時のreplay範囲。

現行実装から、接続方式はHTTPS JSON APIを新設すること、Card Noは`Card.label`、撮影者は`UsageRecord.cameramanId`、複数sceneは`RecordScene`が正本であることまでは確定しました。一方、この一覧の外部契約は現行systemに存在しません。推測してproduction通信を作らず、SD側のOpenAPI、versioned migration、service auth、idempotency、contract fixtureが完成してからadapterを固定します。

## 22. 実装順

1. Scene ID／Catalog／Authority／Revision model。
2. signed snapshot storeとoffline read-only cache。
3. `SceneTransport` mockとprotocol parser。
4. Network.framework＋Bonjour discovery。
5. local TLS identity、pairing、Keychain trust。
6. master single-writer publish／audit／backup。
7. split-brain／handoff／recovery。
8. Card No／Media Identity／Mount Session分離。
9. `SDManagementGateway` Disabled／Mock。
10. durable outboxとfake server contract test。
11. 受領済みSD管理systemのdomain mappingを固定。
12. SD側versioned migration、stable ID、`IngestAttempt`、integration API／service auth／idempotencyを実装。
13. `RinkanSDHTTPGateway`、OpenAPI consumer contract、staging E2Eを実装。
14. staged feature flagで1会場pilot運用。
