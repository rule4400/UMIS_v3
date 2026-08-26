#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
LABEL=${1:-}

if [[ -z "${LABEL}" || ! "${LABEL}" =~ '^[A-Za-z0-9._-]+$' ]]; then
    print -u2 "Usage: Scripts/create_checkpoint.sh <label>"
    exit 2
fi

cd "${PROJECT_DIR}"

if [[ -n "$(git status --porcelain)" ]]; then
    print -u2 "Working tree is not clean. Commit reviewed changes before creating a checkpoint."
    exit 3
fi

swift test

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
TAG="checkpoint/${STAMP}-${LABEL}"
OUT_DIR="${PROJECT_DIR}/Artifacts/checkpoints/${STAMP}-${LABEL}"
mkdir -p "${OUT_DIR}"

git tag -a "${TAG}" -m "Verified checkpoint ${LABEL} at ${STAMP}"
git rev-parse HEAD > "${OUT_DIR}/commit.txt"
git rev-parse HEAD^{tree} > "${OUT_DIR}/tree.txt"
swift --version > "${OUT_DIR}/swift-version.txt" 2>&1
xcodebuild -version > "${OUT_DIR}/xcode-version.txt"
xcrun --sdk macosx --show-sdk-version > "${OUT_DIR}/sdk-version.txt"
git ls-files -z | xargs -0 shasum -a 256 > "${OUT_DIR}/source-sha256.txt"

print "${TAG}"
print "${OUT_DIR}"
