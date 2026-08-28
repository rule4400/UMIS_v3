#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
OUTPUT_DIR=${UMIS_OUTPUT_DIR:-${PROJECT_DIR}/dist}
VERSION=$(<"${PROJECT_DIR}/VERSION")
NOTARY_PROFILE=${UMIS_NOTARY_PROFILE:-}
SOURCE_ENTITLEMENTS_PATH="${PROJECT_DIR}/Resources/RinkanUMIS.entitlements"

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
if ! plutil -lint "${SOURCE_ENTITLEMENTS_PATH}" >/dev/null; then
    print -u2 "The reviewed release entitlements are not a valid property list."
    exit 3
fi
SOURCE_ENTITLEMENTS_CANONICAL=$(plutil -convert xml1 -o - "${SOURCE_ENTITLEMENTS_PATH}")
SOURCE_ENTITLEMENTS_SHA256=$(
    print -rn -- "${SOURCE_ENTITLEMENTS_CANONICAL}" | shasum -a 256 | awk '{print $1}'
)

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

# Serialize release builds that share an output directory. This protects the
# canonical app/DMG, timestamped backup selection, and evidence publication
# from another build_release.sh process using the same paths.
mkdir -p "${OUTPUT_DIR}"
RELEASE_LOCK_PATH="${OUTPUT_DIR}/.umis-release.lock"
RELEASE_LOCK_HELD=0
release_lock_cleanup() {
    if [[ "${RELEASE_LOCK_HELD}" != "1" ]]; then
        return 0
    fi
    if [[ -f "${RELEASE_LOCK_PATH}" ]]; then
        local LOCK_OWNER=$(<"${RELEASE_LOCK_PATH}")
        if [[ "${LOCK_OWNER}" != "$$" ]]; then
            print -u2 "WARNING: release lock ownership changed from $$ to ${LOCK_OWNER}; it was not removed."
            return 1
        fi
        if ! /bin/rm -f -- "${RELEASE_LOCK_PATH}"; then
            print -u2 "WARNING: release lock could not be removed: ${RELEASE_LOCK_PATH}"
            return 1
        fi
    fi
    RELEASE_LOCK_HELD=0
}
release_lock_only_exit() {
    local RELEASE_STATUS=$?
    trap - EXIT INT HUP TERM
    release_lock_cleanup || true
    return "${RELEASE_STATUS}"
}
if ! /usr/bin/shlock -p "$$" -f "${RELEASE_LOCK_PATH}"; then
    LOCK_OWNER="unknown"
    if [[ -f "${RELEASE_LOCK_PATH}" ]]; then
        LOCK_OWNER=$(<"${RELEASE_LOCK_PATH}")
    fi
    print -u2 "Another release process holds ${RELEASE_LOCK_PATH} (PID ${LOCK_OWNER})."
    exit 4
fi
RELEASE_LOCK_HELD=1
trap release_lock_only_exit EXIT
trap 'exit 130' INT
trap 'exit 129' HUP
trap 'exit 143' TERM

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
BUNDLE_ICON_FILE=$(plutil -extract CFBundleIconFile raw -o - "${APP_DIR}/Contents/Info.plist")
APP_ICON_PATH="${APP_DIR}/Contents/Resources/${BUNDLE_ICON_FILE}"
SOURCE_ICON_PATH="${PROJECT_DIR}/Resources/RinkanUMIS.icns"
EXPECTED_BUNDLE_SHORT_VERSION=${VERSION%%[-+]*}
if [[ "${BUNDLE_IDENTIFIER}" != "jp.rinkan.umis" || \
    "${BUNDLE_SHORT_VERSION}" != "${EXPECTED_BUNDLE_SHORT_VERSION}" || \
    "${MINIMUM_SYSTEM_VERSION}" != "13.0" || \
    "${BUNDLE_ICON_FILE}" != "RinkanUMIS.icns" || ! -s "${APP_ICON_PATH}" || \
    ! -s "${SOURCE_ICON_PATH}" ]]; then
    print -u2 "Bundle identity, marketing version, or deployment target does not match the reviewed release source."
    exit 7
fi
APP_ICON_SHA256=$(shasum -a 256 "${APP_ICON_PATH}" | awk '{print $1}')
SOURCE_ICON_SHA256=$(shasum -a 256 "${SOURCE_ICON_PATH}" | awk '{print $1}')
if [[ "${APP_ICON_SHA256}" != "${SOURCE_ICON_SHA256}" ]]; then
    print -u2 "The release application icon does not match the reviewed source icon."
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
PREPACKAGE_BUNDLE_BUILD_VERSION="${BUNDLE_BUILD_VERSION}"
PREPACKAGE_TEAM_IDENTIFIER="${EXPECTED_TEAM_IDENTIFIER}"
PREPACKAGE_LEAF_AUTHORITY="${EXPECTED_LEAF_AUTHORITY}"

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
if [[ -e "${SYMBOL_ARCHIVE}" || -e "${SYMBOL_ARCHIVE}.sha256" ]]; then
    BACKUP_SYMBOLS="${SYMBOL_ARCHIVE}.previous.$(date +%Y%m%d%H%M%S)"
    BACKUP_SYMBOLS_SUFFIX=1
    while [[ -e "${BACKUP_SYMBOLS}" || -e "${BACKUP_SYMBOLS}.sha256" || \
        -e "${BACKUP_SYMBOLS}.sha256.original" ]]; do
        BACKUP_SYMBOLS="${SYMBOL_ARCHIVE}.previous.$(date +%Y%m%d%H%M%S).${BACKUP_SYMBOLS_SUFFIX}"
        (( BACKUP_SYMBOLS_SUFFIX += 1 ))
    done
    if [[ -e "${SYMBOL_ARCHIVE}" ]]; then
        BACKUP_SYMBOLS_SHA256=$(shasum -a 256 "${SYMBOL_ARCHIVE}" | awk '{print $1}')
        mv "${SYMBOL_ARCHIVE}" "${BACKUP_SYMBOLS}"
    fi
    if [[ -e "${SYMBOL_ARCHIVE}.sha256" ]]; then
        mv "${SYMBOL_ARCHIVE}.sha256" "${BACKUP_SYMBOLS}.sha256.original"
    fi
    if [[ -e "${BACKUP_SYMBOLS}" ]]; then
        BACKUP_SYMBOLS_CHECKSUM_TEMP=$(mktemp "${SYMBOL_DIR}/.${BACKUP_SYMBOLS:t}.sha256.XXXXXX")
        print -r -- "${BACKUP_SYMBOLS_SHA256}  ${BACKUP_SYMBOLS:t}" > "${BACKUP_SYMBOLS_CHECKSUM_TEMP}"
        mv "${BACKUP_SYMBOLS_CHECKSUM_TEMP}" "${BACKUP_SYMBOLS}.sha256"
    fi
