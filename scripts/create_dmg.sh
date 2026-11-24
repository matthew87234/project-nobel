#!/bin/zsh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SRC_DIR="${REPO_ROOT}"
BUILD_DIR="${SRC_DIR}/.build/release"
DMG_STAGING="${REPO_ROOT}/.build_dmg_staging"
APP_NAME="Project Nobel"
DMG_OUTPUT_NAME="Project-Nobel-Installer.dmg"
FINAL_DMG="${REPO_ROOT}/${DMG_OUTPUT_NAME}"
BG_IMAGE="${REPO_ROOT}/dmg_background.png"
VERSION_FILE="${SRC_DIR}/VERSION"
if [[ "${GITHUB_REF_NAME:-}" == v* ]]; then
    APP_VERSION="${GITHUB_REF_NAME#v}"
elif [ -f "${VERSION_FILE}" ]; then
    APP_VERSION="$(tr -d '[:space:]' < "${VERSION_FILE}")"
else
    APP_VERSION="1.0.3"
fi

if [ -z "$SDKROOT" ]; then
    if [ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk" ]; then
        export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
    elif command -v xcrun >/dev/null 2>&1; then
        export SDKROOT="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
    fi
fi

echo "=================================================="
echo " 1. Building ${APP_NAME} Release Binary"
echo "=================================================="

cd "${SRC_DIR}"
swift build -c release

echo "=================================================="
echo " 2. Creating Application Bundle (.app)"
echo "=================================================="

APP_BUNDLE="${DMG_STAGING}/${APP_NAME}.app"
rm -rf "${DMG_STAGING}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cat <<EOF > "${APP_BUNDLE}/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ProjectNobel</string>
    <key>CFBundleIdentifier</key>
    <string>com.projectnobel.app</string>
    <key>CFBundleName</key>
    <string>Project Nobel</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
</dict>
</plist>
EOF

cp "${BUILD_DIR}/ProjectNobel" "${APP_BUNDLE}/Contents/MacOS/ProjectNobel"
if [ -f "${SRC_DIR}/Resources/AppIcon.icns" ]; then
    cp "${SRC_DIR}/Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
fi
if [ -f "${SRC_DIR}/Resources/MenuBarIcon.png" ]; then
    cp "${SRC_DIR}/Resources/MenuBarIcon.png" "${APP_BUNDLE}/Contents/Resources/MenuBarIcon.png"
fi
if [ -d "${SRC_DIR}/Resources/katex" ]; then
    cp -R "${SRC_DIR}/Resources/katex" "${APP_BUNDLE}/Contents/Resources/katex"
fi

xattr -cr "${APP_BUNDLE}"
echo "Signing application bundle with ad-hoc identity..."
codesign --force --deep --sign - "${APP_BUNDLE}"

echo "=================================================="
echo " 3. Generating High-Res DMG Background Image"
echo "=================================================="

swift "${SCRIPT_DIR}/generate_dmg_background.swift" "${BG_IMAGE}"

echo "=================================================="
echo " 4. Creating Professional DMG with dmgbuild"
echo "=================================================="

rm -f "${FINAL_DMG}"

cd "${REPO_ROOT}"
python3 -m dmgbuild -s "${SCRIPT_DIR}/dmgbuild_settings.py" "Project Nobel" "${FINAL_DMG}"

# Cleanup staging and generated background
rm -rf "${DMG_STAGING}"
rm -f "${BG_IMAGE}"

echo "=================================================="
echo " DMG Successfully Created!"
echo " Path: ${FINAL_DMG}"
echo " File Size: $(du -sh "${FINAL_DMG}" | awk '{print $1}')"
echo "=================================================="
