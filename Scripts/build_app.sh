#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
CONFIGURATION=${UMIS_CONFIGURATION:-release}
OUTPUT_DIR=${UMIS_OUTPUT_DIR:-${PROJECT_DIR}/dist}
APP_NAME="RINKAN UMIS"
APP_DIR="${OUTPUT_DIR}/${APP_NAME}.app"
ICON_NAME="RinkanUMIS.icns"
ICON_SOURCE="${PROJECT_DIR}/Resources/${ICON_NAME}"
VERSION=$(<"${PROJECT_DIR}/VERSION")
# GitHub's default shallow checkout has a history count of one. Its run number is
# monotonic for the repository and therefore a safer CI build-number fallback.
BUILD_NUMBER=${UMIS_BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-$(git -C "${PROJECT_DIR}" rev-list --count HEAD)}}
BUNDLE_VERSION=${UMIS_MARKETING_VERSION:-${VERSION%%[-+]*}}

SEMVER_PATTERN='^(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)([.](0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?([+]([0-9A-Za-z-]+)([.][0-9A-Za-z-]+)*)?$'
if [[ -z "${VERSION}" || "${VERSION}" == *$'\n'* ]] || \
    ! print -r -- "${VERSION}" | grep -Eq "${SEMVER_PATTERN}"; then
    print -u2 "VERSION must contain exactly one valid Semantic Version: ${VERSION}"
    exit 2
fi
if ! print -r -- "${BUNDLE_VERSION}" | grep -Eq '^[0-9]+[.][0-9]+[.][0-9]+$'; then
    print -u2 "Invalid CFBundleShortVersionString: ${BUNDLE_VERSION}"
    print -u2 "Set UMIS_MARKETING_VERSION to exactly three dot-separated integers."
    exit 2
fi
if ! print -r -- "${BUILD_NUMBER}" | grep -Eq '^[0-9]+([.][0-9]+){0,2}$'; then
    print -u2 "Invalid CFBundleVersion: ${BUILD_NUMBER}"
    exit 2
fi
plutil -lint "${PROJECT_DIR}/Resources/Info.plist" >/dev/null
PLIST_ICON_NAME=$(plutil -extract CFBundleIconFile raw -o - "${PROJECT_DIR}/Resources/Info.plist")
if [[ "${PLIST_ICON_NAME}" != "${ICON_NAME}" || ! -s "${ICON_SOURCE}" ]]; then
    print -u2 "The reviewed application icon is missing or does not match CFBundleIconFile."
    exit 2
fi
ICON_FORMAT=$(sips -g format "${ICON_SOURCE}" | awk '/format:/ {print $2}')
ICON_WIDTH=$(sips -g pixelWidth "${ICON_SOURCE}" | awk '/pixelWidth:/ {print $2}')
ICON_HEIGHT=$(sips -g pixelHeight "${ICON_SOURCE}" | awk '/pixelHeight:/ {print $2}')
ICON_PROFILE=$(sips -g profile "${ICON_SOURCE}" | sed -n 's/^[[:space:]]*profile: //p')
ICON_ALPHA=$(sips -g hasAlpha "${ICON_SOURCE}" | awk '/hasAlpha:/ {print $2}')
if [[ "${ICON_FORMAT}" != "icns" || "${ICON_WIDTH}" != "1024" || \
    "${ICON_HEIGHT}" != "1024" || "${ICON_PROFILE}" != *sRGB* || \
    "${ICON_ALPHA}" != "yes" ]]; then
    print -u2 "The reviewed application icon must be a 1024x1024 sRGB ICNS with alpha."
    exit 2
fi
SOURCE_ICON_SHA256=$(shasum -a 256 "${ICON_SOURCE}" | awk '{print $1}')

IDENTITY=${UMIS_CODESIGN_IDENTITY:-}
ALLOW_ADHOC=${UMIS_ALLOW_ADHOC:-0}
if [[ "${ALLOW_ADHOC}" != "0" && "${ALLOW_ADHOC}" != "1" ]]; then
    print -u2 "UMIS_ALLOW_ADHOC must be either 0 or 1."
    exit 2
fi

