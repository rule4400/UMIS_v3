#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
MASTER=${UMIS_ICON_MASTER:-${PROJECT_DIR}/Resources/RinkanUMIS-AppIcon-1024.png}
OUTPUT=${UMIS_ICON_OUTPUT:-${PROJECT_DIR}/Resources/RinkanUMIS.icns}
BACKUP_ROOT=${UMIS_ICON_BACKUP_DIR:-${PROJECT_DIR}/Artifacts/icon-backups}

if [[ ! -f "${MASTER}" ]]; then
    print -u2 "The 1024-pixel app-icon master is missing: ${MASTER}"
    exit 2
fi

MASTER_WIDTH=$(sips -g pixelWidth "${MASTER}" | awk '/pixelWidth:/ {print $2}')
MASTER_HEIGHT=$(sips -g pixelHeight "${MASTER}" | awk '/pixelHeight:/ {print $2}')
MASTER_FORMAT=$(sips -g format "${MASTER}" | awk '/format:/ {print $2}')
MASTER_PROFILE=$(sips -g profile "${MASTER}" | sed -n 's/^[[:space:]]*profile: //p')
if [[ "${MASTER_WIDTH}" != "1024" || "${MASTER_HEIGHT}" != "1024" || \
    "${MASTER_FORMAT}" != "png" || "${MASTER_PROFILE}" != *sRGB* ]]; then
    print -u2 "The app-icon master must be a 1024x1024 sRGB PNG."
    exit 2
fi

WORK_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/umis-icon.XXXXXX")
ICONSET="${WORK_ROOT}/RinkanUMIS.iconset"
TEMP_ICNS="${WORK_ROOT}/RinkanUMIS.icns"
cleanup_icon_work() {
    if [[ -d "${WORK_ROOT}" ]]; then
        rm -r "${WORK_ROOT}"
    fi
}
trap cleanup_icon_work EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

mkdir -p "${ICONSET}"
render_icon() {
    local size=$1
    local filename=$2
    sips -s format png -z "${size}" "${size}" "${MASTER}" \
        --out "${ICONSET}/${filename}" >/dev/null
}

render_icon 16 icon_16x16.png
render_icon 32 icon_16x16@2x.png
render_icon 32 icon_32x32.png
render_icon 64 icon_32x32@2x.png
render_icon 128 icon_128x128.png
render_icon 256 icon_128x128@2x.png
render_icon 256 icon_256x256.png
render_icon 512 icon_256x256@2x.png
render_icon 512 icon_512x512.png
render_icon 1024 icon_512x512@2x.png

iconutil -c icns --output "${TEMP_ICNS}" "${ICONSET}"
if [[ ! -s "${TEMP_ICNS}" ]]; then
    print -u2 "iconutil did not produce a valid application icon."
    exit 1
fi

mkdir -p "${OUTPUT:h}"
OUTPUT_TEMP="${OUTPUT}.tmp.$$"
ditto "${TEMP_ICNS}" "${OUTPUT_TEMP}"

BACKUP_PATH=""
if [[ -d "${OUTPUT}" ]]; then
    print -u2 "The application-icon output path is a directory: ${OUTPUT}"
    exit 2
fi
if [[ -f "${OUTPUT}" ]]; then
    if cmp -s "${OUTPUT_TEMP}" "${OUTPUT}"; then
        rm "${OUTPUT_TEMP}"
        print "${OUTPUT}"
        print "sha256=$(shasum -a 256 "${OUTPUT}" | awk '{print $1}')"
        print "unchanged=true"
        exit 0
    fi

    mkdir -p "${BACKUP_ROOT}"
    BACKUP_PATH="${BACKUP_ROOT}/${OUTPUT:t}.previous.$(date -u +%Y%m%dT%H%M%SZ)"
    BACKUP_SUFFIX=1
    while [[ -e "${BACKUP_PATH}" ]]; do
        BACKUP_PATH="${BACKUP_ROOT}/${OUTPUT:t}.previous.$(date -u +%Y%m%dT%H%M%SZ).${BACKUP_SUFFIX}"
        (( BACKUP_SUFFIX += 1 ))
    done
    ditto "${OUTPUT}" "${BACKUP_PATH}"
fi

mv "${OUTPUT_TEMP}" "${OUTPUT}"

print "${OUTPUT}"
print "sha256=$(shasum -a 256 "${OUTPUT}" | awk '{print $1}')"
if [[ -n "${BACKUP_PATH}" ]]; then
    print "previous=${BACKUP_PATH}"
fi
