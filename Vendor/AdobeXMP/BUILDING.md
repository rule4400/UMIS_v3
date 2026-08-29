# Rebuilding AdobeXMPBridge.xcframework

## Prerequisites

The build script targets macOS and requires a selected full Xcode installation. It checks for these commands before changing the checked-in artifact:

```text
git curl shasum tar xcrun xcodebuild lipo libtool strip
```

The host must be able to reach the pinned HTTPS URLs in `DEPENDENCIES.md`. The script creates a private directory with `mktemp -d`; by default it deletes that workspace on exit. Set `UMIS_XMP_KEEP_WORK=1` only when a retained source/build tree is needed for audit or diagnosis.

## One-command build

From the repository root:

```sh
Vendor/AdobeXMP/Scripts/build_xcframework.sh
```

The script performs these operations:

1. clones Adobe's official repository and checks out exactly commit `581c41213ddcee1fbc72cbb532531102a6617a25` in detached-HEAD state;
2. downloads Expat 2.5.0, zlib 1.2.13, and CMake 3.23.2 Universal, then verifies their SHA-256 values before extraction;
3. stages Expat and zlib into the locations expected by the Adobe build;
4. applies the two reviewed patches in `Patches/`;
5. generates an Xcode project with DOM disabled and static libraries enabled;
6. builds Adobe `XMPCore` and `XMPFiles` for `arm64` and `x86_64` with a macOS 13.0 deployment target;
7. compiles the UMIS C ABI bridge separately for each architecture;
8. combines the bridge, XMPCore, and XMPFiles static archives per architecture, strips local/debug symbols, then creates one Universal 2 archive;
9. wraps the Universal 2 archive, public C header, module map, and framework Info.plist as a static framework, then creates, verifies, stages, and promotes `Vendor/AdobeXMP/AdobeXMPBridge.xcframework`.

## Adobe CMake configuration

The generated project uses these material options:

```text
-DCMAKE_CL_64=On
-DCMAKE_BUILD_TYPE=Release
-DXMP_BUILD_STATIC=On
-DCMAKE_TOOLCHAIN_FILE=build/shared/ToolchainLLVM.cmake
-DCMAKE_LIBCPP=On
-DINCLUDE_CPP_DOM_SOURCE=FALSE
```

`INCLUDE_CPP_DOM_SOURCE=FALSE` is intentional. UMIS only needs the established `SXMPMeta`/`SXMPFiles` API for `xmp:Rating`; Adobe's optional C++ DOM implementation is excluded to reduce code size and dependency surface.

The Xcode build explicitly sets:

```text
ARCHS=arm64 x86_64
ONLY_ACTIVE_ARCH=NO
MACOSX_DEPLOYMENT_TARGET=13.0
CODE_SIGNING_ALLOWED=NO
```

This is an unsigned static dependency. The framework directory is only the XCFramework packaging envelope for a static archive; it is not a dynamically loaded framework. Signing and notarization apply to the final UMIS app/package, not independently to the static `AdobeXMPBridge.framework/AdobeXMPBridge` payload.

## Bridge compiler flags

The bridge is compiled as C++17 for each architecture using the active macOS SDK and `-mmacosx-version-min=13.0`. The material flags and definitions are:

```text
-std=c++17
-O2
-fshort-enums
-funsigned-char
-fno-common
-fvisibility=hidden
-fvisibility-inlines-hidden
-fstack-protector-strong
-D_FORTIFY_SOURCE=2
-DXMP_StaticBuild=1
-DXMP_64=1
-DMAC_ENV=1
-DENABLE_CPP_DOM_MODEL=0
```

`-fshort-enums`, `-funsigned-char`, `XMP_StaticBuild`, `XMP_64`, and `MAC_ENV` match the Adobe static-library ABI on this platform. `ENABLE_CPP_DOM_MODEL=0` matches the DOM-disabled CMake configuration. Because `-fshort-enums` changes the representation of enum types, the exported status type is explicitly `uint32_t`, not a C enum; this keeps the Swift-imported signature and compiled bridge return ABI identical. Only symbols declared in `Bridge/include/UMISXMPBridge.h` are exposed to Swift; every C++ exception is converted to a C status and message within the bridge.

