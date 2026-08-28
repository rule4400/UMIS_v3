#!/bin/zsh
set -euo pipefail

# Independently verifies an existing release without modifying the release
# artifact, repository, signing identity, or notarization record.
#
# Usage:
#   Scripts/verify_release.sh
#   UMIS_VERIFY_VERSION=0.2.0-alpha.3 \
#     UMIS_VERIFY_PROFILE=UMIS_NOTARY \
#     Scripts/verify_release.sh
#
# If more than one release manifest exists for a version, select the exact
# manifest explicitly with UMIS_VERIFY_MANIFEST. A relative path is resolved
# from the project root.

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
VERIFY_VERSION=${UMIS_VERIFY_VERSION:-$(<"${PROJECT_DIR}/VERSION")}
OUTPUT_DIR=${UMIS_VERIFY_OUTPUT_DIR:-${PROJECT_DIR}/dist}
MANIFEST_DIR="${OUTPUT_DIR}/manifests"
NOTARY_PROFILE=${UMIS_VERIFY_PROFILE:-}
EXPECTED_TEAM_IDENTIFIER=${UMIS_EXPECTED_TEAM_IDENTIFIER:-FA43T8UK3P}

fail() {
    print -u2 -- "Release verification failed: $*"
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command is unavailable: $1"
}

manifest_key_count() {
    local KEY=$1
    awk -v key="${KEY}" '
        index($0, key "=") == 1 { count += 1 }
        END { print count + 0 }
    ' "${RELEASE_MANIFEST}"
}

manifest_value() {
    local KEY=$1
    local KEY_COUNT
    KEY_COUNT=$(manifest_key_count "${KEY}")
    [[ "${KEY_COUNT}" == "1" ]] ||
        fail "Manifest key is missing or duplicated: ${KEY}"
    awk -v key="${KEY}" '
        index($0, key "=") == 1 {
            print substr($0, length(key) + 2)
        }
    ' "${RELEASE_MANIFEST}"
}

# Verifies the exact single-record sidecar without asking shasum to follow the
# filename contained in that sidecar. This prevents an altered sidecar from
# making verification read an unrelated path.
verify_sha256_sidecar() {
    local ARTIFACT=$1
    local SIDECAR=$2
    local RECORD_COUNT
    local RECORDED_HASH
    local RECORDED_NAME
    local ACTUAL_HASH

    [[ -f "${ARTIFACT}" ]] || fail "Artifact is missing: ${ARTIFACT}"
    [[ -f "${SIDECAR}" ]] || fail "Checksum sidecar is missing: ${SIDECAR}"

    RECORD_COUNT=$(awk 'NF { count += 1 } END { print count + 0 }' "${SIDECAR}")
    [[ "${RECORD_COUNT}" == "1" ]] ||
        fail "Checksum sidecar must contain exactly one record: ${SIDECAR}"

    RECORDED_HASH=$(awk 'NF { print $1 }' "${SIDECAR}")
    RECORDED_NAME=$(awk 'NF { print $2 }' "${SIDECAR}")
    [[ "${RECORDED_HASH}" =~ '^[0-9a-fA-F]{64}$' ]] ||
        fail "Checksum sidecar contains an invalid SHA-256: ${SIDECAR}"
    [[ "${RECORDED_NAME}" == "${ARTIFACT:t}" ]] ||
        fail "Checksum sidecar names an unexpected artifact: ${SIDECAR}"

    ACTUAL_HASH=$(shasum -a 256 "${ARTIFACT}" | awk '{print $1}')
    [[ "${ACTUAL_HASH:l}" == "${RECORDED_HASH:l}" ]] ||
        fail "SHA-256 mismatch: ${ARTIFACT}"
    VERIFIED_SHA256="${ACTUAL_HASH:l}"
}

for REQUIRED_COMMAND in \
    awk codesign dwarfdump git grep hdiutil jq lipo mktemp mount otool plutil \
    readlink sed shasum sips sort spctl tr unzip wc xcrun; do
    require_command "${REQUIRED_COMMAND}"
done

SEMVER_PATTERN='^(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)([.](0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?([+]([0-9A-Za-z-]+)([.][0-9A-Za-z-]+)*)?$'
if [[ -z "${VERIFY_VERSION}" || "${VERIFY_VERSION}" == *$'\n'* ]] || \
    ! print -r -- "${VERIFY_VERSION}" | grep -Eq "${SEMVER_PATTERN}"; then
    fail "UMIS_VERIFY_VERSION is not a valid Semantic Version: ${VERIFY_VERSION}"
fi

cd "${PROJECT_DIR}"

