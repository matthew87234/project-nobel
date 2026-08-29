#!/bin/zsh
set -e

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="${REPO_ROOT}/swiftui-version"
BUILD_DIR="${SRC_DIR}/.build/release"
DMG_STAGING="${REPO_ROOT}/.build_dmg_staging"
APP_NAME="Project Nobel"
DMG_OUTPUT_NAME="Project-Nobel-Installer.dmg"
FINAL_DMG="${REPO_ROOT}/${DMG_OUTPUT_NAME}"

echo "=================================================="
echo " Building ${APP_NAME} Release Binary"
echo "=================================================="

cd "${SRC_DIR}"
swift build -c release

echo "=================================================="
echo " Creating Application Bundle (.app)"
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

# Clear quarantine on binary
xattr -cr "${APP_BUNDLE}"

echo "=================================================="
echo " Preparing Disk Image Layout & /Applications Link"
echo "=================================================="

# Create Applications shortcut inside DMG
ln -s /Applications "${DMG_STAGING}/Applications"

echo "=================================================="
echo " Generating Compressed .dmg File"
echo "=================================================="

rm -f "${FINAL_DMG}"

hdiutil create \
    -volname "Project Nobel" \
    -srcfolder "${DMG_STAGING}" \
    -ov \
    -format UDZO \
    "${FINAL_DMG}"

# Cleanup staging directory
rm -rf "${DMG_STAGING}"

echo "=================================================="
echo " DMG Successfully Created!"
echo " Path: ${FINAL_DMG}"
echo " File Size: $(du -sh "${FINAL_DMG}" | awk '{print $1}')"
echo "=================================================="
