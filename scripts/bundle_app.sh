#!/usr/bin/env bash
set -euo pipefail

APP_NAME="UtilizationAnalyzer"
BUNDLE_ID="com.riteshyejju.UtilizationAnalyzer"
VERSION="${VERSION:-1.0.0}"
OUT_DIR="dist"
RELEASE_DIR="releases"
APP_BUNDLE="${OUT_DIR}/${APP_NAME}.app"
DMG_STAGING="${OUT_DIR}/dmg_staging"
DMG_PATH="${RELEASE_DIR}/${APP_NAME}.dmg"

echo "==> Building ${APP_NAME} (Release)..."
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/${APP_NAME}"
if [[ ! -f "${BIN_PATH}" ]]; then
    echo "Error: Binary not found at ${BIN_PATH}"
    exit 1
fi

echo "==> Packaging ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BIN_PATH}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

cat > "${APP_BUNDLE}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>UtilizationAnalyzer</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

echo -n "APPL????" > "${APP_BUNDLE}/Contents/PkgInfo"

SIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
echo "==> Signing ${APP_BUNDLE} (identity: ${SIGN_IDENTITY})..."
if [[ "${SIGN_IDENTITY}" == "-" ]]; then
    codesign --force --deep --sign - "${APP_BUNDLE}"
else
    codesign --force --deep --options runtime --timestamp --sign "${SIGN_IDENTITY}" "${APP_BUNDLE}"
fi

echo "==> Creating ${DMG_PATH}..."
rm -rf "${DMG_STAGING}"
mkdir -p "${DMG_STAGING}" "${RELEASE_DIR}"
cp -R "${APP_BUNDLE}" "${DMG_STAGING}/${APP_NAME}.app"
ln -s /Applications "${DMG_STAGING}/Applications"
rm -f "${DMG_PATH}"
hdiutil create -volname "${APP_NAME}" -srcfolder "${DMG_STAGING}" -ov -format UDZO "${DMG_PATH}" >/dev/null
rm -rf "${DMG_STAGING}"

if [[ "${SIGN_IDENTITY}" != "-" && -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    echo "==> Submitting ${DMG_PATH} for Apple Notarization..."
    xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${NOTARY_KEYCHAIN_PROFILE}" --wait
    xcrun stapler staple "${DMG_PATH}"
fi

echo "==> Built ${APP_BUNDLE} and ${DMG_PATH} successfully!"