fi
ditto -c -k --sequesterRsrc --keepParent "${DSYM_DIR}" "${SYMBOL_ARCHIVE}"
unzip -tq "${SYMBOL_ARCHIVE}"
SYMBOL_ARCHIVE_SHA256=$(shasum -a 256 "${SYMBOL_ARCHIVE}" | awk '{print $1}')
SYMBOL_CHECKSUM_TEMP=$(mktemp "${SYMBOL_DIR}/.${SYMBOL_ARCHIVE:t}.sha256.XXXXXX")
print -r -- "${SYMBOL_ARCHIVE_SHA256}  ${SYMBOL_ARCHIVE:t}" > "${SYMBOL_CHECKSUM_TEMP}"
mv "${SYMBOL_CHECKSUM_TEMP}" "${SYMBOL_ARCHIVE}.sha256"

STAGING_DIR=$(mktemp -d "${TMPDIR:-/tmp}/umis-release.XXXXXX")
DMG_WORK_DIR=$(mktemp -d "${OUTPUT_DIR}/.umis-dmg.XXXXXX")
DMG_MOUNT_DIR=""
DMG_DEVICE=""
DMG_DETACH_REQUIRED=0
RELEASE_MANIFEST_TEMP=""
RELEASE_MANIFEST_SHA256_TEMP=""
DMG_SHA256_TEMP=""
BACKUP_DMG_CHECKSUM_TEMP=""
PUBLICATION_STARTED=0
PUBLICATION_COMPLETE=0
PUBLICATION_ROLLED_BACK=0
NEW_DMG_PROMOTED=0
NEW_DMG_CHECKSUM_PUBLISHED=0
RELEASE_MANIFEST_PUBLISHED=0
RELEASE_MANIFEST_CHECKSUM_PUBLISHED=0
detach_release_dmg() {
    local DETACH_FAILED=0
    if [[ "${DMG_DETACH_REQUIRED}" == "1" && -n "${DMG_MOUNT_DIR}" ]]; then
        local DETACH_TARGET=${DMG_DEVICE:-${DMG_MOUNT_DIR}}
        if ! hdiutil detach "${DETACH_TARGET}" >/dev/null 2>&1; then
            if ! hdiutil detach -force "${DETACH_TARGET}" >/dev/null 2>&1; then
                if [[ "${DETACH_TARGET}" != "${DMG_MOUNT_DIR}" ]] && \
                    { hdiutil detach "${DMG_MOUNT_DIR}" >/dev/null 2>&1 || \
                        hdiutil detach -force "${DMG_MOUNT_DIR}" >/dev/null 2>&1; }; then
                    DETACH_FAILED=0
                else
                    DETACH_FAILED=1
                fi
            fi
        fi
        if [[ "${DETACH_FAILED}" == "0" ]]; then
            DMG_DETACH_REQUIRED=0
        fi
    fi
    if [[ -n "${DMG_MOUNT_DIR}" && -d "${DMG_MOUNT_DIR}" ]]; then
        if rmdir "${DMG_MOUNT_DIR}" 2>/dev/null; then
            # If both detach forms failed but the mount directory can be
            # removed before a device was identified, attach never completed.
            if [[ -z "${DMG_DEVICE}" ]]; then
                DETACH_FAILED=0
                DMG_DETACH_REQUIRED=0
            fi
        else
            DETACH_FAILED=1
        fi
    fi
    if [[ "${DETACH_FAILED}" == "0" ]]; then
        DMG_MOUNT_DIR=""
        DMG_DEVICE=""
    fi
    return "${DETACH_FAILED}"
}
retain_failed_release() {
    local RELEASE_STATUS=$?
    trap - EXIT INT HUP TERM
    if [[ "${PUBLICATION_STARTED}" == "1" && "${PUBLICATION_COMPLETE}" == "0" && \
        "${PUBLICATION_ROLLED_BACK}" == "0" ]] && (( ${+functions[rollback_release_publication]} )); then
        if ! rollback_release_publication; then
            print -u2 "WARNING: release publication rollback was incomplete; inspect the retained work directory and artifact paths."
        fi
    fi
    if ! detach_release_dmg; then
        print -u2 "WARNING: release DMG detachment failed for device '${DMG_DEVICE}' at '${DMG_MOUNT_DIR}'."
        print -u2 "Inspect with 'hdiutil info' and detach that exact device before another release attempt."
    fi
    local TEMPORARY_EVIDENCE
    for TEMPORARY_EVIDENCE in \
        "${RELEASE_MANIFEST_TEMP}" \
        "${RELEASE_MANIFEST_SHA256_TEMP}" \
        "${DMG_SHA256_TEMP}" \
        "${BACKUP_DMG_CHECKSUM_TEMP}"; do
        if [[ -n "${TEMPORARY_EVIDENCE}" && -e "${TEMPORARY_EVIDENCE}" && -d "${DMG_WORK_DIR}" ]]; then
            if ! mv "${TEMPORARY_EVIDENCE}" "${DMG_WORK_DIR}/${TEMPORARY_EVIDENCE:t}.retained"; then
                print -u2 "WARNING: temporary release evidence could not be retained: ${TEMPORARY_EVIDENCE}"
            fi
        fi
    done
    if [[ -d "${STAGING_DIR}" ]]; then
        if ! mv "${STAGING_DIR}" "${STAGING_DIR}.retained"; then
            print -u2 "WARNING: failed release staging could not be retained: ${STAGING_DIR}"
        fi
    fi
    if [[ -d "${DMG_WORK_DIR}" ]]; then
        if ! mv "${DMG_WORK_DIR}" "${DMG_WORK_DIR}.retained"; then
            print -u2 "WARNING: failed release DMG work could not be retained: ${DMG_WORK_DIR}"
        fi
    fi
    release_lock_cleanup || true
    return "${RELEASE_STATUS}"
}
trap retain_failed_release EXIT
trap 'exit 130' INT
trap 'exit 129' HUP
trap 'exit 143' TERM
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

