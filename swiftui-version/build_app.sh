#!/bin/zsh
set -e

# Define directories
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="${SCRIPT_DIR}"
BUILD_DIR="${SRC_DIR}/.build/release"
DESKTOP_BUILD_DIR="${HOME}/Desktop/MacApp-Build"
APP_NAME="Project Nobel"
APP_BUNDLE="${DESKTOP_BUILD_DIR}/${APP_NAME}.app"
DESKTOP_APP="${HOME}/Desktop/${APP_NAME}.app"

if [ -z "$SDKROOT" ] && [ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk" ]; then
    export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
fi

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
    <string>1.0.3</string>
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

# Seed desktop testing database from production database only if desktop DB is missing, corrupt, or empty
PROD_DB="$HOME/.physics_study_app/physics_study.db"
DESKTOP_DB="$HOME/.physics_study_app/physics_study_desktop.db"
if [ -f "${PROD_DB}" ]; then
    NEED_SEED=0
    if [ ! -f "${DESKTOP_DB}" ]; then
        NEED_SEED=1
    else
        INTEGRITY=$(sqlite3 "${DESKTOP_DB}" "PRAGMA quick_check;" 2>/dev/null || echo "fail")
        MOD_COUNT=$(sqlite3 "${DESKTOP_DB}" "SELECT COUNT(*) FROM modules;" 2>/dev/null || echo "0")
        if [ "${INTEGRITY}" != "ok" ] || [ "${MOD_COUNT}" -eq 0 ] 2>/dev/null; then
            NEED_SEED=1
        fi
    fi
    if [ "${NEED_SEED}" -eq 1 ]; then
        echo "Seeding desktop database from production database..."
        rm -f "${DESKTOP_DB}" "${DESKTOP_DB}-wal" "${DESKTOP_DB}-shm"
        sqlite3 "${PROD_DB}" ".backup '${DESKTOP_DB}'"
    else
        echo "Preserving existing valid desktop database (${DESKTOP_DB}) so desktop review progress is not overwritten."
    fi
fi

echo "Build and bundle creation complete: ${DESKTOP_APP}"


