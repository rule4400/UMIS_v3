#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
VENDOR_DIR=${SCRIPT_DIR:h}
XCFRAMEWORK="$VENDOR_DIR/AdobeXMPBridge.xcframework"
EXPECTED_SHA_FILE="$VENDOR_DIR/Artifacts.sha256"
SOURCE_SHA_FILE="$VENDOR_DIR/SourceInputs.sha256"
SOURCE_HEADER="$VENDOR_DIR/Bridge/include/UMISXMPBridge.h"
SOURCE_MODULE_MAP="$VENDOR_DIR/Bridge/include/module.modulemap"
SOURCE_FRAMEWORK_INFO="$VENDOR_DIR/Bridge/Info.plist"
BUILD_SCRIPT="$VENDOR_DIR/Scripts/build_xcframework.sh"

if [[ ! -d "$XCFRAMEWORK" ]]; then
    print -u2 "Missing XCFramework: $XCFRAMEWORK"
    exit 1
fi

FRAMEWORK=$(find "$XCFRAMEWORK" -type d -name 'AdobeXMPBridge.framework' -print -quit)
LIBRARY="$FRAMEWORK/AdobeXMPBridge"
HEADER="$FRAMEWORK/Headers/UMISXMPBridge.h"
MODULE_MAP="$FRAMEWORK/Modules/module.modulemap"
FRAMEWORK_INFO="$FRAMEWORK/Info.plist"
if [[ -z "$FRAMEWORK" || ! -f "$LIBRARY" || ! -f "$HEADER" || \
    ! -f "$MODULE_MAP" || ! -f "$FRAMEWORK_INFO" ]]; then
    print -u2 "XCFramework is missing its static framework binary, header, module map, or Info.plist"
    exit 1
fi
if [[ ! -f "$SOURCE_SHA_FILE" ]]; then
    print -u2 "Missing pinned bridge-source manifest: $SOURCE_SHA_FILE"
    exit 1
fi
if ! plutil -lint "$XCFRAMEWORK/Info.plist" "$FRAMEWORK_INFO" >/dev/null; then
    print -u2 "XCFramework contains an invalid property list"
    exit 1
fi
if [[ "$(plutil -extract CFBundlePackageType raw -o - "$FRAMEWORK_INFO")" != "FMWK" || \
      "$(plutil -extract CFBundleExecutable raw -o - "$FRAMEWORK_INFO")" != "AdobeXMPBridge" || \
      "$(plutil -extract LSMinimumSystemVersion raw -o - "$FRAMEWORK_INFO")" != "13.0" ]]; then
    print -u2 "Static framework identity or deployment target is invalid"
    exit 1
fi

if ! cmp -s "$SOURCE_HEADER" "$HEADER"; then
    print -u2 "XCFramework public header differs from the reviewed bridge header"
    exit 1
fi
if ! cmp -s "$SOURCE_MODULE_MAP" "$MODULE_MAP"; then
    print -u2 "XCFramework module map differs from the reviewed bridge module map"
    exit 1
fi
if ! cmp -s "$SOURCE_FRAMEWORK_INFO" "$FRAMEWORK_INFO"; then
    print -u2 "XCFramework Info.plist differs from the reviewed static-framework template"
    exit 1
fi
if ! grep -Eq '^#define UMIS_XMP_BRIDGE_ABI_VERSION 3u$' "$HEADER"; then
    print -u2 "XCFramework does not expose the required AdobeXMPBridge ABI version 3"
    exit 1
fi

ARCHITECTURES=$(lipo -archs "$LIBRARY")
if [[ "$ARCHITECTURES" != *arm64* || "$ARCHITECTURES" != *x86_64* ]]; then
    print -u2 "XCFramework is not Universal 2: $ARCHITECTURES"
    exit 1
fi

EXPECTED_EXPORTS=$'_umis_xmp_finalize_recovery_at\n_umis_xmp_initialize\n_umis_xmp_probe_file\n_umis_xmp_probe_file_at\n_umis_xmp_read_embedded_rating\n_umis_xmp_read_embedded_rating_at\n_umis_xmp_write_embedded_rating_at'
for architecture in arm64 x86_64; do
    ACTUAL_EXPORTS=$(nm -arch "$architecture" -gjU "$LIBRARY" \
        | grep '^_umis_xmp_' \
        | LC_ALL=C sort -u)
    if [[ "$ACTUAL_EXPORTS" != "$EXPECTED_EXPORTS" ]]; then
        print -u2 "AdobeXMPBridge $architecture C ABI does not match the reviewed ABI-v3 symbol set"
        print -u2 "actual exports:"
        print -u2 -- "$ACTUAL_EXPORTS"
        exit 1
    fi
done

if ! grep -Fq 'ADOBE_COMMIT="581c41213ddcee1fbc72cbb532531102a6617a25"' "$BUILD_SCRIPT" || \
   ! grep -Fq 'EXPAT_SHA256="6b902ab103843592be5e99504f846ec109c1abb692e85347587f237a4ffa1033"' "$BUILD_SCRIPT" || \
   ! grep -Fq 'ZLIB_SHA256="b3a24de97a8fdbc835b9833169501030b8977031bcb54b3b3ac13740f846ab30"' "$BUILD_SCRIPT" || \
   ! grep -Fq 'CMAKE_SHA256="853a0f9af148c5ef47282ffffee06c4c9f257be2635936755f39ca13c3286c88"' "$BUILD_SCRIPT" || \
   ! grep -Fq -- '-DINCLUDE_CPP_DOM_SOURCE=FALSE' "$BUILD_SCRIPT" || \
   ! grep -Fq -- '-mmacosx-version-min=13.0' "$BUILD_SCRIPT"; then
    print -u2 "Pinned source provenance or required build policy changed unexpectedly"
    exit 1
fi

(cd "$VENDOR_DIR" && shasum -a 256 -c "$SOURCE_SHA_FILE")
(cd "$VENDOR_DIR" && shasum -a 256 -c "$EXPECTED_SHA_FILE")
print "AdobeXMPBridge XCFramework verified ($ARCHITECTURES)"
