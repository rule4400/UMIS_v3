#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
VENDOR_DIR=${SCRIPT_DIR:h}
REPOSITORY_DIR=${VENDOR_DIR:h:h}
OUTPUT_XCFRAMEWORK="$VENDOR_DIR/AdobeXMPBridge.xcframework"

ADOBE_REPOSITORY="https://github.com/adobe/XMP-Toolkit-SDK.git"
ADOBE_COMMIT="581c41213ddcee1fbc72cbb532531102a6617a25"
EXPAT_URL="https://github.com/libexpat/libexpat/releases/download/R_2_5_0/expat-2.5.0.tar.gz"
EXPAT_SHA256="6b902ab103843592be5e99504f846ec109c1abb692e85347587f237a4ffa1033"
ZLIB_URL="https://github.com/madler/zlib/releases/download/v1.2.13/zlib-1.2.13.tar.gz"
ZLIB_SHA256="b3a24de97a8fdbc835b9833169501030b8977031bcb54b3b3ac13740f846ab30"
CMAKE_URL="https://github.com/Kitware/CMake/releases/download/v3.23.2/cmake-3.23.2-macos-universal.tar.gz"
CMAKE_SHA256="853a0f9af148c5ef47282ffffee06c4c9f257be2635936755f39ca13c3286c88"

for command_name in git curl shasum tar xcrun xcodebuild lipo libtool strip; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        print -u2 "Required command is unavailable: $command_name"
        exit 1
    fi
done

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/umis-xmp-build.XXXXXX")
if [[ -z "$WORK_DIR" || ! -d "$WORK_DIR" ]]; then
    print -u2 "Unable to create a private XMP build directory"
    exit 1
fi
cleanup() {
    if [[ "${UMIS_XMP_KEEP_WORK:-0}" == "1" ]]; then
        print "Preserving XMP build workspace: $WORK_DIR"
    else
        rm -rf -- "$WORK_DIR"
    fi
}
trap cleanup EXIT INT TERM HUP

verify_sha256() {
    local expected=$1
    local file_path=$2
    local actual
    actual=$(shasum -a 256 "$file_path" | awk '{print $1}')
    if [[ "$actual" != "$expected" ]]; then
        print -u2 "SHA-256 mismatch for $file_path"
        print -u2 "expected: $expected"
        print -u2 "actual:   $actual"
        exit 1
    fi
}

download_verified() {
    local url=$1
    local expected=$2
    local output=$3
    curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --output "$output" "$url"
    verify_sha256 "$expected" "$output"
}

print "Fetching Adobe XMP Toolkit SDK at pinned commit $ADOBE_COMMIT"
git -c advice.detachedHead=false clone --filter=blob:none --no-checkout "$ADOBE_REPOSITORY" "$WORK_DIR/XMP-Toolkit-SDK"
git -C "$WORK_DIR/XMP-Toolkit-SDK" fetch --depth 1 origin "$ADOBE_COMMIT"
git -C "$WORK_DIR/XMP-Toolkit-SDK" checkout --detach "$ADOBE_COMMIT"
if [[ "$(git -C "$WORK_DIR/XMP-Toolkit-SDK" rev-parse HEAD)" != "$ADOBE_COMMIT" ]]; then
    print -u2 "Adobe XMP Toolkit checkout does not match the pinned commit"
    exit 1
fi

download_verified "$EXPAT_URL" "$EXPAT_SHA256" "$WORK_DIR/expat-2.5.0.tar.gz"
download_verified "$ZLIB_URL" "$ZLIB_SHA256" "$WORK_DIR/zlib-1.2.13.tar.gz"
download_verified "$CMAKE_URL" "$CMAKE_SHA256" "$WORK_DIR/cmake-3.23.2-macos-universal.tar.gz"

mkdir -p "$WORK_DIR/dependencies/expat" "$WORK_DIR/dependencies/zlib" "$WORK_DIR/dependencies/cmake"
tar -xzf "$WORK_DIR/expat-2.5.0.tar.gz" -C "$WORK_DIR/dependencies/expat"
tar -xzf "$WORK_DIR/zlib-1.2.13.tar.gz" -C "$WORK_DIR/dependencies/zlib"
tar -xzf "$WORK_DIR/cmake-3.23.2-macos-universal.tar.gz" -C "$WORK_DIR/dependencies/cmake"

