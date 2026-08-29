#!/bin/zsh
set -euo pipefail

MANIFEST_PATH=${1:-}

fail() {
    print -u2 -- "Privacy manifest validation failed: $*"
    exit 1
}

[[ -n "${MANIFEST_PATH}" ]] || fail "Pass the PrivacyInfo.xcprivacy path as the only argument."
[[ "$#" == "1" ]] || fail "Exactly one manifest path is required."
[[ -f "${MANIFEST_PATH}" && ! -L "${MANIFEST_PATH}" ]] ||
    fail "The manifest is missing, non-regular, or a symlink: ${MANIFEST_PATH}"
plutil -lint "${MANIFEST_PATH}" >/dev/null || fail "The property list is malformed."

TRACKING=$(
    plutil -extract NSPrivacyTracking raw -expect bool -o - "${MANIFEST_PATH}" 2>/dev/null || true
)
[[ "${TRACKING}" == "false" ]] || fail "NSPrivacyTracking must be false."

COLLECTED_DATA_TYPE_COUNT=$(
    plutil -extract NSPrivacyCollectedDataTypes raw -expect array \
        -o - "${MANIFEST_PATH}" 2>/dev/null || true
)
[[ "${COLLECTED_DATA_TYPE_COUNT}" == "0" ]] ||
    fail "NSPrivacyCollectedDataTypes must be an empty array for the reviewed release."
ACCESSED_API_TYPE_COUNT=$(
    plutil -extract NSPrivacyAccessedAPITypes raw -expect array \
        -o - "${MANIFEST_PATH}" 2>/dev/null || true
)
[[ "${ACCESSED_API_TYPE_COUNT}" == "2" ]] ||
    fail "The manifest must contain exactly the two reviewed required-reason API categories."

DISK_CATEGORY=$(
    /usr/libexec/PlistBuddy \
        -c "Print :NSPrivacyAccessedAPITypes:0:NSPrivacyAccessedAPIType" \
        "${MANIFEST_PATH}" 2>/dev/null || true
)
DISK_REASON=$(
    /usr/libexec/PlistBuddy \
        -c "Print :NSPrivacyAccessedAPITypes:0:NSPrivacyAccessedAPITypeReasons:0" \
        "${MANIFEST_PATH}" 2>/dev/null || true
)
[[ "${DISK_CATEGORY}" == "NSPrivacyAccessedAPICategoryDiskSpace" && \
    "${DISK_REASON}" == "E174.1" ]] ||
    fail "The reviewed disk-space declaration (E174.1) is missing."
DISK_REASON_COUNT=$(
    plutil -extract NSPrivacyAccessedAPITypes.0.NSPrivacyAccessedAPITypeReasons raw \
        -expect array -o - "${MANIFEST_PATH}" 2>/dev/null || true
)
[[ "${DISK_REASON_COUNT}" == "1" ]] ||
    fail "The disk-space declaration must contain exactly one reviewed reason."

TIMESTAMP_CATEGORY=$(
    /usr/libexec/PlistBuddy \
        -c "Print :NSPrivacyAccessedAPITypes:1:NSPrivacyAccessedAPIType" \
        "${MANIFEST_PATH}" 2>/dev/null || true
)
TIMESTAMP_INTERNAL_REASON=$(
    /usr/libexec/PlistBuddy \
        -c "Print :NSPrivacyAccessedAPITypes:1:NSPrivacyAccessedAPITypeReasons:0" \
        "${MANIFEST_PATH}" 2>/dev/null || true
)
TIMESTAMP_USER_SELECTED_REASON=$(
    /usr/libexec/PlistBuddy \
        -c "Print :NSPrivacyAccessedAPITypes:1:NSPrivacyAccessedAPITypeReasons:1" \
        "${MANIFEST_PATH}" 2>/dev/null || true
)
[[ "${TIMESTAMP_CATEGORY}" == "NSPrivacyAccessedAPICategoryFileTimestamp" && \
    "${TIMESTAMP_INTERNAL_REASON}" == "C617.1" && \
    "${TIMESTAMP_USER_SELECTED_REASON}" == "3B52.1" ]] ||
    fail "The reviewed file-timestamp declarations (C617.1 and 3B52.1) are missing."
TIMESTAMP_REASON_COUNT=$(
    plutil -extract NSPrivacyAccessedAPITypes.1.NSPrivacyAccessedAPITypeReasons raw \
        -expect array -o - "${MANIFEST_PATH}" 2>/dev/null || true
)
[[ "${TIMESTAMP_REASON_COUNT}" == "2" ]] ||
    fail "The file-timestamp declaration must contain exactly two reviewed reasons."

print -- "Privacy manifest validation passed: ${MANIFEST_PATH}"
