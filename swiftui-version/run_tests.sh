#!/bin/zsh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"

echo "Building release binary for test execution..."
cd "${SCRIPT_DIR}"
swift build -c release

echo "Executing unit test suite..."
"${SCRIPT_DIR}/.build/release/macOS-Native" --run-tests
