#!/bin/zsh
set -e

# Define directories
SRC_DIR="/Users/matthewt/Projects/PhysicsStudyApp/swiftui-version"
BUILD_DIR="${SRC_DIR}/.build/release"
DESKTOP_BUILD_DIR="/Users/matthewt/Desktop/MacApp-Build"
APP_NAME="Project Nobel"
APP_BUNDLE="${DESKTOP_BUILD_DIR}/${APP_NAME}.app"

echo "Building Swift Package Manager target in release mode..."
cd "${SRC_DIR}"
swift build -c release

echo "Creating the .app bundle directory structure..."
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
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

echo "Copying binary target to .app bundle..."
cp "${BUILD_DIR}/macOS-Native" "${APP_BUNDLE}/Contents/MacOS/macOS-Native"

echo "Build and bundle creation complete: ${APP_BUNDLE}"
