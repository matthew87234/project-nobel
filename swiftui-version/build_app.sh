#!/bin/zsh
set -e

# Define directories
SRC_DIR="/Users/matthewt/Projects/PhysicsStudyApp/swiftui-version"
BUILD_DIR="${SRC_DIR}/.build/release"
DESKTOP_BUILD_DIR="/Users/matthewt/Desktop/MacApp-Build"
APP_NAME="Project Nobel"
APP_BUNDLE="${DESKTOP_BUILD_DIR}/${APP_NAME}.app"
DESKTOP_APP="/Users/matthewt/Desktop/${APP_NAME}.app"

echo "Building Swift Package Manager target in release mode..."
cd "${SRC_DIR}"
swift build -c release

echo "Creating the .app bundle directory structure..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

echo "Writing Info.plist..."
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
    <string>1.0</string>
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

echo "Copying binary target and icons to .app bundle..."
cp "${BUILD_DIR}/macOS-Native" "${APP_BUNDLE}/Contents/MacOS/macOS-Native"
if [ -f "${SRC_DIR}/Resources/AppIcon.icns" ]; then
    cp "${SRC_DIR}/Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
fi
if [ -f "${SRC_DIR}/Resources/MenuBarIcon.png" ]; then
    cp "${SRC_DIR}/Resources/MenuBarIcon.png" "${APP_BUNDLE}/Contents/Resources/MenuBarIcon.png"
fi

echo "Updating Desktop app bundle..."
rm -rf "${DESKTOP_APP}"
cp -R "${APP_BUNDLE}" "${DESKTOP_APP}"
xattr -cr "${DESKTOP_APP}"
codesign --force --deep --sign - "${DESKTOP_APP}"
touch "${DESKTOP_APP}"
rm -rf "${DESKTOP_BUILD_DIR}"

# One-way sync: Sync production database to desktop testing database if production exists
PROD_DB="$HOME/.physics_study_app/physics_study.db"
DESKTOP_DB="$HOME/.physics_study_app/physics_study_desktop.db"
if [ -f "${PROD_DB}" ]; then
    echo "Performing one-way sync from production database to desktop database..."
    cp "${PROD_DB}" "${DESKTOP_DB}"
fi

echo "Build and bundle creation complete: ${DESKTOP_APP}"