# Validate the exact application contained in the final, stapled disk image.
# The mount point is private, read-only, and never exposed to Finder. The EXIT
# trap owns detachment from before attach starts so an interrupted attach cannot
# leave a release image mounted.
DMG_MOUNT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/umis-release-mount.XXXXXX")
DMG_ATTACH_RESULT="${STAGING_DIR}/hdiutil-attach.plist"
DMG_DETACH_REQUIRED=1
if ! hdiutil attach \
    -readonly \
    -nobrowse \
    -noautoopen \
    -mountpoint "${DMG_MOUNT_DIR}" \
    -plist \
    "${DMG_WORK_PATH}" > "${DMG_ATTACH_RESULT}"; then
    print -u2 "The stapled release DMG could not be mounted read-only for final application validation."
    exit 9
fi

DMG_ENTITY_COUNT=$(plutil -extract system-entities raw -expect array -o - "${DMG_ATTACH_RESULT}")
if ! print -r -- "${DMG_ENTITY_COUNT}" | grep -Eq '^[0-9]+$'; then
    print -u2 "The release DMG attach result did not contain a valid system-entities array."
    exit 9
fi
DMG_DEVICE_MATCH_COUNT=0
DMG_SELECTED_DEVICE=""
for (( DMG_ENTITY_INDEX = 0; DMG_ENTITY_INDEX < DMG_ENTITY_COUNT; DMG_ENTITY_INDEX += 1 )); do
    DMG_ENTITY_MOUNT=$(
        plutil -extract "system-entities.${DMG_ENTITY_INDEX}.mount-point" raw -expect string \
            -o - "${DMG_ATTACH_RESULT}" 2>/dev/null || true
    )
    DMG_ENTITY_DEVICE=$(
        plutil -extract "system-entities.${DMG_ENTITY_INDEX}.dev-entry" raw -expect string \
            -o - "${DMG_ATTACH_RESULT}" 2>/dev/null || true
    )
    if [[ -n "${DMG_ENTITY_MOUNT}" && "${DMG_ENTITY_MOUNT:A}" == "${DMG_MOUNT_DIR:A}" ]]; then
        (( DMG_DEVICE_MATCH_COUNT += 1 ))
        DMG_SELECTED_DEVICE="${DMG_ENTITY_DEVICE}"
    fi
done
if [[ "${DMG_DEVICE_MATCH_COUNT}" != "1" || "${DMG_SELECTED_DEVICE}" != /dev/disk* ]]; then
    print -u2 "The release DMG mount could not be bound unambiguously to its attached device."
    exit 9
fi
DMG_DEVICE="${DMG_SELECTED_DEVICE}"
DMG_DEVICE_INFO=$(diskutil info -plist "${DMG_DEVICE}")
DMG_ACTUAL_MOUNT=$(
    print -r -- "${DMG_DEVICE_INFO}" |
        plutil -extract MountPoint raw -expect string -o - -
)
DMG_MEDIA_WRITABLE=$(
    print -r -- "${DMG_DEVICE_INFO}" |
        plutil -extract WritableMedia raw -expect bool -o - -
)
DMG_VOLUME_WRITABLE=$(
    print -r -- "${DMG_DEVICE_INFO}" |
        plutil -extract WritableVolume raw -expect bool -o - -
)
DMG_WRITABLE=$(
    print -r -- "${DMG_DEVICE_INFO}" |
        plutil -extract Writable raw -expect bool -o - -
)
if [[ "${DMG_ACTUAL_MOUNT:A}" != "${DMG_MOUNT_DIR:A}" || \
    "${DMG_MEDIA_WRITABLE}" != "false" || \
    "${DMG_VOLUME_WRITABLE}" != "false" || \
    "${DMG_WRITABLE}" != "false" ]]; then
    print -u2 "The release DMG was not mounted at the private mount point with read-only media and volume state."
    exit 9
