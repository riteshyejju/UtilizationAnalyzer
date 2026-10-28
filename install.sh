#!/usr/bin/env bash
set -euo pipefail

APP_NAME="UtilizationAnalyzer"
DMG_URL="https://github.com/riteshyejju/UtilizationAnalyzer/releases/latest/download/UtilizationAnalyzer.dmg"
TMP_DMG="/tmp/${APP_NAME}.dmg"
MOUNT_POINT="/Volumes/${APP_NAME}"

echo "==> Downloading ${APP_NAME}..."
curl -fsSL "${DMG_URL}" -o "${TMP_DMG}"

echo "==> Mounting ${APP_NAME}.dmg..."
hdiutil attach "${TMP_DMG}" -nobrowse -quiet -mountpoint "${MOUNT_POINT}"

echo "==> Installing to /Applications/${APP_NAME}.app..."
rm -rf "/Applications/${APP_NAME}.app"
cp -R "${MOUNT_POINT}/${APP_NAME}.app" "/Applications/${APP_NAME}.app"

hdiutil detach "${MOUNT_POINT}" -quiet || true
rm -f "${TMP_DMG}"
xattr -cr "/Applications/${APP_NAME}.app" 2>/dev/null || true

echo "==> Installed! Launching ${APP_NAME}..."
open "/Applications/${APP_NAME}.app"
