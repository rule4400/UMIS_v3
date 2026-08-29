# RINKAN UMIS contributor instructions

## Required commands

Before handing off a change:

```sh
Vendor/AdobeXMP/Scripts/verify_xcframework.sh
swift test --parallel
swift build --configuration release
UMIS_ALLOW_ADHOC=1 Scripts/build_app.sh
```

## Non-negotiable safety rules

- Never use array index, display name, mount label, or path alone as a persistent identity.
- Never treat destination existence or byte-size equality as verified delivery.
- Never overwrite a destination file silently.
- Copy through an exclusive partial file, synchronize it, re-read SHA-256, and atomically commit without replacement.
- Required Set must be non-empty and every required delivery must have a fresh durable receipt before erase eligibility.
- Remote LAN／VPS state may only add restrictions; it cannot weaken local verification or create an erase token.
- An erase token is one-shot, short-lived, bound to the current physical insertion and verified manifest, and must be consumed before destructive execution.
- Tests must inject fake erase／eject process runners. Never run `diskutil erase*` against a real device in automated tests.
- Do not call the current SD system browser routes from production Swift code. Until the versioned integration API exists, production uses only `DisabledSDManagementGateway`.
- Do not commit secrets, production DBs, personal data, signing private keys, notarization credentials, DMGs, or generated caches.
- Database changes require ordered migration, backup, integrity check, rehearsal, and a documented forward-fix／rollback policy.
- Keep UI work on `@MainActor`; filesystem, hashing, media decode, process wait, database, and network work belong outside the main actor.

## Versioning

- Work on `feature/*` branches.
- Do not rewrite shared history or force-push `main`.
- Use annotated release tags and retain build manifests.
- Verify an old version in a separate Git worktree; do not reset the active worktree destructively.
