# Versioning and rollback

## Principles

1. `main`は常にtest／release buildが通る状態に保つ。
2. 変更は`feature/<topic>` branchで行い、CI成功後にmergeする。
3. 配布候補はannotated tag `vMAJOR.MINOR.PATCH-rc.N`、配布版は`vMAJOR.MINOR.PATCH`を付ける。
4. tagへsource commit、DB schema version、build manifest、署名／公証結果を対応させる。
5. code rollbackとuser data rollbackを混同しない。原則は旧codeが新schemaを読める互換期間、またはforward-fixを使う。
6. destructive migrationの前にはSQLite online backup、integrity check、restore rehearsalを必須にする。

repository clone後は`Scripts/install_git_hooks.sh`を一度実行します。hookはsecret／DB／配布物／20 MiB超の未審査fileのcommitを拒否し、push前に全testを実行します。緊急時にも`--no-verify`を常用せず、例外理由をpull requestへ記録します。

alpha milestoneには`vMAJOR.MINOR.PATCH-alpha.N`を使えます。一度remoteへpushしたtagは打ち替えず、修正は新しいversionとtagにします。

2026-08-26時点のGitHub `main`にはbranch protection／repository rulesetがありません。複数人運用やproduction releaseの前に、pull request必須、CI `test-and-build`必須、force-push／branch deletion禁止をGitHub側で設定します。ローカルhookだけを保護境界にしません。

## Safe checkpoint

作業中のcheckpointは、working treeがcleanでtestに成功したときだけ作成します。

```sh
Scripts/create_checkpoint.sh feature-name
```

このscriptはcommitを作りません。現在commitへannotated tagを付け、source treeとtoolchainのmanifestを`Artifacts/checkpoints`へ生成します。未commit変更がある場合は失敗します。

`Artifacts/`はGit対象外です。checkpoint manifestはtagと一緒にaccess-controlledな証跡庫へcopyし、ローカルdisk故障時にも失わないようにします。tag自体も必要なremoteへ明示pushします。

## Code rollback

既存working treeを破壊しないため、新しいworktreeで過去版を検証します。

```sh
Scripts/checkout_version.sh v0.1.0-bootstrap /absolute/path/to/verification-worktree
```

これにより現在の作業directoryをresetせず、指定tagを別directoryへ展開できます。そこで`swift test`とbuildを実行してから切替判断を行います。

過去binaryの起動確認ではproduction用Application Supportを直接開きません。データを複製した隔離fixtureでschema互換性を確認し、旧codeが新schemaを読めない場合は、codeだけを戻さずforward-fixまたは検証済みbackupの別場所restoreを行います。production DBの同じfileに対するin-place downgradeは行いません。

## Release artifact

releaseごとに次を保存します。

- source tag／commit／tree ID
- `Package.resolved` hash（存在する場合）
- Swift／Xcode／SDK version
- app SHA-256
- `codesign -dvvv` metadata
- notarization submission ID／result
- DB schema version／migration checksums
- test report

秘密鍵、Apple ID password、notary password、production DBはGitへ保存しません。