SDK_ROOT="$WORK_DIR/XMP-Toolkit-SDK"
mkdir -p "$SDK_ROOT/third-party/expat/lib" "$SDK_ROOT/third-party/zlib"
cp -R "$WORK_DIR/dependencies/expat/expat-2.5.0/lib/." "$SDK_ROOT/third-party/expat/lib/"
cp -R "$WORK_DIR/dependencies/zlib/zlib-1.2.13/." "$SDK_ROOT/third-party/zlib/"

git -C "$SDK_ROOT" apply "$VENDOR_DIR/Patches/0001-use-active-macos-sdk-and-target-13.patch"
git -C "$SDK_ROOT" apply "$VENDOR_DIR/Patches/0002-zlib-modern-apple-target.patch"

CMAKE_BIN="$WORK_DIR/dependencies/cmake/cmake-3.23.2-macos-universal/CMake.app/Contents/bin/cmake"
BUILD_DIR="$SDK_ROOT/build/xcode/static/universal-umis"
mkdir -p "$BUILD_DIR"

print "Generating a DOM-disabled macOS 13 Universal 2 Xcode project"
"$CMAKE_BIN" -S "$SDK_ROOT/build" -B "$BUILD_DIR" -G Xcode \
    -DCMAKE_CL_64=On \
    -DCMAKE_BUILD_TYPE=Release \
    -DXMP_CMAKEFOLDER_NAME=xcode/static/universal-umis \
    -DXMP_BUILD_STATIC=On \
    -DCMAKE_TOOLCHAIN_FILE="$SDK_ROOT/build/shared/ToolchainLLVM.cmake" \
    -DCMAKE_LIBCPP=On \
    -DINCLUDE_CPP_DOM_SOURCE=FALSE \
    -Wno-dev

print "Building Adobe XMPCore and XMPFiles for arm64 and x86_64"
xcodebuild \
    -quiet \
    -project "$BUILD_DIR/XMPToolkitSDK64.xcodeproj" \
    -scheme ALL_BUILD \
    -configuration Release \
    ARCHS='arm64 x86_64' \
    ONLY_ACTIVE_ARCH=NO \
    MACOSX_DEPLOYMENT_TARGET=13.0 \
    CODE_SIGNING_ALLOWED=NO \
    build

CORE_LIBRARY="$SDK_ROOT/public/libraries/macintosh/universal/Release/libXMPCoreStatic.a"
FILES_LIBRARY="$SDK_ROOT/public/libraries/macintosh/universal/Release/libXMPFilesStatic.a"
for library in "$CORE_LIBRARY" "$FILES_LIBRARY"; do
    if [[ ! -f "$library" ]]; then
        print -u2 "Expected Adobe static library is missing: $library"
        exit 1
    fi
    architectures=$(lipo -archs "$library")
    if [[ "$architectures" != *arm64* || "$architectures" != *x86_64* ]]; then
        print -u2 "Adobe static library is not Universal 2: $library ($architectures)"
        exit 1
    fi
done

SDK_PATH=$(xcrun --sdk macosx --show-sdk-path)
mkdir -p "$WORK_DIR/bridge"
for architecture in arm64 x86_64; do
    architecture_dir="$WORK_DIR/bridge/$architecture"
    mkdir -p "$architecture_dir"
    xcrun --sdk macosx clang++ \
        -arch "$architecture" \
        -isysroot "$SDK_PATH" \
        -mmacosx-version-min=13.0 \
        -std=c++17 \
        -O2 \
        -fshort-enums \
        -funsigned-char \
        -fno-common \
        -fvisibility=hidden \
        -fvisibility-inlines-hidden \
        -fstack-protector-strong \
        -D_FORTIFY_SOURCE=2 \
        -DXMP_StaticBuild=1 \
        -DXMP_64=1 \
        -DMAC_ENV=1 \
        -DENABLE_CPP_DOM_MODEL=0 \
        -I"$VENDOR_DIR/Bridge/include" \
        -I"$SDK_ROOT" \
        -I"$SDK_ROOT/public/include" \
        -c "$VENDOR_DIR/Bridge/UMISXMPBridge.cpp" \
        -o "$architecture_dir/UMISXMPBridge.o"

    lipo "$CORE_LIBRARY" -thin "$architecture" -output "$architecture_dir/libXMPCoreStatic.a"
    lipo "$FILES_LIBRARY" -thin "$architecture" -output "$architecture_dir/libXMPFilesStatic.a"
    ZERO_AR_DATE=1 libtool -static \
        -o "$architecture_dir/libAdobeXMPBridge.a" \
        "$architecture_dir/UMISXMPBridge.o" \
        "$architecture_dir/libXMPCoreStatic.a" \
        "$architecture_dir/libXMPFilesStatic.a"
    strip -S -x "$architecture_dir/libAdobeXMPBridge.a"
