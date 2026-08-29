#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
cd "${PROJECT_DIR}"
chmod +x .githooks/pre-commit .githooks/pre-push
git config core.hooksPath .githooks
print "Git hooks enabled: $(git config core.hooksPath)"