fi

DMG_APP_DIR="${DMG_MOUNT_DIR}/RINKAN UMIS.app"
DMG_APP_CONTENTS_DIR="${DMG_APP_DIR}/Contents"
DMG_APP_MACOS_DIR="${DMG_APP_CONTENTS_DIR}/MacOS"
DMG_APP_RESOURCES_DIR="${DMG_APP_CONTENTS_DIR}/Resources"
DMG_APP_EXECUTABLE="${DMG_APP_DIR}/Contents/MacOS/RinkanUMIS"
DMG_APP_INFO_PLIST="${DMG_APP_DIR}/Contents/Info.plist"
if [[ ! -d "${DMG_APP_DIR}" || -L "${DMG_APP_DIR}" || \
    ! -d "${DMG_APP_CONTENTS_DIR}" || -L "${DMG_APP_CONTENTS_DIR}" || \
    ! -d "${DMG_APP_MACOS_DIR}" || -L "${DMG_APP_MACOS_DIR}" || \
    ! -d "${DMG_APP_RESOURCES_DIR}" || -L "${DMG_APP_RESOURCES_DIR}" || \
    ! -f "${DMG_APP_EXECUTABLE}" || ! -x "${DMG_APP_EXECUTABLE}" || -L "${DMG_APP_EXECUTABLE}" || \
    ! -f "${DMG_APP_INFO_PLIST}" || -L "${DMG_APP_INFO_PLIST}" ]]; then
    print -u2 "The stapled release DMG does not contain the expected regular RINKAN UMIS application bundle."
    exit 9
fi
if ! plutil -lint "${DMG_APP_INFO_PLIST}" >/dev/null; then
    print -u2 "The application Info.plist inside the stapled release DMG is malformed."
    exit 9
fi

DMG_APP_ARCHS=$(lipo -archs "${DMG_APP_EXECUTABLE}")
DMG_APP_ARCH_COUNT=$(print -r -- "${DMG_APP_ARCHS}" | awk '{print NF}')
if [[ " ${DMG_APP_ARCHS} " != *" arm64 "* || " ${DMG_APP_ARCHS} " != *" x86_64 "* || \
    "${DMG_APP_ARCH_COUNT}" != "2" ]]; then
    print -u2 "Universal 2 validation failed for the application inside the stapled DMG: ${DMG_APP_ARCHS}"
    exit 9
fi

DMG_BUNDLE_IDENTIFIER=$(plutil -extract CFBundleIdentifier raw -o - "${DMG_APP_INFO_PLIST}")
DMG_BUNDLE_EXECUTABLE=$(plutil -extract CFBundleExecutable raw -o - "${DMG_APP_INFO_PLIST}")
DMG_BUNDLE_PACKAGE_TYPE=$(plutil -extract CFBundlePackageType raw -o - "${DMG_APP_INFO_PLIST}")
DMG_BUNDLE_SHORT_VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "${DMG_APP_INFO_PLIST}")
DMG_BUNDLE_BUILD_VERSION=$(plutil -extract CFBundleVersion raw -o - "${DMG_APP_INFO_PLIST}")
DMG_MINIMUM_SYSTEM_VERSION=$(plutil -extract LSMinimumSystemVersion raw -o - "${DMG_APP_INFO_PLIST}")
DMG_BUNDLE_ICON_FILE=$(plutil -extract CFBundleIconFile raw -o - "${DMG_APP_INFO_PLIST}")
DMG_APP_ICON_PATH="${DMG_APP_DIR}/Contents/Resources/${DMG_BUNDLE_ICON_FILE}"
if [[ "${DMG_BUNDLE_IDENTIFIER}" != "jp.rinkan.umis" || \
    "${DMG_BUNDLE_EXECUTABLE}" != "RinkanUMIS" || \
    "${DMG_BUNDLE_PACKAGE_TYPE}" != "APPL" || \
    "${DMG_BUNDLE_SHORT_VERSION}" != "${EXPECTED_BUNDLE_SHORT_VERSION}" || \
    "${DMG_BUNDLE_BUILD_VERSION}" != "${PREPACKAGE_BUNDLE_BUILD_VERSION}" || \
    "${DMG_MINIMUM_SYSTEM_VERSION}" != "13.0" || \
    "${DMG_BUNDLE_ICON_FILE}" != "RinkanUMIS.icns" || \
    ! -f "${DMG_APP_ICON_PATH}" || -L "${DMG_APP_ICON_PATH}" ]]; then
    print -u2 "Bundle identity, executable, versions, deployment target, or icon inside the stapled DMG is not the reviewed value."
    exit 9
fi
if ! print -r -- "${DMG_BUNDLE_BUILD_VERSION}" | grep -Eq '^[0-9]+([.][0-9]+){0,2}$'; then
    print -u2 "The application inside the stapled DMG has an invalid CFBundleVersion."
    exit 9
fi

DMG_APP_EXECUTABLE_SHA256=$(shasum -a 256 "${DMG_APP_EXECUTABLE}" | awk '{print $1}')
DMG_APP_ICON_SHA256=$(shasum -a 256 "${DMG_APP_ICON_PATH}" | awk '{print $1}')
if [[ "${DMG_APP_ICON_SHA256}" != "${SOURCE_ICON_SHA256}" ]]; then
    print -u2 "The application icon inside the stapled DMG does not match the reviewed source icon."
    exit 9
fi