done

UNIVERSAL_LIBRARY="$WORK_DIR/bridge/libAdobeXMPBridge.a"
lipo -create \
    "$WORK_DIR/bridge/arm64/libAdobeXMPBridge.a" \
    "$WORK_DIR/bridge/x86_64/libAdobeXMPBridge.a" \
    -output "$UNIVERSAL_LIBRARY"

architectures=$(lipo -archs "$UNIVERSAL_LIBRARY")
if [[ "$architectures" != *arm64* || "$architectures" != *x86_64* ]]; then
    print -u2 "Combined bridge library is not Universal 2: $architectures"
    exit 1
fi

STATIC_FRAMEWORK="$WORK_DIR/AdobeXMPBridge.framework"
mkdir -p "$STATIC_FRAMEWORK/Headers" "$STATIC_FRAMEWORK/Modules"
cp "$UNIVERSAL_LIBRARY" "$STATIC_FRAMEWORK/AdobeXMPBridge"
cp "$VENDOR_DIR/Bridge/include/UMISXMPBridge.h" "$STATIC_FRAMEWORK/Headers/"
cp "$VENDOR_DIR/Bridge/include/module.modulemap" "$STATIC_FRAMEWORK/Modules/"
cp "$VENDOR_DIR/Bridge/Info.plist" "$STATIC_FRAMEWORK/Info.plist"

NEW_XCFRAMEWORK="$WORK_DIR/AdobeXMPBridge.xcframework"
xcodebuild -create-xcframework \
    -framework "$STATIC_FRAMEWORK" \
    -output "$NEW_XCFRAMEWORK"

XCFRAMEWORK_LIBRARY=$(find "$NEW_XCFRAMEWORK" -type f -path '*/AdobeXMPBridge.framework/AdobeXMPBridge' -print -quit)
if [[ -z "$XCFRAMEWORK_LIBRARY" ]]; then
    print -u2 "XCFramework does not contain its static framework binary"
    exit 1
fi
architectures=$(lipo -archs "$XCFRAMEWORK_LIBRARY")
if [[ "$architectures" != *arm64* || "$architectures" != *x86_64* ]]; then
    print -u2 "XCFramework slice is not Universal 2: $architectures"
    exit 1
fi

STAGED_OUTPUT="$VENDOR_DIR/.AdobeXMPBridge.xcframework.new"
rm -rf -- "$STAGED_OUTPUT"
cp -R "$NEW_XCFRAMEWORK" "$STAGED_OUTPUT"
if [[ -e "$OUTPUT_XCFRAMEWORK" ]]; then
    rm -rf -- "$OUTPUT_XCFRAMEWORK"
fi
mv "$STAGED_OUTPUT" "$OUTPUT_XCFRAMEWORK"

print "Created: $OUTPUT_XCFRAMEWORK"
OUTPUT_LIBRARY=$(find "$OUTPUT_XCFRAMEWORK" -type f -path '*/AdobeXMPBridge.framework/AdobeXMPBridge' -print -quit)
print "Architectures: $(lipo -archs "$OUTPUT_LIBRARY")"
print "Library SHA-256: $(shasum -a 256 "$OUTPUT_LIBRARY" | awk '{print $1}')"
print "Build host: $(sw_vers -productVersion), $(xcodebuild -version | tr '\n' ' ')"
