#!/bin/zsh
set -e

DESKTOP_BUILD_DIR="/Users/matthewt/Desktop/MacApp-Build"
APP_NAME="Project Nobel"
DESKTOP_APP="/Users/matthewt/Desktop/${APP_NAME}.app"
TARGET_APP="/Applications/${APP_NAME}.app"

if [ -d "${DESKTOP_BUILD_DIR}/${APP_NAME}.app" ]; then
    APP_BUNDLE="${DESKTOP_BUILD_DIR}/${APP_NAME}.app"
elif [ -d "${DESKTOP_APP}" ]; then
    APP_BUNDLE="${DESKTOP_APP}"
else
    echo "No existing app bundle found on Desktop. Running build_app.sh..."
    "$(dirname "$0")/swiftui-version/build_app.sh"
    APP_BUNDLE="${DESKTOP_APP}"
fi

echo "Moving standalone app bundle to /Applications..."

# Remove old app if it exists
if [ -d "${TARGET_APP}" ]; then
    echo "Removing existing app at ${TARGET_APP}..."
    rm -rf "${TARGET_APP}"
fi

# Copy the app to /Applications
echo "Copying ${APP_NAME}.app to /Applications..."
cp -R "${APP_BUNDLE}" "${TARGET_APP}"

# Clear macOS quarantine flags and re-sign
echo "Removing quarantine flags..."
xattr -cr "${TARGET_APP}"
codesign --force --deep --sign - "${TARGET_APP}"
touch "${TARGET_APP}"

# Clean up temporary build folder if it exists
if [ -d "${DESKTOP_BUILD_DIR}" ]; then
    echo "Cleaning up temporary Desktop build folder..."
    rm -rf "${DESKTOP_BUILD_DIR}"
fi

echo "Deployment complete! You can now run ${APP_NAME} from your Applications folder."