`XMP_StaticBuild=1` is also what makes Adobe's official `SXMPFiles::OpenFile(XMP_IO *)`
overload available. ABI version 3 uses that overload for the `_at` entry points, whose custom
`XMP_IO` keeps media and nested safe-update temps relative to a held parent directory descriptor.
The safe-update temp is created as a fresh exclusive mode-`0600` file in a private random mode-`0700`
recovery directory. Pending, sealed, and cleanup-state manifests are also exclusive mode-`0600`
files. Descriptor-to-descriptor metadata copying before promotion may change a replacement's final
mode to the source mode; the old original moved into recovery by the swap remains the same inode and
keeps its source mode, ACLs, and xattrs. A successful write returns a process-local token;
Swift/Core independently reopens and verifies the committed rating, then consumes the token through
`umis_xmp_finalize_recovery_at`. The finalizer deletes noncritical artifacts first and the old
original last, and durably records `manifest.cleanup.json` state `committedOriginalRemoved` before
removing sealed, pending, and finally the cleanup-state manifest. Keeping the cleanup manifest until
last prevents a later crash from exposing an older manifest that falsely implies an original backup
is still linked. Removing this second phase would leave full-size recovery files and
held descriptors behind and is a release-blocking ABI violation.
Do not remove the static-build definition or replace the static payload with a dynamic framework;
either change would invalidate the capability implementation as well as the binary ABI.

## Verification and accepting a new artifact

After a build, first inspect the architecture and compute the complete candidate manifest:

```sh
lipo -archs Vendor/AdobeXMP/AdobeXMPBridge.xcframework/macos-arm64_x86_64/AdobeXMPBridge.framework/AdobeXMPBridge
find Vendor/AdobeXMP/AdobeXMPBridge.xcframework -type f -print0 \
  | LC_ALL=C sort -z \
  | xargs -0 shasum -a 256
```

Expected architectures are both `arm64` and `x86_64`. Review the new hashes, update `Artifacts.sha256` only after accepting the rebuilt artifact, then run:

```sh
Vendor/AdobeXMP/Scripts/verify_xcframework.sh
swift test --parallel
swift build --configuration release
```

`verify_xcframework.sh` requires the static framework binary, public header, module map, outer XCFramework Info.plist, and inner framework Info.plist. It validates both property lists, checks the inner framework identity and macOS 13.0 minimum, confirms Universal 2 with `lipo`, and verifies:

- packaged header, module map, and framework template exactly match the reviewed source copies;
- public ABI version is exactly 3 and each architecture exports exactly the reviewed seven-function C ABI, including `umis_xmp_finalize_recovery_at` and excluding the retired path-authorized write;
- Adobe commit, archive SHA-256 values, DOM-disabled setting, and macOS 13 compiler target remain pinned in the build script;
- `SourceInputs.sha256` matches all reviewed bridge/build inputs;
- `Artifacts.sha256` matches all five checked-in XCFramework files.

The source and artifact manifests are separate on purpose: this prevents an old ABI-v2 binary from
passing merely because its old artifact hashes were internally consistent with an ABI-v3 source tree.

The symbol check is necessary but not sufficient. Before accepting an ABI-v3 artifact, the test run
must also exercise both finalizer outcomes: (1) an original backup is still linked, which is a
structured failure, and (2) the original has been proven unlinked but cleanup residue remains,
which is a committed result with `recoveryAttentionRequired`. Crash fixtures must be discoverable
through `manifest.cleanup.json`, `manifest.sealed.json`, and `manifest.pending.json` without any
automatic deletion. Every nonzero write token must be consumed exactly once, including independent
upper-readback failures.

The release test matrix must also cover safeguards outside the static artifact: one O(N) frozen-root
recovery scan plus advisory `flock` authorization per rating batch; O(1) authorized-parent checks;
bounded descriptor-relative ASCII-case-variant `fstatat` probes for RAW sidecar collisions on a
case-sensitive APFS volume; exact-FD FinderInfo label round trips that preserve every non-label byte
and named Finder tags; and one `NSFileCoordinator` accessor spanning the capability write and
readback (normal embedded write intent, content-independent Finder metadata intent, and combined
media-read/sidecar-write intents). See `SAFETY.md` for the cooperative-writer threat boundary.

Do not treat a hash mismatch after rebuilding as an automatic corruption finding. The sources and archive downloads are pinned, but an Xcode/SDK/toolchain upgrade can legitimately change generated object code. Such a change must still be reviewed, tested on both architectures, recorded in `DEPENDENCIES.md`, and intentionally accepted into `Artifacts.sha256`.
