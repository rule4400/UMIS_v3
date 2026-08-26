# Versioning and rollback

## Principles

1. `main`は常にtest／release buildが通る状態に保つ。
2. 変更は`feature/<topic>` branchで行い、CI成功後にmergeする。
3. 配布候補はannotated tag `vMAJOR.MINOR.PATCH-rc.N`、配布版は`vMAJOR.MINOR.PATCH`を付ける。
4. tagへsource commit、DB schema version、build manifest、署名／公証結果を対応させる。
5. code rollbackとuser data rollbackを混同しない。原則は旧codeが新schemaを読める互換期間、またはforward-fixを使う。
6. destructive migrationの前にはSQLite online backup、integrity check、restore rehearsalを必須にする。

## Safe checkpoint

作業中のcheckpointは、working treeがcleanでtestに成功したときだけ作成します。

```sh
Scripts/create_checkpoint.sh feature-name
```

このscriptはcommitを作りません。現在commitへannotated tagを付け、source treeとtoolchainのmanifestを`Artifacts/checkpoints`へ生成します。未commit変更がある場合は失敗します。

## Code rollback

既存working treeを破壊しないため、新しいworktreeで過去版を検証します。

```sh
Scripts/checkout_version.sh v0.1.0 /absolute/path/to/verification-worktree
```

これにより現在の作業directoryをresetせず、指定tagを別directoryへ展開できます。そこで`swift test`とbuildを実行してから切替判断を行います。

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