codesign --verify --all-architectures --deep --strict --verbose=2 "${DMG_APP_DIR}"
DMG_EXPECTED_TEAM_IDENTIFIER=""
DMG_EXPECTED_LEAF_AUTHORITY=""
DMG_EXPECTED_ENTITLEMENTS_SHA256=""
DMG_CODE_DIRECTORY_HASHES=""
for ARCHITECTURE in ${=DMG_APP_ARCHS}; do
    DMG_SIGNATURE_DETAILS=$(codesign -d --arch "${ARCHITECTURE}" --verbose=4 "${DMG_APP_DIR}" 2>&1)
    DMG_LEAF_AUTHORITY=$(print -r -- "${DMG_SIGNATURE_DETAILS}" | sed -n 's/^Authority=\(Developer ID Application:.*\)$/\1/p' | head -n 1)
    DMG_TEAM_IDENTIFIER=$(print -r -- "${DMG_SIGNATURE_DETAILS}" | sed -n 's/^TeamIdentifier=//p' | head -n 1)
    DMG_SIGNED_IDENTIFIER=$(print -r -- "${DMG_SIGNATURE_DETAILS}" | sed -n 's/^Identifier=//p' | head -n 1)
    DMG_CODE_DIRECTORY_HASH=$(print -r -- "${DMG_SIGNATURE_DETAILS}" | sed -n 's/^CDHash=//p' | head -n 1)
    if [[ -z "${DMG_LEAF_AUTHORITY}" ]]; then
        print -u2 "Developer ID signature validation failed for the ${ARCHITECTURE} slice inside the stapled DMG."
        exit 9
    fi
    if ! print -r -- "${DMG_SIGNATURE_DETAILS}" | grep -Eq 'flags=0x[0-9A-Fa-f]+\([^)]*runtime'; then
        print -u2 "Hardened Runtime validation failed for the ${ARCHITECTURE} slice inside the stapled DMG."
        exit 9
    fi
    if ! print -r -- "${DMG_SIGNATURE_DETAILS}" | grep -q '^Timestamp='; then
        print -u2 "Trusted timestamp validation failed for the ${ARCHITECTURE} slice inside the stapled DMG."
        exit 9
    fi
    if ! print -r -- "${DMG_TEAM_IDENTIFIER}" | grep -Eq '^[A-Z0-9]{10}$'; then
        print -u2 "Developer Team identifier is missing from the ${ARCHITECTURE} slice inside the stapled DMG."
        exit 9
    fi
    if [[ "${DMG_SIGNED_IDENTIFIER}" != "${DMG_BUNDLE_IDENTIFIER}" ]]; then
        print -u2 "The signed identifier does not match Info.plist for the ${ARCHITECTURE} slice inside the stapled DMG."
        exit 9
    fi
    if ! print -r -- "${DMG_CODE_DIRECTORY_HASH}" | grep -Eq '^[0-9A-Fa-f]{40}$'; then
        print -u2 "The ${ARCHITECTURE} slice inside the stapled DMG has no valid Code Directory hash."
        exit 9
    fi
    DMG_CODE_DIRECTORY_HASHES="${DMG_CODE_DIRECTORY_HASHES}${ARCHITECTURE}:${DMG_CODE_DIRECTORY_HASH};"
    if [[ -z "${DMG_EXPECTED_TEAM_IDENTIFIER}" ]]; then
        DMG_EXPECTED_TEAM_IDENTIFIER="${DMG_TEAM_IDENTIFIER}"
        DMG_EXPECTED_LEAF_AUTHORITY="${DMG_LEAF_AUTHORITY}"
    elif [[ "${DMG_TEAM_IDENTIFIER}" != "${DMG_EXPECTED_TEAM_IDENTIFIER}" || \
        "${DMG_LEAF_AUTHORITY}" != "${DMG_EXPECTED_LEAF_AUTHORITY}" ]]; then
        print -u2 "Universal 2 slices inside the stapled DMG are not signed by the same Developer ID identity."
        exit 9
    fi

    DMG_EMBEDDED_ENTITLEMENTS=$(codesign -d --arch "${ARCHITECTURE}" --entitlements :- "${DMG_APP_DIR}" 2>/dev/null)
    if ! print -r -- "${DMG_EMBEDDED_ENTITLEMENTS}" | plutil -lint - >/dev/null; then
        print -u2 "Malformed embedded entitlements for the ${ARCHITECTURE} slice inside the stapled DMG."
        exit 9
    fi
    DMG_CANONICAL_ENTITLEMENTS=$(
        print -r -- "${DMG_EMBEDDED_ENTITLEMENTS}" | plutil -convert xml1 -o - -
    )
    DMG_ENTITLEMENTS_SHA256=$(
        print -rn -- "${DMG_CANONICAL_ENTITLEMENTS}" | shasum -a 256 | awk '{print $1}'
    )
    if [[ "${DMG_ENTITLEMENTS_SHA256}" != "${SOURCE_ENTITLEMENTS_SHA256}" ]]; then
        print -u2 "Embedded entitlements for the ${ARCHITECTURE} slice inside the stapled DMG do not match the reviewed source entitlements."
        exit 9
    fi
    if [[ -z "${DMG_EXPECTED_ENTITLEMENTS_SHA256}" ]]; then
        DMG_EXPECTED_ENTITLEMENTS_SHA256="${DMG_ENTITLEMENTS_SHA256}"
    elif [[ "${DMG_ENTITLEMENTS_SHA256}" != "${DMG_EXPECTED_ENTITLEMENTS_SHA256}" ]]; then
        print -u2 "Universal 2 slices inside the stapled DMG do not carry identical entitlements."
        exit 9
    fi
    DMG_GET_TASK_ALLOW=$(
        print -r -- "${DMG_EMBEDDED_ENTITLEMENTS}" |
            plutil -extract com.apple.security.get-task-allow raw -o - - 2>/dev/null || true
    )
    if [[ "${DMG_GET_TASK_ALLOW}" == "true" ]]; then
        print -u2 "The ${ARCHITECTURE} slice inside the stapled DMG contains com.apple.security.get-task-allow."
        exit 9
    fi
    for DANGEROUS_ENTITLEMENT in \
        com.apple.security.cs.allow-jit \
        com.apple.security.cs.allow-unsigned-executable-memory \
        com.apple.security.cs.disable-executable-page-protection \
        com.apple.security.cs.disable-library-validation; do
        DMG_DANGEROUS_VALUE=$(
            print -r -- "${DMG_EMBEDDED_ENTITLEMENTS}" |
                plutil -extract "${DANGEROUS_ENTITLEMENT}" raw -o - - 2>/dev/null || true
        )
        if [[ "${DMG_DANGEROUS_VALUE}" == "true" ]]; then
            print -u2 "The ${ARCHITECTURE} slice inside the stapled DMG contains prohibited entitlement ${DANGEROUS_ENTITLEMENT}."
            exit 9
        fi
    done
    DMG_MACH_O_MINIMUM_VERSION=$(
        otool -arch "${ARCHITECTURE}" -l "${DMG_APP_EXECUTABLE}" |
            awk '$1 == "cmd" && $2 == "LC_BUILD_VERSION" {modern=1}
                 modern && $1 == "minos" && !found {version=$2; found=1}
                 $1 == "cmd" && $2 == "LC_VERSION_MIN_MACOSX" {legacy=1}
                 legacy && $1 == "version" && !found {version=$2; found=1}
                 END {if (found) print version}'
    )
    if [[ "${DMG_MACH_O_MINIMUM_VERSION}" != "${DMG_MINIMUM_SYSTEM_VERSION}" ]]; then
        print -u2 "The ${ARCHITECTURE} deployment target inside the stapled DMG is ${DMG_MACH_O_MINIMUM_VERSION}, expected ${DMG_MINIMUM_SYSTEM_VERSION}."
        exit 9
    fi
