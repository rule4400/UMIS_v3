#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
REVISION=${1:-}
TARGET=${2:-}

if [[ -z "${REVISION}" || -z "${TARGET}" || "${TARGET}" != /* ]]; then
    print -u2 "Usage: Scripts/checkout_version.sh <tag-or-commit> <absolute-empty-target>"
    exit 2
fi

if [[ -e "${TARGET}" ]]; then
    print -u2 "Target already exists: ${TARGET}"
    exit 3
fi

cd "${PROJECT_DIR}"
git rev-parse --verify "${REVISION}^{commit}" >/dev/null
git worktree add --detach "${TARGET}" "${REVISION}"
print "${TARGET}"
