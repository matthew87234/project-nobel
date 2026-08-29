#!/bin/zsh
set -e

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="${REPO_ROOT}/swiftui-version"
BUILD_DIR="${SRC_DIR}/.build/release"
DMG_STAGING="${REPO_ROOT}/.build_dmg_staging"
APP_NAME="Project Nobel"
DMG_OUTPUT_NAME="Project-Nobel-Installer.dmg"
FINAL_DMG="${REPO_ROOT}/${DMG_OUTPUT_NAME}"
BG_IMAGE="${REPO_ROOT}/dmg_background.png"

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
    <string>macOS-Native</string>
    <key>CFBundleIdentifier</key>
    <string>com.projectnobel.macOS-Native</string>
    <key>CFBundleName</key>
    <string>Project Nobel</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
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

cp "${BUILD_DIR}/macOS-Native" "${APP_BUNDLE}/Contents/MacOS/macOS-Native"
if [ -f "${SRC_DIR}/Resources/AppIcon.icns" ]; then
    cp "${SRC_DIR}/Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
fi
if [ -f "${SRC_DIR}/Resources/MenuBarIcon.png" ]; then
    cp "${SRC_DIR}/Resources/MenuBarIcon.png" "${APP_BUNDLE}/Contents/Resources/MenuBarIcon.png"
fi

xattr -cr "${APP_BUNDLE}"
echo "Signing application bundle with ad-hoc identity..."
codesign --force --deep --sign - "${APP_BUNDLE}"

echo "=================================================="
echo " 3. Generating High-Res DMG Background Image"
echo "=================================================="

swift "${REPO_ROOT}/generate_dmg_background.swift" "${BG_IMAGE}"

echo "=================================================="
echo " 4. Creating Professional DMG with dmgbuild"
echo "=================================================="

rm -f "${FINAL_DMG}"

cd "${REPO_ROOT}"
python3 -m dmgbuild -s "${REPO_ROOT}/dmgbuild_settings.py" "Project Nobel" "${FINAL_DMG}"

# Cleanup staging and generated background
rm -rf "${DMG_STAGING}"
rm -f "${BG_IMAGE}"

echo "=================================================="
echo " DMG Successfully Created!"
echo " Path: ${FINAL_DMG}"
echo " File Size: $(du -sh "${FINAL_DMG}" | awk '{print $1}')"
echo "=================================================="
