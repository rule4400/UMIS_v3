# Developer ID signing and notarized release

更新日: 2026-08-28

このprojectはMac App Store外配布を前提とし、`Developer ID Application` + Hardened Runtime + Apple公証 + stapled ticketをrelease条件とします。Apple Developer Program登録だけでは署名できません。署名を行うMacのKeychainに、certificateと対応するprivate keyが必要です。

## 現在の署名／公証構成

2026-08-28のこのMacでの確認結果:

- `security find-identity -v -p codesigning`: valid `Developer ID Application` identity 1件
- Developer Team: `CHECK HOUSE, K.K. (FA43T8UK3P)`
- certificateに対応するprivate key: login Keychainに導入済み
- `notarytool` Keychain profile `UMIS_NOTARY`: 登録・認証済み
- `0.2.0-alpha.3`: Apple Notary Service `Accepted`、ticket staple、Gatekeeper検証済み

private key、Apple IDのapp-specific password、notary credentialはKeychainのみに保存し、repository、`.env`、build manifest、DMGには含めません。各releaseが実際に配布可能かどうかは、対応するrelease manifest、notary submission ID／log、stapler／Gatekeeper結果を正本とします。

## 1. Developer ID Application certificate

Apple DeveloperのCertificates, Identifiers & Profilesで`Developer ID Application`を作成します。Macアプリ用であり、`Developer ID Installer`、`Apple Development`、`Mac App Distribution`ではありません。

1. このMacのKeychain AccessでCertificate Signing Requestを作成する。
2. Apple Developerで`Developer ID Application`を選び、CSRをuploadする。
3. 発行された`.cer`をこのMacのlogin Keychainへinstallする。
4. Keychain Accessの「マイ証明書」でcertificateの下にprivate keyが表示されることを確認する。
5. Terminalで検証する。

```sh
security find-identity -v -p codesigning
```

`Developer ID Application: ... (TEAMID)`が1件以上表示されることが必要です。certificateだけを他のMacからコピーしても、private keyがなければ署名できません。

Apple公式: <https://developer.apple.com/help/account/certificates/create-developer-id-certificates>

## 2. Notary credentialsをKeychainへ保存

app-specific passwordをcommand line、script、GitHub、`.env`へ書きません。次のcommandはpasswordを対話入力し、Keychainの`UMIS_NOTARY`というprofileへ保存します。

```sh
xcrun notarytool store-credentials UMIS_NOTARY \
  --apple-id "<Apple ID>" \
  --team-id "<10文字のTeam ID>"
```

入力後にauthenticationを確認します。

```sh
xcrun notarytool history --keychain-profile UMIS_NOTARY
```

Apple公式: <https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution>

## 3. Release sourceを確定

release scriptは次の条件をfail-closedで要求します。

- working treeがclean
- `VERSION` がSemVer
- HEADに対応するannotated tag `v<VERSION>`
- Universal 2 (`arm64` + `x86_64`)
- 各sliceが同一のDeveloper IDで署名済み
- Hardened Runtime + secure timestamp
- `get-task-allow` false
- Apple公証`Accepted`、警告0、ticket staple済み
- Gatekeeper assessment成功
- appとdSYMのUUID一致
- `jp.rinkan.umis`、macOS 13.0 deployment target、全sliceのTeam ID／Developer ID一致
- JIT／unsigned executable memory／library validation無効化等の危険なentitlementなし
- staple後のDMGをread-onlyで再マウントし、内包appの署名、Universal 2、bundle metadata、entitlements、icon、dSYM UUIDを直接再検証
- release manifestにsource tree、DB schema、toolchain、DMG内app／dSYM／DMG／notary logのSHA-256を記録
- 最終DMG、checksum、manifestの公開途中で失敗した場合は直前のartifactを復元

alpha／rcを含む候補版は、testとreview完了後に`VERSION`と同じannotated tagを付けます。既にpushしたtagの打ち替えやforce-pushは行いません。

```sh
RELEASE_VERSION=$(<VERSION)
git tag -a "v${RELEASE_VERSION}" -m "RINKAN UMIS ${RELEASE_VERSION}"
git push origin HEAD
git push origin "v${RELEASE_VERSION}"
```

feature branchはGitHubのpushし、CI成功後にpull requestで`main`へreviewします。配布用stable tagは、原則としてreview済みの`main`上commitに付けます。

## 4. Distribution build

```sh
UMIS_NOTARY_PROFILE=UMIS_NOTARY Scripts/build_release.sh
```

複数のDeveloper ID identityが存在する場合だけ、証明書のSHA-1 fingerprintを明示します。

```sh
UMIS_CODESIGN_IDENTITY="<certificate SHA-1 fingerprint>" \
UMIS_NOTARY_PROFILE=UMIS_NOTARY \
Scripts/build_release.sh
```

成果物は`dist/`に作成されます。`dist/`、DMG、dSYM、notary credentialはGitへcommitしません。manifest、manifest SHA-256、notary submission ID/logをaccess-controlledなrelease証跡庫へ保管します。`.p12`、`.p8`、private key、app-specific passwordはGitHub Release artifactにも添付しません。

完成後のartifactは、署名や公証recordを変更しない独立検証でも再確認します。

```sh
UMIS_VERIFY_PROFILE=UMIS_NOTARY Scripts/verify_release.sh
```

## 5. Local-only ad-hoc build

Developer IDを使用しないローカル起動検証だけに使います。identityを明示せず`UMIS_ALLOW_ADHOC=1`を指定すると、Developer IDがKeychainに導入済みでも常にad-hoc署名を使用します。

```sh
UMIS_ALLOW_ADHOC=1 UMIS_UNIVERSAL2=1 Scripts/build_app.sh
```

ad-hoc署名にはTeam IDもApple公証ticketもなく、別のMacへの正規配布に使用できません。

## 6. 公開repositoryとGitHub保護

`rule4400/UMIS_v3`は2026-08-26現在public repositoryです。個人のローカル絶対パス、受領source archive、実VPSのIP／domain／credential、production DB／添付、Apple署名鍵をpushしません。GitHubのsecret scanningとpush protectionに加え、repository hookがprivate-key header、代表的なtoken、署名file、DB／DMGをcommit前に拒否します。