done
if [[ "${DMG_EXPECTED_TEAM_IDENTIFIER}" != "${PREPACKAGE_TEAM_IDENTIFIER}" || \
    "${DMG_EXPECTED_LEAF_AUTHORITY}" != "${PREPACKAGE_LEAF_AUTHORITY}" ]]; then
    print -u2 "The Developer ID identity inside the stapled DMG does not match the pre-packaging application."
    exit 9
fi

DMG_APP_UUIDS=$(dwarfdump --uuid "${DMG_APP_EXECUTABLE}" | awk '{print $2, $3}' | sort)
DMG_APP_UUID_COUNT=$(print -r -- "${DMG_APP_UUIDS}" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
if [[ "${DMG_APP_UUID_COUNT}" != "2" || "${DMG_APP_UUIDS}" != *'(arm64)'* || \
    "${DMG_APP_UUIDS}" != *'(x86_64)'* || "${DMG_APP_UUIDS}" != "${DSYM_UUIDS}" ]]; then
    print -u2 "The dSYM UUIDs do not match the application executable inside the stapled DMG."
    exit 9
fi
spctl --assess --type execute --verbose=2 "${DMG_APP_DIR}"

# Persist only values obtained from the application inside the final DMG.
ARCHS="${DMG_APP_ARCHS}"
BUNDLE_IDENTIFIER="${DMG_BUNDLE_IDENTIFIER}"
BUNDLE_SHORT_VERSION="${DMG_BUNDLE_SHORT_VERSION}"
BUNDLE_BUILD_VERSION="${DMG_BUNDLE_BUILD_VERSION}"
MINIMUM_SYSTEM_VERSION="${DMG_MINIMUM_SYSTEM_VERSION}"
EXPECTED_TEAM_IDENTIFIER="${DMG_EXPECTED_TEAM_IDENTIFIER}"
EXPECTED_LEAF_AUTHORITY="${DMG_EXPECTED_LEAF_AUTHORITY}"
APP_UUIDS="${DMG_APP_UUIDS}"
APP_ICON_SHA256="${DMG_APP_ICON_SHA256}"
APP_EXECUTABLE_SHA256="${DMG_APP_EXECUTABLE_SHA256}"
EMBEDDED_ENTITLEMENTS_SHA256="${DMG_EXPECTED_ENTITLEMENTS_SHA256}"
CODE_DIRECTORY_HASHES="${DMG_CODE_DIRECTORY_HASHES}"

if ! detach_release_dmg; then
    print -u2 "The final release DMG could not be detached cleanly after validation."
    exit 9
fi
if [[ -n "$(git status --porcelain)" || "$(git rev-parse HEAD)" != "${RELEASE_COMMIT}" || \
    "$(git rev-parse "refs/tags/${EXPECTED_TAG}")" != "${RELEASE_TAG_OBJECT}" ]]; then
    print -u2 "Repository state changed during notarization; distribution was stopped."
    exit 4
fi

RELEASE_MANIFEST="${OUTPUT_DIR}/manifests/release-${VERSION}-${RELEASE_RUN}.txt"
RELEASE_MANIFEST_SUFFIX=1
while [[ -e "${RELEASE_MANIFEST}" || -e "${RELEASE_MANIFEST}.sha256" ]]; do
    RELEASE_MANIFEST="${OUTPUT_DIR}/manifests/release-${VERSION}-${RELEASE_RUN}.${RELEASE_MANIFEST_SUFFIX}.txt"
    (( RELEASE_MANIFEST_SUFFIX += 1 ))
done
FINAL_DMG_SHA256=$(shasum -a 256 "${DMG_WORK_PATH}" | awk '{print $1}')
FINAL_DSYM_SHA256=$(shasum -a 256 "${SYMBOL_ARCHIVE}" | awk '{print $1}')
NOTARY_RESULT_SHA256=$(shasum -a 256 "${NOTARY_RESULT_PATH}" | awk '{print $1}')
NOTARY_DETAIL_SHA256=$(shasum -a 256 "${NOTARY_DETAIL_PATH}" | awk '{print $1}')
RELEASE_MANIFEST_TEMP=$(mktemp "${RELEASE_MANIFEST:h}/.${RELEASE_MANIFEST:t}.XXXXXX")
RELEASE_MANIFEST_SHA256_TEMP=$(mktemp "${RELEASE_MANIFEST:h}/.${RELEASE_MANIFEST:t}.sha256.XXXXXX")
DMG_SHA256_TEMP=$(mktemp "${OUTPUT_DIR}/.${DMG_PATH:t}.sha256.XXXXXX")
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
    print "app_code_directory_hashes=${CODE_DIRECTORY_HASHES}"
    print "app_entitlements_sha256=${EMBEDDED_ENTITLEMENTS_SHA256}"
    print "app_validation_source=stapled_dmg"
    print "operation_store_schema_version=${DB_SCHEMA_VERSION}"
    print "package_resolved_sha256=${PACKAGE_RESOLVED_SHA256}"
    print "sdk=$(xcrun --sdk macosx --show-sdk-version)"
    print "xcode=$(xcodebuild -version | tr '\n' ' ')"
    print "swift=$(swift --version | head -n 1)"
    print "notary_submission=${NOTARY_ID}"
    print "notary_status=${NOTARY_STATUS}"
    print "notary_submission_sha256=${NOTARY_RESULT_SHA256}"
    print "notary_log_sha256=${NOTARY_DETAIL_SHA256}"
    print "app_executable_sha256=${APP_EXECUTABLE_SHA256}"
    print "app_icon_sha256=${APP_ICON_SHA256}"
    print "dmg_sha256=${FINAL_DMG_SHA256}"
    print "dsym_sha256=${FINAL_DSYM_SHA256}"
} > "${RELEASE_MANIFEST_TEMP}"
RELEASE_MANIFEST_SHA256=$(shasum -a 256 "${RELEASE_MANIFEST_TEMP}" | awk '{print $1}')
print -r -- "${RELEASE_MANIFEST_SHA256}  ${RELEASE_MANIFEST:t}" > "${RELEASE_MANIFEST_SHA256_TEMP}"
print -r -- "${FINAL_DMG_SHA256}  ${DMG_PATH:t}" > "${DMG_SHA256_TEMP}"

