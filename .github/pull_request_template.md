## Summary

<!-- 利用者への影響と変更理由 -->

## Safety checklist

- [ ] `swift test --parallel`が成功した
- [ ] release configurationでbuildした
- [ ] source／destination／物理media identityの安全条件を弱めていない
- [ ] copy／rename／erase／migrationの失敗・cancel・再起動をtestした
- [ ] DB schema変更にはmigration、backup、rehearsal、rollback／forward-fix計画がある
- [ ] secret、production DB、個人情報、署名秘密鍵を追加していない
- [ ] UI変更をkeyboard／VoiceOver／大量素材で確認した
- [ ] 要件文書とCHANGELOGを更新した

## Verification evidence

<!-- test名、build manifest、screenshot、fault injection結果 -->

## Rollback

<!-- 戻すtag／commit。data migrationがある場合はcode rollbackだけで戻せるかを明記 -->