if [[ -n "${IDENTITY}" ]]; then
    if [[ "${IDENTITY}" == "-" ]]; then
        print -u2 "Use UMIS_ALLOW_ADHOC=1 for local ad-hoc signing; do not pass '-' as an identity."
        exit 2
    fi
    VALID_IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null || true)
    MATCHED_IDENTITY_LINES=$(
        {
            print -r -- "${VALID_IDENTITIES}" | grep -F -- "\"${IDENTITY}\"" ||
                print -r -- "${VALID_IDENTITIES}" | grep -F -- " ${IDENTITY} "
        } || true
    )
    MATCHED_IDENTITY_COUNT=$(print -r -- "${MATCHED_IDENTITY_LINES}" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
    if [[ "${MATCHED_IDENTITY_COUNT}" != "1" ]]; then
        print -u2 "The requested code-signing identity is missing or ambiguous. Use its certificate SHA-1 fingerprint when necessary."
        exit 2
    fi
    MATCHED_IDENTITY_LINE=$(print -r -- "${MATCHED_IDENTITY_LINES}" | head -n 1)
    if [[ "${MATCHED_IDENTITY_LINE}" != *'"Developer ID Application:'* ]]; then
        print -u2 "UMIS_CODESIGN_IDENTITY must identify a Developer ID Application certificate. Use UMIS_ALLOW_ADHOC=1 without an explicit identity for local-only builds."
        exit 2
    fi
elif [[ "${ALLOW_ADHOC}" == "1" ]]; then
    # Local-only ad-hoc mode must not probe or use an installed Developer ID
    # identity. This keeps local validation independent of Keychain access.
    IDENTITY=""
else
    VALID_IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null || true)
    DEVELOPER_ID_LINES=$(print -r -- "${VALID_IDENTITIES}" | grep '"Developer ID Application:' || true)
    DEVELOPER_ID_COUNT=$(print -r -- "${DEVELOPER_ID_LINES}" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
    if [[ "${DEVELOPER_ID_COUNT}" -gt 1 ]]; then
        print -u2 "Multiple Developer ID Application identities are installed. Set UMIS_CODESIGN_IDENTITY explicitly."
        exit 2
    fi
    IDENTITY=$(print -r -- "${DEVELOPER_ID_LINES}" | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -n 1)
    if [[ -z "${IDENTITY}" ]]; then
        print -u2 "Developer ID Application identity is not installed. Set UMIS_ALLOW_ADHOC=1 only for a local development build."
        exit 2
    fi
fi

cd "${PROJECT_DIR}"

"${PROJECT_DIR}/Vendor/AdobeXMP/Scripts/verify_xcframework.sh"

BUILD_ARCH_ARGS=()
if [[ "${UMIS_UNIVERSAL2:-0}" == "1" ]]; then
    BUILD_ARCH_ARGS=(--arch arm64 --arch x86_64)
fi
swift build --configuration "${CONFIGURATION}" --product RinkanUMIS "${BUILD_ARCH_ARGS[@]}"

# `--show-bin-path` must use the exact same architecture tuple as the build.
# Without this, a Universal 2 build can accidentally package a stale thin host binary.
BIN_DIR=$(swift build --configuration "${CONFIGURATION}" "${BUILD_ARCH_ARGS[@]}" --show-bin-path)
EXECUTABLE="${BIN_DIR}/RinkanUMIS"

if [[ ! -x "${EXECUTABLE}" ]]; then
    print -u2 "RinkanUMIS executable was not produced: ${EXECUTABLE}"
    exit 1
fi

mkdir -p "${OUTPUT_DIR}"
STAGING_ROOT=$(mktemp -d "${OUTPUT_DIR}/.umis-app.XXXXXX")
STAGED_APP="${STAGING_ROOT}/${APP_NAME}.app"
cleanup_staging() {
    if [[ -d "${STAGING_ROOT}" ]]; then
        rm -r "${STAGING_ROOT}"
    fi
}
trap cleanup_staging EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

mkdir -p "${STAGED_APP}/Contents/MacOS" "${STAGED_APP}/Contents/Resources"
ditto "${EXECUTABLE}" "${STAGED_APP}/Contents/MacOS/RinkanUMIS"
ditto "${PROJECT_DIR}/Resources/Info.plist" "${STAGED_APP}/Contents/Info.plist"
ditto "${PROJECT_DIR}/Sources/RinkanUMIS/Resources" "${STAGED_APP}/Contents/Resources"
ditto "${ICON_SOURCE}" "${STAGED_APP}/Contents/Resources/${ICON_NAME}"
if [[ -d "${BIN_DIR}/RinkanUMIS_RinkanUMIS.bundle" ]]; then
    ditto "${BIN_DIR}/RinkanUMIS_RinkanUMIS.bundle" "${STAGED_APP}/Contents/Resources/RinkanUMIS_RinkanUMIS.bundle"
fi
plutil -replace CFBundleShortVersionString -string "${BUNDLE_VERSION}" "${STAGED_APP}/Contents/Info.plist"
plutil -replace CFBundleVersion -string "${BUILD_NUMBER}" "${STAGED_APP}/Contents/Info.plist"
BUNDLE_IDENTIFIER=$(plutil -extract CFBundleIdentifier raw -o - "${STAGED_APP}/Contents/Info.plist")
BUNDLE_EXECUTABLE=$(plutil -extract CFBundleExecutable raw -o - "${STAGED_APP}/Contents/Info.plist")
MINIMUM_SYSTEM_VERSION=$(plutil -extract LSMinimumSystemVersion raw -o - "${STAGED_APP}/Contents/Info.plist")
BUNDLE_ICON_NAME=$(plutil -extract CFBundleIconFile raw -o - "${STAGED_APP}/Contents/Info.plist")
if [[ "${BUNDLE_IDENTIFIER}" != "jp.rinkan.umis" || "${BUNDLE_EXECUTABLE}" != "RinkanUMIS" || \
    "${MINIMUM_SYSTEM_VERSION}" != "13.0" || "${BUNDLE_ICON_NAME}" != "${ICON_NAME}" || \
    ! -s "${STAGED_APP}/Contents/Resources/${ICON_NAME}" ]]; then
    print -u2 "The application identity or deployment target in Info.plist is not the reviewed value."
    exit 2
fi
STAGED_ICON_SHA256=$(shasum -a 256 "${STAGED_APP}/Contents/Resources/${ICON_NAME}" | awk '{print $1}')
if [[ "${STAGED_ICON_SHA256}" != "${SOURCE_ICON_SHA256}" ]]; then
    print -u2 "The staged application icon does not match the reviewed source icon."
    exit 2
fi

if [[ -n "${IDENTITY}" ]]; then
    codesign --force --options runtime --timestamp --entitlements "${PROJECT_DIR}/Resources/RinkanUMIS.entitlements" --sign "${IDENTITY}" "${STAGED_APP}"
else
    codesign --force --options runtime --timestamp=none --entitlements "${PROJECT_DIR}/Resources/RinkanUMIS.entitlements" --sign - "${STAGED_APP}"
fi

codesign --verify --all-architectures --deep --strict --verbose=2 "${STAGED_APP}"
plutil -lint "${STAGED_APP}/Contents/Info.plist"

ARCHITECTURES=$(lipo -archs "${STAGED_APP}/Contents/MacOS/RinkanUMIS")
if [[ "${UMIS_UNIVERSAL2:-0}" == "1" ]]; then
    ARCH_COUNT=$(print -r -- "${ARCHITECTURES}" | awk '{print NF}')
    if [[ " ${ARCHITECTURES} " != *" arm64 "* || " ${ARCHITECTURES} " != *" x86_64 "* || "${ARCH_COUNT}" != "2" ]]; then
        print -u2 "Universal 2 validation failed: ${ARCHITECTURES}"
        exit 1
    fi
fi

for ARCHITECTURE in ${=ARCHITECTURES}; do
    SIGNATURE_DETAILS=$(codesign -d --arch "${ARCHITECTURE}" --verbose=4 "${STAGED_APP}" 2>&1)
    if ! print -r -- "${SIGNATURE_DETAILS}" | grep -Eq 'flags=0x[0-9A-Fa-f]+\([^)]*runtime'; then
        print -u2 "Hardened Runtime validation failed for ${ARCHITECTURE}."
        exit 1
    fi
    MACH_O_MINIMUM_VERSION=$(
        otool -arch "${ARCHITECTURE}" -l "${STAGED_APP}/Contents/MacOS/RinkanUMIS" |
            awk '$1 == "cmd" && $2 == "LC_BUILD_VERSION" {modern=1}
                 modern && $1 == "minos" && !found {version=$2; found=1}
                 $1 == "cmd" && $2 == "LC_VERSION_MIN_MACOSX" {legacy=1}
                 legacy && $1 == "version" && !found {version=$2; found=1}
                 END {if (found) print version}'
    )
    if [[ "${MACH_O_MINIMUM_VERSION}" != "${MINIMUM_SYSTEM_VERSION}" ]]; then
        print -u2 "The ${ARCHITECTURE} deployment target is ${MACH_O_MINIMUM_VERSION}, expected ${MINIMUM_SYSTEM_VERSION}."
        exit 1
    fi
done

BACKUP_DIR=""
if [[ -e "${APP_DIR}" ]]; then
    BACKUP_DIR="${APP_DIR}.previous.$(date +%Y%m%d%H%M%S)"
    BACKUP_SUFFIX=1
    while [[ -e "${BACKUP_DIR}" ]]; do
        BACKUP_DIR="${APP_DIR}.previous.$(date +%Y%m%d%H%M%S).${BACKUP_SUFFIX}"
        (( BACKUP_SUFFIX += 1 ))
    done
    mv "${APP_DIR}" "${BACKUP_DIR}"
fi
if ! mv "${STAGED_APP}" "${APP_DIR}"; then
    if [[ -n "${BACKUP_DIR}" && ! -e "${APP_DIR}" ]]; then
        mv "${BACKUP_DIR}" "${APP_DIR}"
    fi
    exit 1
fi
rmdir "${STAGING_ROOT}"
trap - EXIT INT HUP TERM

codesign --verify --all-architectures --deep --strict --verbose=2 "${APP_DIR}"

MANIFEST_DIR="${OUTPUT_DIR}/manifests"
mkdir -p "${MANIFEST_DIR}"
BUILD_RUN=$(date -u +%Y%m%dT%H%M%SZ)
MANIFEST="${MANIFEST_DIR}/build-${VERSION}-${BUILD_NUMBER}-${BUILD_RUN}.txt"
MANIFEST_SUFFIX=1
while [[ -e "${MANIFEST}" ]]; do
    MANIFEST="${MANIFEST_DIR}/build-${VERSION}-${BUILD_NUMBER}-${BUILD_RUN}.${MANIFEST_SUFFIX}.txt"
    (( MANIFEST_SUFFIX += 1 ))
done
WORKTREE_STATE="clean"
WORKTREE_DIFF_SHA256="none"
if [[ -n "$(git status --porcelain)" ]]; then
    WORKTREE_STATE="dirty"
    WORKTREE_DIFF_SHA256=$(
        {
            git diff --binary
            git diff --binary --cached
            git status --porcelain=v1 -z
            while IFS= read -r -d '' UNTRACKED_PATH; do
                if [[ -L "${UNTRACKED_PATH}" ]]; then
                    printf 'untracked-symlink\0%s\0%s\0' "${UNTRACKED_PATH}" "$(readlink "${UNTRACKED_PATH}")"
                elif [[ -f "${UNTRACKED_PATH}" ]]; then
                    UNTRACKED_SHA256=$(shasum -a 256 "${UNTRACKED_PATH}" | awk '{print $1}')
                    printf 'untracked-file\0%s\0%s\0' "${UNTRACKED_PATH}" "${UNTRACKED_SHA256}"
                else
                    printf 'untracked-other\0%s\0' "${UNTRACKED_PATH}"
                fi
            done < <(git ls-files --others --exclude-standard -z)
        } |
            shasum -a 256 |
            awk '{print $1}'
    )
fi
{
    print "version=${VERSION}"
    print "build=${BUILD_NUMBER}"
    print "commit=$(git rev-parse HEAD)"
    print "tree=$(git rev-parse HEAD^{tree})"
    print "worktree_state=${WORKTREE_STATE}"
    print "worktree_diff_sha256=${WORKTREE_DIFF_SHA256}"
    print "project_version=${VERSION}"
    print "bundle_short_version=${BUNDLE_VERSION}"
    print "bundle_identifier=${BUNDLE_IDENTIFIER}"
    print "minimum_system_version=${MINIMUM_SYSTEM_VERSION}"
    print "configuration=${CONFIGURATION}"
    print "architectures=${ARCHITECTURES}"
    print "sdk=$(xcrun --sdk macosx --show-sdk-version)"
    print "xcode=$(xcodebuild -version | tr '\n' ' ')"
    print "swift=$(swift --version | head -n 1)"
    print "app_executable_sha256=$(shasum -a 256 "${APP_DIR}/Contents/MacOS/RinkanUMIS" | awk '{print $1}')"
    print "app_icon_sha256=${SOURCE_ICON_SHA256}"
    print "signature=$(codesign -dv "${APP_DIR}" 2>&1 | tr '\n' ' ')"
} > "${MANIFEST}"

print "${APP_DIR}"
print "${MANIFEST}"