BACKUP_DMG=""
BACKUP_DMG_EXISTED=0
BACKUP_DMG_CHECKSUM_EXISTED=0
BACKUP_DMG_GENERATED_CHECKSUM=0
BACKUP_DMG_ORIGINAL_CHECKSUM=""
BACKUP_DMG_CHECKSUM_TEMP=""

rollback_release_publication() {
    local ROLLBACK_FAILED=0
    if [[ "${RELEASE_MANIFEST_CHECKSUM_PUBLISHED}" == "1" && -e "${RELEASE_MANIFEST}.sha256" ]]; then
        mv "${RELEASE_MANIFEST}.sha256" "${RELEASE_MANIFEST_SHA256_TEMP}" || ROLLBACK_FAILED=1
    fi
    if [[ "${RELEASE_MANIFEST_PUBLISHED}" == "1" && -e "${RELEASE_MANIFEST}" ]]; then
        mv "${RELEASE_MANIFEST}" "${RELEASE_MANIFEST_TEMP}" || ROLLBACK_FAILED=1
    fi
    if [[ "${NEW_DMG_CHECKSUM_PUBLISHED}" == "1" && -e "${DMG_PATH}.sha256" ]]; then
        mv "${DMG_PATH}.sha256" "${DMG_SHA256_TEMP}" || ROLLBACK_FAILED=1
    fi
    if [[ "${NEW_DMG_PROMOTED}" == "1" && -e "${DMG_PATH}" ]]; then
        mv "${DMG_PATH}" "${DMG_WORK_PATH}" || ROLLBACK_FAILED=1
    fi
    if [[ "${BACKUP_DMG_GENERATED_CHECKSUM}" == "1" && -e "${BACKUP_DMG}.sha256" ]]; then
        mv "${BACKUP_DMG}.sha256" "${DMG_WORK_DIR}/previous-dmg.generated.sha256" || ROLLBACK_FAILED=1
    fi
    if [[ "${BACKUP_DMG_EXISTED}" == "1" && -e "${BACKUP_DMG}" && ! -e "${DMG_PATH}" ]]; then
        mv "${BACKUP_DMG}" "${DMG_PATH}" || ROLLBACK_FAILED=1
    fi
    if [[ "${BACKUP_DMG_CHECKSUM_EXISTED}" == "1" && -e "${BACKUP_DMG_ORIGINAL_CHECKSUM}" && \
        ! -e "${DMG_PATH}.sha256" ]]; then
        mv "${BACKUP_DMG_ORIGINAL_CHECKSUM}" "${DMG_PATH}.sha256" || ROLLBACK_FAILED=1
    fi
    if [[ "${ROLLBACK_FAILED}" == "0" ]]; then
        PUBLICATION_ROLLED_BACK=1
    fi
    return "${ROLLBACK_FAILED}"
}

