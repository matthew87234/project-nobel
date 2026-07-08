#!/bin/zsh
set -e

DESKTOP_BUILD_DIR="/Users/matthewt/Desktop/MacApp-Build"
APP_NAME="Project Nobel"
APP_BUNDLE="${DESKTOP_BUILD_DIR}/${APP_NAME}.app"
TARGET_APP="/Applications/${APP_NAME}.app"

echo "Moving standalone app bundle to /Applications..."

# Remove old app if it exists
if [ -d "${TARGET_APP}" ]; then
    echo "Removing existing app at ${TARGET_APP}..."
    rm -rf "${TARGET_APP}"
fi

# Copy the app to /Applications
echo "Copying ${APP_NAME}.app to /Applications..."
cp -R "${APP_BUNDLE}" "${TARGET_APP}"

# Clear macOS quarantine flags
echo "Removing quarantine flags..."
xattr -cr "${TARGET_APP}"

# Remove the temporary build dir on Desktop
echo "Cleaning up temporary Desktop build folder..."
rm -rf "${DESKTOP_BUILD_DIR}"

echo "Deployment complete! You can now run ${APP_NAME} from your Applications folder."
