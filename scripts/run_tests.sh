#!/bin/zsh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
if [ -z "$SDKROOT" ]; then
    if [ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk" ]; then
        export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
    elif command -v xcrun >/dev/null 2>&1; then
        export SDKROOT="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
    fi
fi

echo "Building debug binary for test execution..."
cd "${REPO_ROOT}"
swift build

echo "Executing unit test suite..."
"${REPO_ROOT}/.build/debug/ProjectNobel" --run-tests