PUBLICATION_STARTED=1
if [[ -e "${DMG_PATH}" || -e "${DMG_PATH}.sha256" ]]; then
    BACKUP_DMG="${DMG_PATH}.previous.$(date +%Y%m%d%H%M%S)"
    BACKUP_SUFFIX=1
    while [[ -e "${BACKUP_DMG}" || -e "${BACKUP_DMG}.sha256" || \
        -e "${BACKUP_DMG}.sha256.original" ]]; do
        BACKUP_DMG="${DMG_PATH}.previous.$(date +%Y%m%d%H%M%S).${BACKUP_SUFFIX}"
        (( BACKUP_SUFFIX += 1 ))
    done
    if [[ -e "${DMG_PATH}" ]]; then
        BACKUP_DMG_SHA256=$(shasum -a 256 "${DMG_PATH}" | awk '{print $1}')
        BACKUP_DMG_EXISTED=1
        if ! mv "${DMG_PATH}" "${BACKUP_DMG}"; then
            BACKUP_DMG_EXISTED=0
            print -u2 "The existing release DMG could not be moved to its backup path."
            exit 8
        fi
    fi
    if [[ -e "${DMG_PATH}.sha256" ]]; then
        BACKUP_DMG_ORIGINAL_CHECKSUM="${BACKUP_DMG}.sha256.original"
        BACKUP_DMG_CHECKSUM_EXISTED=1
        if ! mv "${DMG_PATH}.sha256" "${BACKUP_DMG_ORIGINAL_CHECKSUM}"; then
            BACKUP_DMG_CHECKSUM_EXISTED=0
            rollback_release_publication || true
            print -u2 "The existing release checksum could not be preserved; the previous DMG was restored when possible."
            exit 8
        fi
    fi
    if [[ "${BACKUP_DMG_EXISTED}" == "1" ]]; then
        BACKUP_DMG_GENERATED_CHECKSUM=1
        if ! BACKUP_DMG_CHECKSUM_TEMP=$(mktemp "${OUTPUT_DIR}/.${BACKUP_DMG:t}.sha256.XXXXXX") || \
            ! print -r -- "${BACKUP_DMG_SHA256}  ${BACKUP_DMG:t}" > "${BACKUP_DMG_CHECKSUM_TEMP}" || \
            ! mv "${BACKUP_DMG_CHECKSUM_TEMP}" "${BACKUP_DMG}.sha256"; then
            BACKUP_DMG_GENERATED_CHECKSUM=0
            rollback_release_publication || true
            print -u2 "A verifiable checksum could not be created for the previous release DMG; it was restored when possible."
            exit 8
        fi
    fi
fi

NEW_DMG_PROMOTED=1
if ! mv "${DMG_WORK_PATH}" "${DMG_PATH}"; then
    NEW_DMG_PROMOTED=0
    rollback_release_publication || true
    print -u2 "The validated release DMG could not be promoted; the previous artifact was restored when possible."
    exit 8
fi
if ! xcrun stapler validate "${DMG_PATH}" || \
    ! hdiutil verify "${DMG_PATH}" || \
    ! codesign --verify --verbose=2 "${DMG_PATH}" || \
    ! spctl --assess --type open --context context:primary-signature --verbose=2 "${DMG_PATH}" || \
    [[ "$(shasum -a 256 "${DMG_PATH}" | awk '{print $1}')" != "${FINAL_DMG_SHA256}" ]]; then
    rollback_release_publication || true
    print -u2 "The promoted release DMG failed final validation; the previous artifact was restored when possible."
    exit 8
fi
NEW_DMG_CHECKSUM_PUBLISHED=1
if ! mv "${DMG_SHA256_TEMP}" "${DMG_PATH}.sha256"; then
    NEW_DMG_CHECKSUM_PUBLISHED=0
    rollback_release_publication || true
    print -u2 "The release DMG checksum could not be published; the previous DMG was restored when possible."
    exit 8
fi
RELEASE_MANIFEST_PUBLISHED=1
if ! mv "${RELEASE_MANIFEST_TEMP}" "${RELEASE_MANIFEST}"; then
    RELEASE_MANIFEST_PUBLISHED=0
    rollback_release_publication || true
    print -u2 "The release manifest could not be published; the previous DMG was restored when possible."
    exit 8
fi
RELEASE_MANIFEST_CHECKSUM_PUBLISHED=1
if ! mv "${RELEASE_MANIFEST_SHA256_TEMP}" "${RELEASE_MANIFEST}.sha256"; then
    RELEASE_MANIFEST_CHECKSUM_PUBLISHED=0
    rollback_release_publication || true
    print -u2 "The release manifest checksum could not be published; the previous DMG was restored when possible."
    exit 8
fi
PUBLICATION_COMPLETE=1
rmdir "${DMG_WORK_DIR}"

rm -r "${STAGING_DIR}"
release_lock_cleanup
trap - EXIT INT HUP TERM
print "${DMG_PATH}"
print "${SYMBOL_ARCHIVE}"
print "${RELEASE_MANIFEST}"
print "${RELEASE_MANIFEST}.sha256"
