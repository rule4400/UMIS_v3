#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
cd "${PROJECT_DIR}"

command -v xcodebuild >/dev/null || { print -u2 "Xcode is required"; exit 2; }
command -v swift >/dev/null || { print -u2 "Swift is required"; exit 2; }
command -v git >/dev/null || { print -u2 "Git is required"; exit 2; }

xcodebuild -version
swift --version
xcrun --sdk macosx --show-sdk-version

Scripts/install_git_hooks.sh
swift package resolve
swift test --parallel

print "Development environment is ready."
print "Open ${PROJECT_DIR}/Package.swift in Xcode, or run: swift run RinkanUMIS"