MANIFEST_OVERRIDE=${UMIS_VERIFY_MANIFEST:-}
if [[ -n "${MANIFEST_OVERRIDE}" ]]; then
    if [[ "${MANIFEST_OVERRIDE}" == /* ]]; then
        RELEASE_MANIFEST="${MANIFEST_OVERRIDE}"
    else
        RELEASE_MANIFEST="${PROJECT_DIR}/${MANIFEST_OVERRIDE}"
    fi
else
    typeset -a RELEASE_MANIFESTS
    RELEASE_MANIFESTS=(
        "${MANIFEST_DIR}"/release-"${VERIFY_VERSION}"-*.txt(N)
    )
    if [[ "${#RELEASE_MANIFESTS[@]}" != "1" ]]; then
        fail "Expected exactly one release manifest for ${VERIFY_VERSION}; found ${#RELEASE_MANIFESTS[@]}. Set UMIS_VERIFY_MANIFEST explicitly."
    fi
    RELEASE_MANIFEST="${RELEASE_MANIFESTS[1]}"
fi

[[ -f "${RELEASE_MANIFEST}" ]] ||
    fail "Release manifest is missing: ${RELEASE_MANIFEST}"
verify_sha256_sidecar "${RELEASE_MANIFEST}" "${RELEASE_MANIFEST}.sha256"

MANIFEST_BASENAME=${RELEASE_MANIFEST:t}
EXPECTED_MANIFEST_PREFIX="release-${VERIFY_VERSION}-"
if [[ "${MANIFEST_BASENAME}" != ${EXPECTED_MANIFEST_PREFIX}*.txt ]]; then
    fail "Release manifest filename does not match ${VERIFY_VERSION}: ${MANIFEST_BASENAME}"
fi
RELEASE_RUN=${MANIFEST_BASENAME#${EXPECTED_MANIFEST_PREFIX}}
RELEASE_RUN=${RELEASE_RUN%.txt}
[[ -n "${RELEASE_RUN}" ]] || fail "Release manifest has no run identifier."

NOTARY_SUBMISSION_PATH="${MANIFEST_DIR}/notary-submission-${VERIFY_VERSION}-${RELEASE_RUN}.json"
NOTARY_LOG_PATH="${MANIFEST_DIR}/notary-log-${VERIFY_VERSION}-${RELEASE_RUN}.json"
DMG_PATH="${OUTPUT_DIR}/RINKAN-UMIS-${VERIFY_VERSION}.dmg"

MANIFEST_VERSION=$(manifest_value version)
MANIFEST_TAG=$(manifest_value tag)
MANIFEST_COMMIT=$(manifest_value commit)
MANIFEST_TREE=$(manifest_value tree)
MANIFEST_TAG_OBJECT=$(manifest_value tag_object)
MANIFEST_BUNDLE_IDENTIFIER=$(manifest_value bundle_identifier)
MANIFEST_SHORT_VERSION=$(manifest_value bundle_short_version)
MANIFEST_BUILD_VERSION=$(manifest_value bundle_build_version)
MANIFEST_MINIMUM_SYSTEM_VERSION=$(manifest_value minimum_system_version)
MANIFEST_TEAM_IDENTIFIER=$(manifest_value team_identifier)
MANIFEST_DEVELOPER_ID_AUTHORITY=$(manifest_value developer_id_authority)
MANIFEST_ARCHITECTURES=$(manifest_value architectures)
MANIFEST_APP_UUIDS=$(manifest_value app_uuids)
MANIFEST_NOTARY_ID=$(manifest_value notary_submission)
MANIFEST_NOTARY_STATUS=$(manifest_value notary_status)
MANIFEST_NOTARY_SUBMISSION_SHA256=$(manifest_value notary_submission_sha256)
MANIFEST_NOTARY_LOG_SHA256=$(manifest_value notary_log_sha256)
MANIFEST_EXECUTABLE_SHA256=$(manifest_value app_executable_sha256)
MANIFEST_DMG_SHA256=$(manifest_value dmg_sha256)
MANIFEST_DSYM_SHA256=$(manifest_value dsym_sha256)

# 0.2.0-alpha.3 predates final-DMG icon, entitlement, and Code Directory
# evidence. It is the only release allowed to omit these fields. A duplicate
# key is never legacy evidence, and a partial new evidence set is always an
# error, including for alpha.3.
LEGACY_EVIDENCE_VERSION=0
if [[ "${VERIFY_VERSION}" == "0.2.0-alpha.3" ]]; then
    LEGACY_EVIDENCE_VERSION=1
fi

ICON_KEY_COUNT=$(manifest_key_count app_icon_sha256)
ICON_EVIDENCE_AVAILABLE=0
if [[ "${ICON_KEY_COUNT}" == "1" ]]; then
    MANIFEST_ICON_SHA256=$(manifest_value app_icon_sha256)
    [[ "${MANIFEST_ICON_SHA256}" =~ '^[0-9a-fA-F]{64}$' ]] ||
        fail "Manifest app_icon_sha256 is malformed."
    ICON_EVIDENCE_AVAILABLE=1
elif [[ "${ICON_KEY_COUNT}" == "0" && "${LEGACY_EVIDENCE_VERSION}" == "1" ]]; then
    print -- "SKIP: icon hash binding (legacy 0.2.0-alpha.3 manifest)."
else
    fail "app_icon_sha256 must occur exactly once; only 0.2.0-alpha.3 may omit it."
fi

VALIDATION_SOURCE_KEY_COUNT=$(manifest_key_count app_validation_source)
ENTITLEMENTS_KEY_COUNT=$(manifest_key_count app_entitlements_sha256)
CODE_DIRECTORY_KEY_COUNT=$(manifest_key_count app_code_directory_hashes)
FINAL_APP_EVIDENCE_AVAILABLE=0
if [[ "${VALIDATION_SOURCE_KEY_COUNT}" == "1" && \
    "${ENTITLEMENTS_KEY_COUNT}" == "1" && \
    "${CODE_DIRECTORY_KEY_COUNT}" == "1" ]]; then
    MANIFEST_APP_VALIDATION_SOURCE=$(manifest_value app_validation_source)
    MANIFEST_ENTITLEMENTS_SHA256=$(manifest_value app_entitlements_sha256)
    MANIFEST_CODE_DIRECTORY_HASHES=$(manifest_value app_code_directory_hashes)
    [[ "${MANIFEST_APP_VALIDATION_SOURCE}" == "stapled_dmg" ]] ||
        fail "app_validation_source must be stapled_dmg."
    [[ "${MANIFEST_ENTITLEMENTS_SHA256}" =~ '^[0-9a-fA-F]{64}$' ]] ||
        fail "Manifest app_entitlements_sha256 is malformed."
    if ! print -r -- "${MANIFEST_CODE_DIRECTORY_HASHES}" |
        grep -Eq '^((arm64|x86_64):[0-9A-Fa-f]{40};){2}$'; then
        fail "Manifest app_code_directory_hashes is malformed."
    fi
    for EVIDENCE_ARCHITECTURE in arm64 x86_64; do
        EVIDENCE_ARCHITECTURE_COUNT=$(
            print -r -- "${MANIFEST_CODE_DIRECTORY_HASHES}" |
                tr ';' '\n' |
                awk -F: -v architecture="${EVIDENCE_ARCHITECTURE}" \
                    '$1 == architecture {count += 1} END {print count + 0}'
        )
        [[ "${EVIDENCE_ARCHITECTURE_COUNT}" == "1" ]] ||
            fail "Manifest must contain exactly one Code Directory hash for ${EVIDENCE_ARCHITECTURE}."
    done
    MANIFEST_ARM64_CODE_DIRECTORY_HASH=$(
        print -r -- "${MANIFEST_CODE_DIRECTORY_HASHES}" |
            tr ';' '\n' |
            awk -F: '$1 == "arm64" {print tolower($2)}'
    )
    MANIFEST_X86_64_CODE_DIRECTORY_HASH=$(
        print -r -- "${MANIFEST_CODE_DIRECTORY_HASHES}" |
            tr ';' '\n' |
            awk -F: '$1 == "x86_64" {print tolower($2)}'
    )
    FINAL_APP_EVIDENCE_AVAILABLE=1
elif [[ "${VALIDATION_SOURCE_KEY_COUNT}" == "0" && \
    "${ENTITLEMENTS_KEY_COUNT}" == "0" && \
    "${CODE_DIRECTORY_KEY_COUNT}" == "0" && \
    "${LEGACY_EVIDENCE_VERSION}" == "1" ]]; then
    print -- "SKIP: final-DMG entitlement/CDHash binding (legacy 0.2.0-alpha.3 manifest)."
else
    fail "app_validation_source, app_entitlements_sha256, and app_code_directory_hashes must each occur exactly once; only 0.2.0-alpha.3 may omit all three."
fi

[[ "${MANIFEST_VERSION}" == "${VERIFY_VERSION}" ]] ||
    fail "Manifest version does not match requested version."
[[ "${MANIFEST_TAG}" == "v${VERIFY_VERSION}" ]] ||
    fail "Manifest tag does not match requested version."
[[ "${MANIFEST_COMMIT}" =~ '^[0-9a-f]{40}$' ]] ||
    fail "Manifest commit is not a full Git object ID."
[[ "${MANIFEST_TREE}" =~ '^[0-9a-f]{40}$' ]] ||
    fail "Manifest tree is not a full Git object ID."
[[ "${MANIFEST_TAG_OBJECT}" =~ '^[0-9a-f]{40}$' ]] ||
    fail "Manifest tag object is not a full Git object ID."
[[ "${MANIFEST_BUNDLE_IDENTIFIER}" == "jp.rinkan.umis" ]] ||
    fail "Unexpected bundle identifier: ${MANIFEST_BUNDLE_IDENTIFIER}"
[[ "${MANIFEST_SHORT_VERSION}" == "${VERIFY_VERSION%%[-+]*}" ]] ||
    fail "Bundle marketing version does not match the release version."
[[ "${MANIFEST_BUILD_VERSION}" =~ '^[0-9]+([.][0-9]+){0,2}$' ]] ||
    fail "Manifest build version is invalid."
[[ "${MANIFEST_MINIMUM_SYSTEM_VERSION}" == "13.0" ]] ||
    fail "Unexpected minimum macOS version: ${MANIFEST_MINIMUM_SYSTEM_VERSION}"
[[ "${MANIFEST_TEAM_IDENTIFIER}" == "${EXPECTED_TEAM_IDENTIFIER}" ]] ||
    fail "Unexpected Developer Team: ${MANIFEST_TEAM_IDENTIFIER}"
[[ "${MANIFEST_DEVELOPER_ID_AUTHORITY}" == 'Developer ID Application: '* ]] ||
    fail "Manifest does not identify a Developer ID Application authority."
[[ "${MANIFEST_NOTARY_STATUS}" == "Accepted" ]] ||
    fail "Manifest notarization status is not Accepted."
[[ "${MANIFEST_NOTARY_ID}" =~ '^[0-9a-fA-F-]{36}$' ]] ||
    fail "Manifest notarization submission ID is malformed."

# Validate the immutable release source. HEAD and the current branch may have
# moved since an older release, so they are deliberately not used as identity.
[[ "$(git cat-file -t "${MANIFEST_COMMIT}")" == "commit" ]] ||
    fail "Release commit object is unavailable locally."
[[ "$(git rev-parse "${MANIFEST_COMMIT}^{tree}")" == "${MANIFEST_TREE}" ]] ||
    fail "Release commit tree differs from the manifest."
[[ "$(git cat-file -t "refs/tags/${MANIFEST_TAG}")" == "tag" ]] ||
    fail "Release tag is not an annotated or signed tag."
[[ "$(git rev-parse "refs/tags/${MANIFEST_TAG}")" == "${MANIFEST_TAG_OBJECT}" ]] ||
    fail "Local release tag object differs from the manifest."
[[ "$(git rev-parse "${MANIFEST_TAG}^{}")" == "${MANIFEST_COMMIT}" ]] ||
    fail "Local release tag does not peel to the release commit."
TAG_VERSION=$(git show "${MANIFEST_COMMIT}:VERSION")
[[ "${TAG_VERSION}" == "${VERIFY_VERSION}" ]] ||
    fail "VERSION in the release commit differs from the manifest."

if [[ "${FINAL_APP_EVIDENCE_AVAILABLE}" == "1" ]]; then
    TAGGED_SOURCE_ENTITLEMENTS=$(
        git show "${MANIFEST_COMMIT}:Resources/RinkanUMIS.entitlements"
    )
    print -r -- "${TAGGED_SOURCE_ENTITLEMENTS}" | plutil -lint - >/dev/null ||
        fail "Tagged release source entitlements are malformed."
    TAGGED_CANONICAL_ENTITLEMENTS=$(
        print -r -- "${TAGGED_SOURCE_ENTITLEMENTS}" |
            plutil -convert xml1 -o - -
    )
    TAGGED_ENTITLEMENTS_SHA256=$(
        print -rn -- "${TAGGED_CANONICAL_ENTITLEMENTS}" |
            shasum -a 256 | awk '{print $1}'
    )
    [[ "${TAGGED_ENTITLEMENTS_SHA256}" == "${MANIFEST_ENTITLEMENTS_SHA256:l}" ]] ||
        fail "Tagged source entitlements SHA-256 differs from the manifest."
fi

# ls-remote reads GitHub state without changing local refs.
REMOTE_TAG_LIST=$(
    git ls-remote origin \
        "refs/tags/${MANIFEST_TAG}" \
        "refs/tags/${MANIFEST_TAG}^{}"
)
REMOTE_TAG_OBJECT=$(
    print -r -- "${REMOTE_TAG_LIST}" |
        awk -v ref="refs/tags/${MANIFEST_TAG}" '$2 == ref {print $1}'
)
REMOTE_TAG_COMMIT=$(
    print -r -- "${REMOTE_TAG_LIST}" |
        awk -v ref="refs/tags/${MANIFEST_TAG}^{}" '$2 == ref {print $1}'
)
[[ "${REMOTE_TAG_OBJECT}" == "${MANIFEST_TAG_OBJECT}" ]] ||
    fail "Remote annotated tag object differs from the manifest."
[[ "${REMOTE_TAG_COMMIT}" == "${MANIFEST_COMMIT}" ]] ||
    fail "Remote release tag does not peel to the release commit."

# The manifest and checksum sidecar record the final, stapled DMG. Apple's
# notary log records the pre-staple upload and must not be compared to this hash.
verify_sha256_sidecar "${DMG_PATH}" "${DMG_PATH}.sha256"
ACTUAL_DMG_SHA256=${VERIFIED_SHA256}
[[ "${ACTUAL_DMG_SHA256}" == "${MANIFEST_DMG_SHA256:l}" ]] ||
    fail "Final DMG SHA-256 differs from the release manifest."

[[ -f "${NOTARY_SUBMISSION_PATH}" ]] ||
    fail "Notary submission JSON is missing: ${NOTARY_SUBMISSION_PATH}"
[[ -f "${NOTARY_LOG_PATH}" ]] ||
    fail "Notary detail log is missing: ${NOTARY_LOG_PATH}"
ACTUAL_NOTARY_SUBMISSION_SHA256=$(
    shasum -a 256 "${NOTARY_SUBMISSION_PATH}" | awk '{print $1}'
)
ACTUAL_NOTARY_LOG_SHA256=$(
    shasum -a 256 "${NOTARY_LOG_PATH}" | awk '{print $1}'
)
[[ "${ACTUAL_NOTARY_SUBMISSION_SHA256}" == "${MANIFEST_NOTARY_SUBMISSION_SHA256:l}" ]] ||
    fail "Notary submission JSON SHA-256 differs from the manifest."
[[ "${ACTUAL_NOTARY_LOG_SHA256}" == "${MANIFEST_NOTARY_LOG_SHA256:l}" ]] ||
    fail "Notary detail log SHA-256 differs from the manifest."

jq -e --arg id "${MANIFEST_NOTARY_ID}" '
    .id == $id and .status == "Accepted"
' "${NOTARY_SUBMISSION_PATH}" >/dev/null ||
    fail "Notary submission JSON is not Accepted or has the wrong ID."

jq -e \
    --arg id "${MANIFEST_NOTARY_ID}" \
    --arg archive "${DMG_PATH:t}" '
        .jobId == $id and
        .status == "Accepted" and
        .statusCode == 0 and
        (.issues == null or .issues == []) and
        .archiveFilename == $archive and
        (.sha256 | type == "string" and test("^[0-9a-fA-F]{64}$")) and
        (.ticketContents | type == "array" and length > 0) and
        (
            [
                .ticketContents[]
                | select(.path == ($archive + "/RINKAN UMIS.app"))
                | .arch
            ] | sort
        ) == ["arm64", "x86_64"] and
        (
            [
                .ticketContents[]
                | select(.path == ($archive + "/RINKAN UMIS.app/Contents/MacOS/RinkanUMIS"))
                | .arch
            ] | sort
        ) == ["arm64", "x86_64"] and
        any(.ticketContents[]; .path == $archive) and
        all(.ticketContents[]; .digestAlgorithm == "SHA-256") and
        (
            [
                ..
                | objects
                | .severity? // empty
                | ascii_downcase
                | select(. == "warning" or . == "error")
            ] | length == 0
        )
    ' "${NOTARY_LOG_PATH}" >/dev/null ||
    fail "Notary detail log is inconsistent or contains a warning/error."

if [[ -n "${NOTARY_PROFILE}" ]]; then
    LIVE_NOTARY_INFO=$(
        xcrun notarytool info \
            "${MANIFEST_NOTARY_ID}" \
            --keychain-profile "${NOTARY_PROFILE}" \
            --output-format json
    )
    print -r -- "${LIVE_NOTARY_INFO}" |
        jq -e \
            --arg id "${MANIFEST_NOTARY_ID}" \
            --arg name "${DMG_PATH:t}" \
            '.id == $id and .name == $name and .status == "Accepted"' >/dev/null ||
        fail "Apple Notary Service does not report this submission as Accepted."
    print -- "OK: Apple Notary Service live status is Accepted."
else
    print -- "SKIP: Apple Notary Service live status (set UMIS_VERIFY_PROFILE to enable)."
fi

hdiutil verify "${DMG_PATH}"
codesign --verify --strict --verbose=2 "${DMG_PATH}"
DMG_SIGNATURE_DETAILS=$(codesign -d --verbose=4 "${DMG_PATH}" 2>&1)
print -r -- "${DMG_SIGNATURE_DETAILS}" |
    grep -Fqx "Authority=${MANIFEST_DEVELOPER_ID_AUTHORITY}" ||
    fail "DMG Developer ID authority differs from the manifest."
print -r -- "${DMG_SIGNATURE_DETAILS}" |
    grep -Fqx "TeamIdentifier=${MANIFEST_TEAM_IDENTIFIER}" ||
    fail "DMG Team ID differs from the manifest."
print -r -- "${DMG_SIGNATURE_DETAILS}" | grep -q '^Timestamp=' ||
    fail "DMG secure timestamp is missing."
print -r -- "${DMG_SIGNATURE_DETAILS}" | grep -Fqx 'Notarization Ticket=stapled' ||
    fail "DMG signature metadata does not report a stapled ticket."
xcrun stapler validate "${DMG_PATH}"
spctl --assess \
    --type open \
    --context context:primary-signature \
    --verbose=2 \
    "${DMG_PATH}"

SHORT_COMMIT=${MANIFEST_COMMIT[1,12]}
DSYM_ARCHIVE="${OUTPUT_DIR}/symbols/RINKAN-UMIS-${VERIFY_VERSION}-${SHORT_COMMIT}.dSYM.zip"
verify_sha256_sidecar "${DSYM_ARCHIVE}" "${DSYM_ARCHIVE}.sha256"
ACTUAL_DSYM_SHA256=${VERIFIED_SHA256}
[[ "${ACTUAL_DSYM_SHA256}" == "${MANIFEST_DSYM_SHA256:l}" ]] ||
    fail "dSYM archive SHA-256 differs from the release manifest."
unzip -tq "${DSYM_ARCHIVE}"

# The only temporary state is an empty mount point. The image is attached
# read-only, and cleanup detaches only device nodes returned by this attach.
VERIFY_TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/umis-release-verification.XXXXXX")
MOUNT_POINT="${VERIFY_TEMP_ROOT}/mount"
mkdir "${MOUNT_POINT}"
CANONICAL_MOUNT_POINT=$(cd "${MOUNT_POINT}" && pwd -P)
typeset -a ATTACHED_DEVICES
ATTACHED_DEVICES=()

cleanup_mount() {
    local VERIFY_STATUS=$?
    local DEVICE
    local RECOVERED_DEVICE_LINES
    trap - EXIT HUP INT TERM
    # If parsing the attach response failed after a successful attach, recover
    # only device nodes whose mount point is this unique mktemp directory.
    if [[ "${#ATTACHED_DEVICES[@]}" == "0" ]]; then
        RECOVERED_DEVICE_LINES=$(
            hdiutil info -plist 2>/dev/null |
                plutil -convert json -o - - 2>/dev/null |
                jq -r --arg mount "${CANONICAL_MOUNT_POINT}" '
                    .images[]?
                    | .["system-entities"][]?
                    | select(.["mount-point"]? == $mount)
                    | .["dev-entry"]
                ' 2>/dev/null || true
        )
        if [[ -n "${RECOVERED_DEVICE_LINES}" ]]; then
            ATTACHED_DEVICES=("${(@f)RECOVERED_DEVICE_LINES}")
        fi
    fi
    for DEVICE in "${ATTACHED_DEVICES[@]}"; do
        if [[ -n "${DEVICE}" ]] && ! hdiutil detach "${DEVICE}" >/dev/null 2>&1; then
            print -u2 -- "Could not detach verification device: ${DEVICE}"
            VERIFY_STATUS=1
        fi
    done
    rmdir "${MOUNT_POINT}" 2>/dev/null || true
    rmdir "${VERIFY_TEMP_ROOT}" 2>/dev/null || true
    exit "${VERIFY_STATUS}"
}
trap cleanup_mount EXIT HUP INT TERM

ATTACH_PLIST=$(
    hdiutil attach "${DMG_PATH}" \
        -readonly \
        -nobrowse \
        -noautoopen \
        -mountpoint "${MOUNT_POINT}" \
        -plist
)
ATTACHED_DEVICES=(
    "${(@f)$(
        print -r -- "${ATTACH_PLIST}" |
            plutil -convert json -o - - |
            jq -r '
                .["system-entities"][]
                | select(.["mount-point"]? != null)
                | .["dev-entry"]
            '
    )}"
)
[[ "${#ATTACHED_DEVICES[@]}" == "1" && -n "${ATTACHED_DEVICES[1]}" ]] ||
    fail "Expected exactly one mounted filesystem in the release DMG."
MOUNT_DEVICE=${ATTACHED_DEVICES[1]}
mount | grep -F "${MOUNT_DEVICE} on " | grep -q 'read-only' ||
    fail "Release DMG filesystem is not mounted read-only."

APP_PATH="${MOUNT_POINT}/RINKAN UMIS.app"
APP_EXECUTABLE_PATH="${APP_PATH}/Contents/MacOS/RinkanUMIS"
APP_INFO_PATH="${APP_PATH}/Contents/Info.plist"
APP_CONTENTS_PATH="${APP_PATH}/Contents"
APP_MACOS_PATH="${APP_CONTENTS_PATH}/MacOS"
APP_RESOURCES_PATH="${APP_CONTENTS_PATH}/Resources"
[[ -d "${APP_PATH}" && ! -L "${APP_PATH}" && \
    -d "${APP_CONTENTS_PATH}" && ! -L "${APP_CONTENTS_PATH}" && \
    -d "${APP_MACOS_PATH}" && ! -L "${APP_MACOS_PATH}" && \
    -d "${APP_RESOURCES_PATH}" && ! -L "${APP_RESOURCES_PATH}" ]] ||
    fail "The DMG does not contain the expected regular application directories."
[[ -f "${APP_EXECUTABLE_PATH}" && -x "${APP_EXECUTABLE_PATH}" && \
    ! -L "${APP_EXECUTABLE_PATH}" ]] ||
    fail "App executable is missing, non-regular, or a symlink."
[[ -f "${APP_INFO_PATH}" && ! -L "${APP_INFO_PATH}" ]] ||
    fail "App Info.plist is missing, non-regular, or a symlink."
plutil -lint "${APP_INFO_PATH}" >/dev/null || fail "App Info.plist is malformed."
[[ -L "${MOUNT_POINT}/Applications" ]] || fail "Applications symlink is missing."
[[ "$(readlink "${MOUNT_POINT}/Applications")" == "/Applications" ]] ||
    fail "Applications symlink has an unexpected target."

codesign --verify --all-architectures --deep --strict --verbose=2 "${APP_PATH}"
spctl --assess --type execute --verbose=2 "${APP_PATH}"

ACTUAL_ARCHITECTURES=$(lipo -archs "${APP_EXECUTABLE_PATH}")
ACTUAL_ARCHITECTURE_COUNT=$(print -r -- "${ACTUAL_ARCHITECTURES}" | awk '{print NF}')
[[ "${ACTUAL_ARCHITECTURE_COUNT}" == "2" && \
    " ${ACTUAL_ARCHITECTURES} " == *" arm64 "* && \
    " ${ACTUAL_ARCHITECTURES} " == *" x86_64 "* ]] ||
    fail "The application is not exactly arm64 + x86_64 Universal 2."
SORTED_ACTUAL_ARCHITECTURES=$(
    print -r -- "${ACTUAL_ARCHITECTURES}" |
        tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort
)
SORTED_MANIFEST_ARCHITECTURES=$(
    print -r -- "${MANIFEST_ARCHITECTURES}" |
        tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort
)
[[ "${SORTED_ACTUAL_ARCHITECTURES}" == "${SORTED_MANIFEST_ARCHITECTURES}" ]] ||
    fail "Application architectures differ from the release manifest."

APP_BUNDLE_IDENTIFIER=$(plutil -extract CFBundleIdentifier raw -o - "${APP_INFO_PATH}")
APP_SHORT_VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "${APP_INFO_PATH}")
APP_BUILD_VERSION=$(plutil -extract CFBundleVersion raw -o - "${APP_INFO_PATH}")
APP_MINIMUM_SYSTEM_VERSION=$(plutil -extract LSMinimumSystemVersion raw -o - "${APP_INFO_PATH}")
APP_EXECUTABLE_NAME=$(plutil -extract CFBundleExecutable raw -o - "${APP_INFO_PATH}")
[[ "${APP_BUNDLE_IDENTIFIER}" == "${MANIFEST_BUNDLE_IDENTIFIER}" ]] ||
    fail "App bundle identifier differs from the manifest."
[[ "${APP_SHORT_VERSION}" == "${MANIFEST_SHORT_VERSION}" ]] ||
    fail "App marketing version differs from the manifest."
[[ "${APP_BUILD_VERSION}" == "${MANIFEST_BUILD_VERSION}" ]] ||
    fail "App build version differs from the manifest."
[[ "${APP_MINIMUM_SYSTEM_VERSION}" == "${MANIFEST_MINIMUM_SYSTEM_VERSION}" ]] ||
    fail "App minimum macOS version differs from the manifest."
[[ "${APP_EXECUTABLE_NAME}" == "RinkanUMIS" ]] ||
    fail "App executable name is unexpected."

FIRST_EMBEDDED_ENTITLEMENTS_SHA256=""
for ARCHITECTURE in arm64 x86_64; do
    SIGNATURE_DETAILS=$(codesign -d --arch "${ARCHITECTURE}" --verbose=4 "${APP_PATH}" 2>&1)
    SLICE_AUTHORITY=$(
        print -r -- "${SIGNATURE_DETAILS}" |
            sed -n 's/^Authority=\(Developer ID Application:.*\)$/\1/p' |
            head -n 1
    )
    SLICE_TEAM_IDENTIFIER=$(
        print -r -- "${SIGNATURE_DETAILS}" |
            sed -n 's/^TeamIdentifier=//p' |
            head -n 1
    )
    SLICE_IDENTIFIER=$(
        print -r -- "${SIGNATURE_DETAILS}" |
            sed -n 's/^Identifier=//p' |
            head -n 1
    )
    SLICE_CODE_DIRECTORY_HASH=$(
        print -r -- "${SIGNATURE_DETAILS}" |
            sed -n 's/^CDHash=//p' |
            head -n 1
    )
    [[ "${SLICE_AUTHORITY}" == "${MANIFEST_DEVELOPER_ID_AUTHORITY}" ]] ||
        fail "${ARCHITECTURE} Developer ID authority differs from the manifest."
    [[ "${SLICE_TEAM_IDENTIFIER}" == "${MANIFEST_TEAM_IDENTIFIER}" ]] ||
        fail "${ARCHITECTURE} Team ID differs from the manifest."
    [[ "${SLICE_IDENTIFIER}" == "${MANIFEST_BUNDLE_IDENTIFIER}" ]] ||
        fail "${ARCHITECTURE} signed identifier differs from Info.plist."
    print -r -- "${SIGNATURE_DETAILS}" |
        grep -Eq 'flags=0x[0-9A-Fa-f]+\([^)]*runtime' ||
        fail "${ARCHITECTURE} Hardened Runtime flag is missing."
    print -r -- "${SIGNATURE_DETAILS}" | grep -q '^Timestamp=' ||
        fail "${ARCHITECTURE} secure timestamp is missing."

    if [[ "${FINAL_APP_EVIDENCE_AVAILABLE}" == "1" ]]; then
        [[ "${SLICE_CODE_DIRECTORY_HASH}" =~ '^[0-9a-fA-F]{40}$' ]] ||
            fail "${ARCHITECTURE} Code Directory hash is malformed."
        if [[ "${ARCHITECTURE}" == "arm64" ]]; then
            EXPECTED_CODE_DIRECTORY_HASH=${MANIFEST_ARM64_CODE_DIRECTORY_HASH}
        else
            EXPECTED_CODE_DIRECTORY_HASH=${MANIFEST_X86_64_CODE_DIRECTORY_HASH}
        fi
        [[ "${SLICE_CODE_DIRECTORY_HASH:l}" == "${EXPECTED_CODE_DIRECTORY_HASH}" ]] ||
            fail "${ARCHITECTURE} Code Directory hash differs from the manifest."
    fi

    EMBEDDED_ENTITLEMENTS=$(
        codesign -d --arch "${ARCHITECTURE}" --entitlements :- "${APP_PATH}" 2>/dev/null
    )
    print -r -- "${EMBEDDED_ENTITLEMENTS}" | plutil -lint - >/dev/null ||
        fail "${ARCHITECTURE} embedded entitlements are malformed."
    if [[ "${FINAL_APP_EVIDENCE_AVAILABLE}" == "1" ]]; then
        CANONICAL_EMBEDDED_ENTITLEMENTS=$(
            print -r -- "${EMBEDDED_ENTITLEMENTS}" |
                plutil -convert xml1 -o - -
        )
        EMBEDDED_ENTITLEMENTS_SHA256=$(
            print -rn -- "${CANONICAL_EMBEDDED_ENTITLEMENTS}" |
                shasum -a 256 | awk '{print $1}'
        )
        [[ "${EMBEDDED_ENTITLEMENTS_SHA256}" == "${MANIFEST_ENTITLEMENTS_SHA256:l}" ]] ||
            fail "${ARCHITECTURE} canonical entitlements SHA-256 differs from the manifest."
        [[ "${EMBEDDED_ENTITLEMENTS_SHA256}" == "${TAGGED_ENTITLEMENTS_SHA256}" ]] ||
            fail "${ARCHITECTURE} entitlements differ from the tagged release source."
        if [[ -z "${FIRST_EMBEDDED_ENTITLEMENTS_SHA256}" ]]; then
            FIRST_EMBEDDED_ENTITLEMENTS_SHA256=${EMBEDDED_ENTITLEMENTS_SHA256}
        else
            [[ "${EMBEDDED_ENTITLEMENTS_SHA256}" == \
                "${FIRST_EMBEDDED_ENTITLEMENTS_SHA256}" ]] ||
                fail "Universal 2 slices do not carry identical entitlements."
        fi
    fi
    GET_TASK_ALLOW=$(
        print -r -- "${EMBEDDED_ENTITLEMENTS}" |
            plutil -extract com.apple.security.get-task-allow raw -o - - 2>/dev/null || true
    )
    [[ "${GET_TASK_ALLOW}" != "true" ]] ||
        fail "${ARCHITECTURE} enables com.apple.security.get-task-allow."
    for DANGEROUS_ENTITLEMENT in \
        com.apple.security.cs.allow-jit \
        com.apple.security.cs.allow-unsigned-executable-memory \
        com.apple.security.cs.disable-executable-page-protection \
        com.apple.security.cs.disable-library-validation; do
        DANGEROUS_VALUE=$(
            print -r -- "${EMBEDDED_ENTITLEMENTS}" |
                plutil -extract "${DANGEROUS_ENTITLEMENT}" raw -o - - 2>/dev/null || true
        )
        [[ "${DANGEROUS_VALUE}" != "true" ]] ||
            fail "${ARCHITECTURE} enables prohibited entitlement ${DANGEROUS_ENTITLEMENT}."
    done

    MACH_O_MINIMUM_VERSION=$(
        otool -arch "${ARCHITECTURE}" -l "${APP_EXECUTABLE_PATH}" |
            awk '
                $1 == "cmd" && $2 == "LC_BUILD_VERSION" { modern = 1 }
                modern && $1 == "minos" && !found { version = $2; found = 1 }
                $1 == "cmd" && $2 == "LC_VERSION_MIN_MACOSX" { legacy = 1 }
                legacy && $1 == "version" && !found { version = $2; found = 1 }
                END { if (found) print version }
            '
    )
    [[ "${MACH_O_MINIMUM_VERSION}" == "${MANIFEST_MINIMUM_SYSTEM_VERSION}" ]] ||
        fail "${ARCHITECTURE} Mach-O deployment target differs from the manifest."
done

ACTUAL_EXECUTABLE_SHA256=$(
    shasum -a 256 "${APP_EXECUTABLE_PATH}" | awk '{print $1}'
)
[[ "${ACTUAL_EXECUTABLE_SHA256}" == "${MANIFEST_EXECUTABLE_SHA256:l}" ]] ||
    fail "App executable SHA-256 differs from the manifest."

# Icon evidence was added after 0.2.0-alpha.3. Every other version must bind
# the app icon to both the manifest and the icon blob in the tagged commit.
if [[ "${ICON_EVIDENCE_AVAILABLE}" == "1" ]]; then
    APP_ICON_FILE=$(plutil -extract CFBundleIconFile raw -o - "${APP_INFO_PATH}")
    [[ "${APP_ICON_FILE}" == "RinkanUMIS.icns" ]] ||
        fail "App icon filename is unexpected."
    APP_ICON_PATH="${APP_PATH}/Contents/Resources/${APP_ICON_FILE}"
    [[ -f "${APP_ICON_PATH}" && -s "${APP_ICON_PATH}" && ! -L "${APP_ICON_PATH}" ]] ||
        fail "App icon is missing, non-regular, or a symlink."
    ACTUAL_ICON_SHA256=$(shasum -a 256 "${APP_ICON_PATH}" | awk '{print $1}')
    TAGGED_ICON_SHA256=$(
        git show "${MANIFEST_COMMIT}:Resources/RinkanUMIS.icns" |
            shasum -a 256 | awk '{print $1}'
    )
    [[ "${ACTUAL_ICON_SHA256}" == "${MANIFEST_ICON_SHA256:l}" ]] ||
        fail "App icon SHA-256 differs from the manifest."
    [[ "${ACTUAL_ICON_SHA256}" == "${TAGGED_ICON_SHA256}" ]] ||
        fail "App icon differs from the icon in the tagged release commit."
fi

APP_UUIDS=$(
    dwarfdump --uuid "${APP_EXECUTABLE_PATH}" |
        awk '{print $2, $3}' | LC_ALL=C sort
)
DSYM_UUIDS=$(
    unzip -p \
        "${DSYM_ARCHIVE}" \
        'RinkanUMIS.dSYM/Contents/Resources/DWARF/RinkanUMIS' |
        dwarfdump --uuid - |
        awk '{print $2, $3}' | LC_ALL=C sort
)
RECORDED_APP_UUIDS=$(
    print -r -- "${MANIFEST_APP_UUIDS}" |
        tr ';' '\n' | sed '/^[[:space:]]*$/d' | LC_ALL=C sort
)
APP_UUID_COUNT=$(print -r -- "${APP_UUIDS}" | sed '/^$/d' | wc -l | tr -d ' ')
[[ "${APP_UUID_COUNT}" == "2" && \
    "${APP_UUIDS}" == *'(arm64)'* && \
    "${APP_UUIDS}" == *'(x86_64)'* ]] ||
    fail "App does not contain exactly one UUID for each Universal 2 slice."
[[ "${APP_UUIDS}" == "${DSYM_UUIDS}" ]] ||
    fail "dSYM UUIDs do not match the application executable."
[[ "${APP_UUIDS}" == "${RECORDED_APP_UUIDS}" ]] ||
    fail "Application UUIDs differ from the release manifest."

for MOUNT_DEVICE in "${ATTACHED_DEVICES[@]}"; do
    hdiutil detach "${MOUNT_DEVICE}"
done
ATTACHED_DEVICES=()
rmdir "${MOUNT_POINT}"
rmdir "${VERIFY_TEMP_ROOT}"
trap - EXIT HUP INT TERM

print -- "Release verification passed."
print -- "  version: ${VERIFY_VERSION}"
print -- "  commit: ${MANIFEST_COMMIT}"
print -- "  tag object: ${MANIFEST_TAG_OBJECT}"
print -- "  notarization: ${MANIFEST_NOTARY_ID} (${MANIFEST_NOTARY_STATUS})"
print -- "  DMG SHA-256: ${ACTUAL_DMG_SHA256}"
print -- "  architectures: ${ACTUAL_ARCHITECTURES}"
print -- "  Team ID: ${MANIFEST_TEAM_IDENTIFIER}"
