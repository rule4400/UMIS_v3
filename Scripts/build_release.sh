#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
OUTPUT_DIR=${UMIS_OUTPUT_DIR:-${PROJECT_DIR}/dist}
VERSION=$(<"${PROJECT_DIR}/VERSION")
NOTARY_PROFILE=${UMIS_NOTARY_PROFILE:-}

SEMVER_PATTERN='^(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)([.](0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?([+]([0-9A-Za-z-]+)([.][0-9A-Za-z-]+)*)?$'
if [[ -z "${VERSION}" || "${VERSION}" == *$'\n'* ]] || \
    ! print -r -- "${VERSION}" | grep -Eq "${SEMVER_PATTERN}"; then
    print -u2 "VERSION must contain exactly one valid Semantic Version: ${VERSION}"
    exit 2
fi
if [[ -z "${NOTARY_PROFILE}" ]]; then
    print -u2 "UMIS_NOTARY_PROFILE is required. Store credentials with: xcrun notarytool store-credentials <profile>"
    exit 2
fi

VALID_IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null || true)
IDENTITY=${UMIS_CODESIGN_IDENTITY:-}
if [[ -z "${IDENTITY}" ]]; then
    DEVELOPER_ID_LINES=$(print -r -- "${VALID_IDENTITIES}" | grep '"Developer ID Application:' || true)
    DEVELOPER_ID_COUNT=$(print -r -- "${DEVELOPER_ID_LINES}" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
    if [[ "${DEVELOPER_ID_COUNT}" -gt 1 ]]; then
        print -u2 "Multiple Developer ID Application identities are installed. Set UMIS_CODESIGN_IDENTITY explicitly."
        exit 3
    fi
    IDENTITY=$(print -r -- "${DEVELOPER_ID_LINES}" | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -n 1)
else
    MATCHED_IDENTITY_LINES=$(
        {
            print -r -- "${VALID_IDENTITIES}" | grep -F -- "\"${IDENTITY}\"" ||
                print -r -- "${VALID_IDENTITIES}" | grep -F -- " ${IDENTITY} "
        } || true
    )
    MATCHED_IDENTITY_COUNT=$(print -r -- "${MATCHED_IDENTITY_LINES}" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
    MATCHED_IDENTITY_LINE=$(print -r -- "${MATCHED_IDENTITY_LINES}" | head -n 1)
    if [[ "${MATCHED_IDENTITY_COUNT}" != "1" ]]; then
        print -u2 "UMIS_CODESIGN_IDENTITY is missing or ambiguous. Use its certificate SHA-1 fingerprint when necessary."
        exit 3
    fi
    if [[ "${MATCHED_IDENTITY_LINE}" != *'"Developer ID Application:'* ]]; then
        print -u2 "UMIS_CODESIGN_IDENTITY must identify a valid Developer ID Application certificate with an accessible private key."
        exit 3
    fi
fi

if [[ -z "${IDENTITY}" ]]; then
    print -u2 "Developer ID Application identity is not installed in this Keychain."
    exit 3
fi

cd "${PROJECT_DIR}"
if [[ -n "$(git status --porcelain)" ]]; then
    print -u2 "Distribution builds require a clean, committed working tree."
    exit 4
fi

EXPECTED_TAG="v${VERSION}"
if ! git tag --points-at HEAD | grep -Fxq "${EXPECTED_TAG}"; then
    print -u2 "HEAD must carry the reviewed release tag ${EXPECTED_TAG}."
    exit 5
fi
if [[ "$(git cat-file -t "refs/tags/${EXPECTED_TAG}")" != "tag" ]]; then
    print -u2 "Release tag ${EXPECTED_TAG} must be annotated (or signed), not lightweight."
    exit 5
fi
RELEASE_COMMIT=$(git rev-parse HEAD)
RELEASE_TREE=$(git rev-parse "${RELEASE_COMMIT}^{tree}")
RELEASE_TAG_OBJECT=$(git rev-parse "refs/tags/${EXPECTED_TAG}")
if ! xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" --output-format json >/dev/null; then
    print -u2 "The notary profile could not authenticate with Apple's notary service."
    exit 2
fi

UMIS_CONFIGURATION=release \
    UMIS_UNIVERSAL2=1 \
    UMIS_ALLOW_ADHOC=0 \
    UMIS_CODESIGN_IDENTITY="${IDENTITY}" \
    UMIS_OUTPUT_DIR="${OUTPUT_DIR}" \
    "${SCRIPT_DIR}/build_app.sh"

if [[ -n "$(git status --porcelain)" || "$(git rev-parse HEAD)" != "${RELEASE_COMMIT}" || \
    "$(git rev-parse "refs/tags/${EXPECTED_TAG}")" != "${RELEASE_TAG_OBJECT}" ]]; then
    print -u2 "Repository state changed during the application build; distribution was stopped."
    exit 4
fi

APP_DIR="${OUTPUT_DIR}/RINKAN UMIS.app"
ARCHS=$(lipo -archs "${APP_DIR}/Contents/MacOS/RinkanUMIS")
ARCH_COUNT=$(print -r -- "${ARCHS}" | awk '{print NF}')
if [[ " ${ARCHS} " != *" arm64 "* || " ${ARCHS} " != *" x86_64 "* || "${ARCH_COUNT}" != "2" ]]; then
    print -u2 "Universal 2 validation failed: ${ARCHS}"
    exit 6
fi
BUNDLE_IDENTIFIER=$(plutil -extract CFBundleIdentifier raw -o - "${APP_DIR}/Contents/Info.plist")
BUNDLE_SHORT_VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "${APP_DIR}/Contents/Info.plist")
BUNDLE_BUILD_VERSION=$(plutil -extract CFBundleVersion raw -o - "${APP_DIR}/Contents/Info.plist")
MINIMUM_SYSTEM_VERSION=$(plutil -extract LSMinimumSystemVersion raw -o - "${APP_DIR}/Contents/Info.plist")
EXPECTED_BUNDLE_SHORT_VERSION=${VERSION%%[-+]*}
if [[ "${BUNDLE_IDENTIFIER}" != "jp.rinkan.umis" || \
    "${BUNDLE_SHORT_VERSION}" != "${EXPECTED_BUNDLE_SHORT_VERSION}" || \
    "${MINIMUM_SYSTEM_VERSION}" != "13.0" ]]; then
    print -u2 "Bundle identity, marketing version, or deployment target does not match the reviewed release source."
    exit 7
fi

codesign --verify --all-architectures --deep --strict --verbose=2 "${APP_DIR}"
EXPECTED_TEAM_IDENTIFIER=""
EXPECTED_LEAF_AUTHORITY=""
for ARCHITECTURE in ${=ARCHS}; do
    SIGNATURE_DETAILS=$(codesign -d --arch "${ARCHITECTURE}" --verbose=4 "${APP_DIR}" 2>&1)
    LEAF_AUTHORITY=$(print -r -- "${SIGNATURE_DETAILS}" | sed -n 's/^Authority=\(Developer ID Application:.*\)$/\1/p' | head -n 1)
    TEAM_IDENTIFIER=$(print -r -- "${SIGNATURE_DETAILS}" | sed -n 's/^TeamIdentifier=//p' | head -n 1)
    SIGNED_IDENTIFIER=$(print -r -- "${SIGNATURE_DETAILS}" | sed -n 's/^Identifier=//p' | head -n 1)
    if [[ -z "${LEAF_AUTHORITY}" ]]; then
        print -u2 "Developer ID signature validation failed for ${ARCHITECTURE}."
        exit 7
    fi
    if ! print -r -- "${SIGNATURE_DETAILS}" | grep -Eq 'flags=0x[0-9A-Fa-f]+\([^)]*runtime'; then
        print -u2 "Hardened Runtime validation failed for ${ARCHITECTURE}."
        exit 7
    fi
    if ! print -r -- "${SIGNATURE_DETAILS}" | grep -q '^Timestamp='; then
        print -u2 "Trusted timestamp validation failed for ${ARCHITECTURE}."
        exit 7
    fi
    if ! print -r -- "${TEAM_IDENTIFIER}" | grep -Eq '^[A-Z0-9]{10}$'; then
        print -u2 "Developer Team identifier is missing from the ${ARCHITECTURE} application signature."
        exit 7
    fi
    if [[ "${SIGNED_IDENTIFIER}" != "${BUNDLE_IDENTIFIER}" ]]; then
        print -u2 "The signed identifier does not match Info.plist for ${ARCHITECTURE}."
        exit 7
    fi
    if [[ -z "${EXPECTED_TEAM_IDENTIFIER}" ]]; then
        EXPECTED_TEAM_IDENTIFIER="${TEAM_IDENTIFIER}"
        EXPECTED_LEAF_AUTHORITY="${LEAF_AUTHORITY}"
    elif [[ "${TEAM_IDENTIFIER}" != "${EXPECTED_TEAM_IDENTIFIER}" || \
        "${LEAF_AUTHORITY}" != "${EXPECTED_LEAF_AUTHORITY}" ]]; then
        print -u2 "Universal 2 slices are not signed by the same Developer ID identity."
        exit 7
    fi
    EMBEDDED_ENTITLEMENTS=$(codesign -d --arch "${ARCHITECTURE}" --entitlements :- "${APP_DIR}" 2>/dev/null)
    if ! print -r -- "${EMBEDDED_ENTITLEMENTS}" | plutil -lint - >/dev/null; then
        print -u2 "Malformed embedded entitlements for ${ARCHITECTURE}."
        exit 7
    fi
    GET_TASK_ALLOW=$(
        print -r -- "${EMBEDDED_ENTITLEMENTS}" |
            plutil -extract com.apple.security.get-task-allow raw -o - - 2>/dev/null || true
    )
    if [[ "${GET_TASK_ALLOW}" == "true" ]]; then
        print -u2 "Distribution builds must not contain com.apple.security.get-task-allow."
        exit 7
    fi
    for DANGEROUS_ENTITLEMENT in \
        com.apple.security.cs.allow-jit \
        com.apple.security.cs.allow-unsigned-executable-memory \
        com.apple.security.cs.disable-executable-page-protection \
        com.apple.security.cs.disable-library-validation; do
        DANGEROUS_VALUE=$(
            print -r -- "${EMBEDDED_ENTITLEMENTS}" |
                plutil -extract "${DANGEROUS_ENTITLEMENT}" raw -o - - 2>/dev/null || true
        )
        if [[ "${DANGEROUS_VALUE}" == "true" ]]; then
            print -u2 "Distribution build contains prohibited entitlement ${DANGEROUS_ENTITLEMENT}."
            exit 7
        fi
    done
    MACH_O_MINIMUM_VERSION=$(
        otool -arch "${ARCHITECTURE}" -l "${APP_DIR}/Contents/MacOS/RinkanUMIS" |
            awk '$1 == "cmd" && $2 == "LC_BUILD_VERSION" {modern=1}
                 modern && $1 == "minos" && !found {version=$2; found=1}
                 $1 == "cmd" && $2 == "LC_VERSION_MIN_MACOSX" {legacy=1}
                 legacy && $1 == "version" && !found {version=$2; found=1}
                 END {if (found) print version}'
    )
    if [[ "${MACH_O_MINIMUM_VERSION}" != "${MINIMUM_SYSTEM_VERSION}" ]]; then
        print -u2 "The ${ARCHITECTURE} deployment target is ${MACH_O_MINIMUM_VERSION}, expected ${MINIMUM_SYSTEM_VERSION}."
        exit 7
    fi
done

BUILD_BIN_DIR=$(swift build --configuration release --arch arm64 --arch x86_64 --show-bin-path)
DSYM_DIR="${BUILD_BIN_DIR}/RinkanUMIS.dSYM"
if [[ ! -d "${DSYM_DIR}" ]]; then
    print -u2 "The Universal 2 dSYM was not produced: ${DSYM_DIR}"
    exit 7
fi
APP_UUIDS=$(dwarfdump --uuid "${APP_DIR}/Contents/MacOS/RinkanUMIS" | awk '{print $2, $3}' | sort)
DSYM_UUIDS=$(dwarfdump --uuid "${DSYM_DIR}" | awk '{print $2, $3}' | sort)
APP_UUID_COUNT=$(print -r -- "${APP_UUIDS}" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
if [[ "${APP_UUID_COUNT}" != "2" || "${APP_UUIDS}" != *'(arm64)'* || \
    "${APP_UUIDS}" != *'(x86_64)'* || "${APP_UUIDS}" != "${DSYM_UUIDS}" ]]; then
    print -u2 "The dSYM UUIDs do not match the application executable."
    exit 7
fi

DB_SCHEMA_VERSION_LINES=$(
    sed -nE 's/^[[:space:]]*public static let currentSchemaVersion = ([0-9]+).*$/\1/p' \
        "${PROJECT_DIR}/Sources/UMISCore/OperationStore.swift"
)
DB_SCHEMA_VERSION_COUNT=$(print -r -- "${DB_SCHEMA_VERSION_LINES}" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
if [[ "${DB_SCHEMA_VERSION_COUNT}" != "1" ]]; then
    print -u2 "OperationStore schema version could not be determined unambiguously for the release manifest."
    exit 7
fi
DB_SCHEMA_VERSION=$(print -r -- "${DB_SCHEMA_VERSION_LINES}" | head -n 1)
PACKAGE_RESOLVED_SHA256="none"
if [[ -f "${PROJECT_DIR}/Package.resolved" ]]; then
    PACKAGE_RESOLVED_SHA256=$(shasum -a 256 "${PROJECT_DIR}/Package.resolved" | awk '{print $1}')
fi

SYMBOL_DIR="${OUTPUT_DIR}/symbols"
mkdir -p "${SYMBOL_DIR}"
SHORT_COMMIT=${RELEASE_COMMIT[1,12]}
SYMBOL_ARCHIVE="${SYMBOL_DIR}/RINKAN-UMIS-${VERSION}-${SHORT_COMMIT}.dSYM.zip"
if [[ -e "${SYMBOL_ARCHIVE}" ]]; then
    BACKUP_SYMBOLS="${SYMBOL_ARCHIVE}.previous.$(date +%Y%m%d%H%M%S)"
    mv "${SYMBOL_ARCHIVE}" "${BACKUP_SYMBOLS}"
    if [[ -e "${SYMBOL_ARCHIVE}.sha256" ]]; then
        mv "${SYMBOL_ARCHIVE}.sha256" "${BACKUP_SYMBOLS}.sha256"
    fi
fi
ditto -c -k --sequesterRsrc --keepParent "${DSYM_DIR}" "${SYMBOL_ARCHIVE}"
unzip -tq "${SYMBOL_ARCHIVE}"
(
    cd "${SYMBOL_DIR}"
    shasum -a 256 "${SYMBOL_ARCHIVE:t}" > "${SYMBOL_ARCHIVE:t}.sha256"
)

STAGING_DIR=$(mktemp -d "${TMPDIR:-/tmp}/umis-release.XXXXXX")
DMG_WORK_DIR=$(mktemp -d "${OUTPUT_DIR}/.umis-dmg.XXXXXX")
retain_failed_release() {
    if [[ -d "${STAGING_DIR}" ]]; then
        mv "${STAGING_DIR}" "${STAGING_DIR}.retained"
    fi
    if [[ -d "${DMG_WORK_DIR}" ]]; then
        mv "${DMG_WORK_DIR}" "${DMG_WORK_DIR}.retained"
    fi
}
trap retain_failed_release EXIT
ditto "${APP_DIR}" "${STAGING_DIR}/RINKAN UMIS.app"
ln -s /Applications "${STAGING_DIR}/Applications"

DMG_PATH="${OUTPUT_DIR}/RINKAN-UMIS-${VERSION}.dmg"
DMG_WORK_PATH="${DMG_WORK_DIR}/RINKAN-UMIS-${VERSION}.dmg"
hdiutil create -volname "RINKAN UMIS" -srcfolder "${STAGING_DIR}" -format UDZO "${DMG_WORK_PATH}"
hdiutil verify "${DMG_WORK_PATH}"

codesign --force --timestamp --sign "${IDENTITY}" "${DMG_WORK_PATH}"
codesign --verify --verbose=2 "${DMG_WORK_PATH}"
mkdir -p "${OUTPUT_DIR}/manifests"
RELEASE_RUN=$(date -u +%Y%m%dT%H%M%SZ)
NOTARY_RESULT_PATH="${OUTPUT_DIR}/manifests/notary-submission-${VERSION}-${RELEASE_RUN}.json"
NOTARY_DETAIL_PATH="${OUTPUT_DIR}/manifests/notary-log-${VERSION}-${RELEASE_RUN}.json"
NOTARY_TIMEOUT=${UMIS_NOTARY_TIMEOUT:-2h}
if ! NOTARY_RESULT=$(
    xcrun notarytool submit "${DMG_WORK_PATH}" \
        --keychain-profile "${NOTARY_PROFILE}" \
        --wait \
        --timeout "${NOTARY_TIMEOUT}" \
        --output-format json
); then
    if [[ -n "${NOTARY_RESULT:-}" ]]; then
        print -r -- "${NOTARY_RESULT}" | tee "${NOTARY_RESULT_PATH}"
    fi
    print -u2 "Notarization submission failed or did not complete within ${NOTARY_TIMEOUT}."
    exit 8
fi
print -r -- "${NOTARY_RESULT}" | tee "${NOTARY_RESULT_PATH}"
NOTARY_STATUS=$(print -r -- "${NOTARY_RESULT}" | plutil -extract status raw -o - -)
NOTARY_ID=$(print -r -- "${NOTARY_RESULT}" | plutil -extract id raw -o - -)
if [[ -z "${NOTARY_ID}" ]]; then
    print -u2 "The notarization response did not contain a submission ID."
    exit 8
fi
if ! xcrun notarytool log \
    --keychain-profile "${NOTARY_PROFILE}" \
    "${NOTARY_ID}" \
    "${NOTARY_DETAIL_PATH}"; then
    print -u2 "The notarization detail log could not be retrieved."
    exit 8
fi
if [[ "${NOTARY_STATUS}" != "Accepted" ]]; then
    print -u2 "Apple did not accept the notarization submission. Review ${NOTARY_DETAIL_PATH}."
    exit 8
fi
if grep -Eiq '"severity"[[:space:]]*:[[:space:]]*"(warning|error)"' "${NOTARY_DETAIL_PATH}"; then
    print -u2 "The notarization log contains a warning or error and requires review."
    exit 8
fi
xcrun stapler staple "${DMG_WORK_PATH}"
xcrun stapler validate "${DMG_WORK_PATH}"
hdiutil verify "${DMG_WORK_PATH}"
codesign --verify --verbose=2 "${DMG_WORK_PATH}"
spctl --assess --type open --context context:primary-signature --verbose=2 "${DMG_WORK_PATH}"
spctl --assess --type execute --verbose=2 "${APP_DIR}"
if [[ -n "$(git status --porcelain)" || "$(git rev-parse HEAD)" != "${RELEASE_COMMIT}" || \
    "$(git rev-parse "refs/tags/${EXPECTED_TAG}")" != "${RELEASE_TAG_OBJECT}" ]]; then
    print -u2 "Repository state changed during notarization; distribution was stopped."
    exit 4
fi

BACKUP_DMG=""
if [[ -e "${DMG_PATH}" ]]; then
    BACKUP_DMG="${DMG_PATH}.previous.$(date +%Y%m%d%H%M%S)"
    BACKUP_SUFFIX=1
    while [[ -e "${BACKUP_DMG}" ]]; do
        BACKUP_DMG="${DMG_PATH}.previous.$(date +%Y%m%d%H%M%S).${BACKUP_SUFFIX}"
        (( BACKUP_SUFFIX += 1 ))
    done
    mv "${DMG_PATH}" "${BACKUP_DMG}"
    if [[ -e "${DMG_PATH}.sha256" ]]; then
        mv "${DMG_PATH}.sha256" "${BACKUP_DMG}.sha256"
    fi
fi
if ! mv "${DMG_WORK_PATH}" "${DMG_PATH}"; then
    if [[ -n "${BACKUP_DMG}" && ! -e "${DMG_PATH}" ]]; then
        mv "${BACKUP_DMG}" "${DMG_PATH}"
        if [[ -e "${BACKUP_DMG}.sha256" ]]; then
            mv "${BACKUP_DMG}.sha256" "${DMG_PATH}.sha256"
        fi
    fi
    exit 8
fi
rmdir "${DMG_WORK_DIR}"
xcrun stapler validate "${DMG_PATH}"
hdiutil verify "${DMG_PATH}"
codesign --verify --verbose=2 "${DMG_PATH}"
spctl --assess --type open --context context:primary-signature --verbose=2 "${DMG_PATH}"
(
    cd "${OUTPUT_DIR}"
    shasum -a 256 "${DMG_PATH:t}" > "${DMG_PATH:t}.sha256"
)

RELEASE_MANIFEST="${OUTPUT_DIR}/manifests/release-${VERSION}-${RELEASE_RUN}.txt"
{
    print "version=${VERSION}"
    print "tag=${EXPECTED_TAG}"
    print "commit=${RELEASE_COMMIT}"
    print "tree=${RELEASE_TREE}"
    print "tag_object=${RELEASE_TAG_OBJECT}"
    print "bundle_identifier=${BUNDLE_IDENTIFIER}"
    print "bundle_short_version=${BUNDLE_SHORT_VERSION}"
    print "bundle_build_version=${BUNDLE_BUILD_VERSION}"
    print "minimum_system_version=${MINIMUM_SYSTEM_VERSION}"
    print "team_identifier=${EXPECTED_TEAM_IDENTIFIER}"
    print "developer_id_authority=${EXPECTED_LEAF_AUTHORITY}"
    print "architectures=${ARCHS}"
    print "app_uuids=$(print -r -- "${APP_UUIDS}" | tr '\n' ';')"
    print "operation_store_schema_version=${DB_SCHEMA_VERSION}"
    print "package_resolved_sha256=${PACKAGE_RESOLVED_SHA256}"
    print "sdk=$(xcrun --sdk macosx --show-sdk-version)"
    print "xcode=$(xcodebuild -version | tr '\n' ' ')"
    print "swift=$(swift --version | head -n 1)"
    print "notary_submission=${NOTARY_ID}"
    print "notary_status=${NOTARY_STATUS}"
    print "notary_submission_sha256=$(shasum -a 256 "${NOTARY_RESULT_PATH}" | awk '{print $1}')"
    print "notary_log_sha256=$(shasum -a 256 "${NOTARY_DETAIL_PATH}" | awk '{print $1}')"
    print "app_executable_sha256=$(shasum -a 256 "${APP_DIR}/Contents/MacOS/RinkanUMIS" | awk '{print $1}')"
    print "dmg_sha256=$(shasum -a 256 "${DMG_PATH}" | awk '{print $1}')"
    print "dsym_sha256=$(shasum -a 256 "${SYMBOL_ARCHIVE}" | awk '{print $1}')"
} > "${RELEASE_MANIFEST}"
(
    cd "${RELEASE_MANIFEST:h}"
    shasum -a 256 "${RELEASE_MANIFEST:t}" > "${RELEASE_MANIFEST:t}.sha256"
)

rm -r "${STAGING_DIR}"
trap - EXIT
print "${DMG_PATH}"
print "${SYMBOL_ARCHIVE}"
print "${RELEASE_MANIFEST}"
print "${RELEASE_MANIFEST}.sha256"
