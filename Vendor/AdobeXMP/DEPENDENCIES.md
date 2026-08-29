# Dependency and artifact manifest

## Runtime contents

| Component | Pinned version | Immutable identity | Official source | Role |
| --- | --- | --- | --- | --- |
| Adobe XMP Toolkit SDK | `v2025.03` | Git commit `581c41213ddcee1fbc72cbb532531102a6617a25` | [Adobe repository at the pinned commit](https://github.com/adobe/XMP-Toolkit-SDK/tree/581c41213ddcee1fbc72cbb532531102a6617a25) | Static `XMPCore` and `XMPFiles`; shipped inside the static framework binary `AdobeXMPBridge.framework/AdobeXMPBridge` |
| Expat | `2.5.0` | SHA-256 `6b902ab103843592be5e99504f846ec109c1abb692e85347587f237a4ffa1033` | [expat-2.5.0.tar.gz](https://github.com/libexpat/libexpat/releases/download/R_2_5_0/expat-2.5.0.tar.gz) | XML parser source supplied to the XMP build; linked into the static artifact |
| zlib | `1.2.13` | SHA-256 `b3a24de97a8fdbc835b9833169501030b8977031bcb54b3b3ac13740f846ab30` | [zlib-1.2.13.tar.gz](https://github.com/madler/zlib/releases/download/v1.2.13/zlib-1.2.13.tar.gz) | Compression source supplied to the XMP build; linked into the static artifact |

Adobe is pinned by the full Git commit rather than a mutable branch or only a tag name. At the time of integration, that commit is the target of tag `v2025.03` and has commit subject `Security fixes (#102)`.

## Build-only tool

| Component | Pinned version | Immutable identity | Official source | Role |
| --- | --- | --- | --- | --- |
| CMake macOS Universal | `3.23.2` | SHA-256 `853a0f9af148c5ef47282ffffee06c4c9f257be2635936755f39ca13c3286c88` | [cmake-3.23.2-macos-universal.tar.gz](https://github.com/Kitware/CMake/releases/download/v3.23.2/cmake-3.23.2-macos-universal.tar.gz) | Generates the Xcode project; not linked into or shipped inside the UMIS XCFramework |

`Scripts/build_xcframework.sh` downloads the three archives using HTTPS and rejects them before extraction unless their SHA-256 exactly matches this table. The Adobe checkout is rejected unless `git rev-parse HEAD` exactly matches the full commit.

## Local patches

Patches are applied after the pinned sources and dependencies have been staged:

1. `Patches/0001-use-active-macos-sdk-and-target-13.patch`
   - replaces the obsolete hard-coded macOS SDK `13.1` with the SDK selected by `xcrun --sdk macosx --show-sdk-version`;
   - fails CMake generation if the active SDK cannot be resolved;
   - changes the deployment target from macOS 10.15 to macOS 13.0;
   - retains Adobe's Universal Apple project setting.
2. `Patches/0002-zlib-modern-apple-target.patch`
   - removes zlib's obsolete `TARGET_OS_MAC` path from its classic Mac OS `OS_CODE` conditional;
   - is required because modern Apple SDK headers define `TARGET_OS_MAC` for current macOS, which must not select that legacy branch.

No functional Adobe XMP handler code is patched. DOM is disabled at configuration and compile time; see `BUILDING.md`.

## Artifact identity

`Artifacts.sha256` hashes every file that is part of the checked-in XCFramework: the outer Info.plist, static framework binary, public header, inner framework Info.plist, and module map. `SourceInputs.sha256` independently fixes the reviewed UMIS bridge source, public ABI header, module map, framework template, local patches, reproducible build script, and release verifier. Verification runs from this directory so manifest paths are stable. Both manifests are regenerated only after review; a rebuild must never reuse the previous artifact hashes.

The current accepted static framework binary SHA-256 is `fac07b0e14a8f4a714591e68314239e196151941ad72210a065cd1c6d3a499eb`; the same value is recorded from the actual file in `Artifacts.sha256`. The packaged payload is approximately 8.2 MB (about 7.8 MiB on disk) and contains both architectures in one static framework slice.

The public ABI is version 3. Its status type is deliberately `typedef uint32_t UMISXMPStatus`. The bridge must use Adobe's `-fshort-enums` ABI flags, so a public enum return type is not permitted; status constants are kept separately as anonymous enum constants. Version 2 introduced the parent-directory-FD plus leaf `_at` functions backed by the official static-build `OpenFile(XMP_IO *)` API. Version 3 adds a mandatory two-phase recovery token/result and `umis_xmp_finalize_recovery_at`: descriptor-capability writes retain the old inode until an independent Swift/Core readback authorizes cleanup. The exported path functions are probe/read compatibility adapters only; no path-authorized mutation export is accepted into the artifact.

ABI v3's filesystem contract is part of artifact acceptance. It uses a random private mode-`0700`
recovery directory, exclusive mode-`0600` pending/sealed/cleanup manifests, and replacement partials
that begin mode `0600`. The old original remains the same swapped inode with its source mode, ACLs,
and xattrs. Finalization removes noncritical artifacts first and the original last, then durably
records `manifest.cleanup.json` state `committedOriginalRemoved`; sealed and pending manifests are
removed before this cleanup-state manifest, which remains authoritative while any later cleanup
residue exists. A retained original is a structured error; residue after the original is proven unlinked is
a committed result that requires a warning, inspector attention, batch invalidation, and a fresh
root scan.

`Scripts/verify_xcframework.sh` now rejects a source/artifact ABI split. It requires byte-for-byte equality between the reviewed and packaged header/module map/framework template, ABI version 3, the exact seven-function `umis_xmp_*` export set, the pinned Adobe/Expat/zlib/CMake identities and DOM-disabled/macOS-13 build policy, both source-input and artifact manifests, and both Universal 2 architectures. The former path-authorized mutation export is intentionally absent; only the descriptor-capability `_at` write can mutate embedded XMP.

The recorded build environment for this artifact is:

- macOS 26.5.1 (build 25F80)
- Xcode 26.6 (build 17F113)
- Apple clang 21.0.0 (`clang-2100.1.1.101`)
- deployment target: macOS 13.0
- architectures: `arm64`, `x86_64`

The minimum deployment target is fixed by both the patched Adobe toolchain and the bridge compiler invocation. A newer SDK was used to compile; that does not raise the declared macOS 13 runtime minimum.

The checked-in binary cannot enforce the complete application threat model by itself. Release
acceptance also requires Core/App integration that performs one O(N) recovery scan while holding a
short-lived frozen-root advisory `flock`, O(1) authorized-parent checks per asset, bounded
case-variant descriptor-relative `fstatat` collision probes for same-stem RAW, exact-FD FinderInfo
mutation/readback, and cooperative `NSFileCoordinator` intents around the whole write/readback
operation. These policies are documented in `SAFETY.md` and are intentionally not represented as
additional C ABI exports.

## License inventory

The following files are exact copies in content of the named files in their primary distributions. Their SHA-256 values are included here so future upgrades can distinguish upstream text changes from local edits.

| Local file | Primary-distribution file | SHA-256 |
| --- | --- | --- |
| `Licenses/Adobe-XMP-Toolkit-SDK-LICENSE` | XMP Toolkit SDK root `LICENSE` | `99678ec755c91c9400a989fef7c6e1bd2907aff40eef4cf855c111bbd282c1d4` |
| `Licenses/Expat-COPYING` | Expat 2.5.0 `COPYING` | `122f2c27000472a201d337b9b31f7eb2b52d091b02857061a8880371612d9534` |
| `Licenses/zlib-LICENSE` | zlib 1.2.13 `LICENSE` | `845efc77857d485d91fb3e0b884aaa929368c717ae8186b66fe1ed2495753243` |
| `Licenses/CMake-Copyright.txt` | CMake app `Contents/doc/cmake/Copyright.txt` | `6a02a053cfb1e1964e623dc0eeabc7206d33058259ddfdbd754467339efc5608` |

Adobe's pinned SDK also publishes `docs/xmp_public_patent_license.pdf`. It can be reviewed at the [immutable commit path](https://github.com/adobe/XMP-Toolkit-SDK/blob/581c41213ddcee1fbc72cbb532531102a6617a25/docs/xmp_public_patent_license.pdf). It is a separate patent-license document, not a replacement for the BSD 3-Clause software license reproduced here.

The Adobe source also compiles its bundled RSA Data Security, Inc. MD5 implementation into XMPCore/XMPFiles. Its source-level notice requires identification and retention. `Licenses/RSA-MD5-NOTICE` reproduces that notice from the pinned [`third-party/zuid/interfaces/MD5.h`](https://github.com/adobe/XMP-Toolkit-SDK/blob/581c41213ddcee1fbc72cbb532531102a6617a25/third-party/zuid/interfaces/MD5.h). Expat's compiled `siphash.h` identifies its implementation as CC0; that upstream identification is recorded in `Licenses/Expat-SipHash-CC0-NOTICE` with immutable source links.
