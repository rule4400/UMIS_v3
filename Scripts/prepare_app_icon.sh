#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
SOURCE=${UMIS_ICON_UNMASKED_SOURCE:-${PROJECT_DIR}/Resources/RinkanUMIS-AppIcon-Unmasked-1024.png}
OUTPUT=${UMIS_ICON_MASKED_OUTPUT:-${PROJECT_DIR}/Resources/RinkanUMIS-AppIcon-1024.png}
BACKUP_ROOT=${UMIS_ICON_BACKUP_DIR:-${PROJECT_DIR}/Artifacts/icon-backups}
SRGB_PROFILE='/System/Library/ColorSync/Profiles/sRGB Profile.icc'

if [[ ! -f "${SOURCE}" ]]; then
    print -u2 "The unmasked application-icon source is missing: ${SOURCE}"
    exit 2
fi
if ! python3 -c 'from PIL import Image, ImageDraw, ImageFilter' >/dev/null 2>&1; then
    print -u2 "Preparing the legacy icon requires Python 3 and Pillow."
    exit 2
fi
if [[ ! -f "${SRGB_PROFILE}" ]]; then
    print -u2 "The system sRGB profile is missing: ${SRGB_PROFILE}"
    exit 2
fi

SOURCE_WIDTH=$(sips -g pixelWidth "${SOURCE}" | awk '/pixelWidth:/ {print $2}')
SOURCE_HEIGHT=$(sips -g pixelHeight "${SOURCE}" | awk '/pixelHeight:/ {print $2}')
SOURCE_FORMAT=$(sips -g format "${SOURCE}" | awk '/format:/ {print $2}')
SOURCE_PROFILE=$(sips -g profile "${SOURCE}" | sed -n 's/^[[:space:]]*profile: //p')
SOURCE_ALPHA=$(sips -g hasAlpha "${SOURCE}" | awk '/hasAlpha:/ {print $2}')
if [[ "${SOURCE_WIDTH}" != "1024" || "${SOURCE_HEIGHT}" != "1024" || \
    "${SOURCE_FORMAT}" != "png" || "${SOURCE_PROFILE}" != *sRGB* || \
    "${SOURCE_ALPHA}" != "no" ]]; then
    print -u2 "The unmasked source must be an opaque 1024x1024 sRGB PNG."
    exit 2
fi

WORK_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/umis-icon-mask.XXXXXX")
RAW_OUTPUT="${WORK_ROOT}/RinkanUMIS-legacy-raw.png"
PROFILED_OUTPUT="${WORK_ROOT}/RinkanUMIS-legacy-srgb.png"
cleanup_icon_mask_work() {
    if [[ -d "${WORK_ROOT}" ]]; then
        rm -r "${WORK_ROOT}"
    fi
}
trap cleanup_icon_mask_work EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

python3 - "${SOURCE}" "${RAW_OUTPUT}" <<'PY'
from pathlib import Path
import math
import sys

from PIL import Image, ImageDraw, ImageFilter

source_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])

# Measured against Apple's legacy macOS app-icon geometry. The unmasked artwork
# is retained separately for Icon Composer and system-mask workflows.
canvas_size = 1024
supersample = 4
body_size = 824
body_origin = 100
superellipse_exponent = 5.0
shadow_blur = 22
shadow_offset_y = 10
shadow_opacity = 0.20

with Image.open(source_path) as source_image:
    source = source_image.convert("RGBA")

high_canvas_size = canvas_size * supersample
high_body_size = body_size * supersample
high_body_origin = body_origin * supersample
center = high_body_origin + high_body_size / 2.0
half_extent = high_body_size / 2.0

points = []
for index in range(4096):
    angle = 2.0 * math.pi * index / 4096.0
    cosine = math.cos(angle)
    sine = math.sin(angle)
    x = center + half_extent * math.copysign(
        abs(cosine) ** (2.0 / superellipse_exponent), cosine
    )
    y = center + half_extent * math.copysign(
        abs(sine) ** (2.0 / superellipse_exponent), sine
    )
    points.append((x, y))

body_mask = Image.new("L", (high_canvas_size, high_canvas_size), 0)
ImageDraw.Draw(body_mask).polygon(points, fill=255)

scaled_artwork = source.resize(
    (high_body_size, high_body_size), Image.Resampling.LANCZOS
)
body_layer = Image.new(
    "RGBA", (high_canvas_size, high_canvas_size), (0, 0, 0, 0)
)
body_layer.paste(scaled_artwork, (high_body_origin, high_body_origin))
body_layer.putalpha(
    Image.composite(
        body_layer.getchannel("A"), Image.new("L", body_layer.size, 0), body_mask
    )
)

shadow_source = body_mask.filter(
    ImageFilter.GaussianBlur(radius=shadow_blur * supersample)
)
shadow_source = shadow_source.point(lambda value: round(value * shadow_opacity))
shadow_layer = Image.new(
    "RGBA", (high_canvas_size, high_canvas_size), (24, 38, 54, 0)
)
shadow_offset_mask = Image.new("L", shadow_layer.size, 0)
shadow_offset_mask.paste(shadow_source, (0, shadow_offset_y * supersample))
shadow_layer.putalpha(shadow_offset_mask)

result = Image.alpha_composite(shadow_layer, body_layer).resize(
    (canvas_size, canvas_size), Image.Resampling.LANCZOS
)
result.save(output_path, format="PNG", optimize=True)
PY

sips --matchTo "${SRGB_PROFILE}" "${RAW_OUTPUT}" --out "${PROFILED_OUTPUT}" >/dev/null

python3 - "${PROFILED_OUTPUT}" <<'PY'
from pathlib import Path
import sys

from PIL import Image

path = Path(sys.argv[1])
with Image.open(path) as source:
    image = source.convert("RGBA")

alpha = image.getchannel("A")
threshold = alpha.point(lambda value: 255 if value > 127 else 0)
bbox = threshold.getbbox()
edge_max = max(
    max(alpha.crop((0, 0, image.width, 1)).getdata()),
    max(alpha.crop((0, image.height - 1, image.width, image.height)).getdata()),
    max(alpha.crop((0, 0, 1, image.height)).getdata()),
    max(alpha.crop((image.width - 1, 0, image.width, image.height)).getdata()),
)
center_alpha = alpha.getpixel((image.width // 2, image.height // 2))

if image.size != (1024, 1024):
    raise SystemExit("The prepared icon is not 1024x1024.")
if bbox != (100, 100, 924, 924):
    raise SystemExit(f"Unexpected opaque body bounds: {bbox}")
if edge_max != 0:
    raise SystemExit("The prepared icon touches the canvas edge.")
if center_alpha != 255:
    raise SystemExit("The prepared icon center is not fully opaque.")
PY

OUTPUT_PROFILE=$(sips -g profile "${PROFILED_OUTPUT}" | sed -n 's/^[[:space:]]*profile: //p')
if [[ "${OUTPUT_PROFILE}" != *sRGB* ]]; then
    print -u2 "The prepared application icon does not have an sRGB profile."
    exit 2
fi

mkdir -p "${OUTPUT:h}"
OUTPUT_TEMP="${OUTPUT}.tmp.$$"
ditto "${PROFILED_OUTPUT}" "${OUTPUT_TEMP}"

BACKUP_PATH=""
if [[ -d "${OUTPUT}" ]]; then
    print -u2 "The prepared-icon output path is a directory: ${OUTPUT}"
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
