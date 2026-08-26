#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
CONFIGURATION=${UMIS_CONFIGURATION:-release}
OUTPUT_DIR=${UMIS_OUTPUT_DIR:-${PROJECT_DIR}/dist}
APP_NAME="RINKAN UMIS"
APP_DIR="${OUTPUT_DIR}/${APP_NAME}.app"

cd "${PROJECT_DIR}"

if [[ "${UMIS_UNIVERSAL2:-0}" == "1" ]]; then
    swift build --configuration "${CONFIGURATION}" --product RinkanUMIS --arch arm64 --arch x86_64
else
    swift build --configuration "${CONFIGURATION}" --product RinkanUMIS
fi

BIN_DIR=$(swift build --configuration "${CONFIGURATION}" --show-bin-path)
EXECUTABLE="${BIN_DIR}/RinkanUMIS"

if [[ ! -x "${EXECUTABLE}" ]]; then
    print -u2 "RinkanUMIS executable was not produced: ${EXECUTABLE}"
    exit 1
fi

if [[ -e "${APP_DIR}" ]]; then
    mv "${APP_DIR}" "${APP_DIR}.previous.$(date +%Y%m%d%H%M%S)"
fi

mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
ditto "${EXECUTABLE}" "${APP_DIR}/Contents/MacOS/RinkanUMIS"
ditto "${PROJECT_DIR}/Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"
ditto "${PROJECT_DIR}/Sources/RinkanUMIS/Resources" "${APP_DIR}/Contents/Resources"

IDENTITY=${UMIS_CODESIGN_IDENTITY:-}
if [[ -z "${IDENTITY}" ]]; then
    IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -n 1)
fi

if [[ -n "${IDENTITY}" ]]; then
    codesign --force --options runtime --timestamp --entitlements "${PROJECT_DIR}/Resources/RinkanUMIS.entitlements" --sign "${IDENTITY}" "${APP_DIR}"
elif [[ "${UMIS_ALLOW_ADHOC:-0}" == "1" ]]; then
    codesign --force --options runtime --timestamp=none --entitlements "${PROJECT_DIR}/Resources/RinkanUMIS.entitlements" --sign - "${APP_DIR}"
else
    print -u2 "Developer ID Application identity is not installed. Set UMIS_ALLOW_ADHOC=1 only for a local development build."
    exit 2
fi

codesign --verify --deep --strict --verbose=2 "${APP_DIR}"
plutil -lint "${APP_DIR}/Contents/Info.plist"
print "${APP_DIR}"
