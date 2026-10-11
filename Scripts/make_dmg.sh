#!/bin/bash
# Packages build/Playdock.app into dist/Playdock-<version>.dmg with a drag-to-Applications layout.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${1:-1.0.0}"
APP_BUNDLE="build/Playdock.app"
STAGING_DIR="build/dmg-staging"
DMG_PATH="dist/Playdock-${VERSION}.dmg"

if [ ! -d "$APP_BUNDLE" ]; then
    echo "error: $APP_BUNDLE not found - run Scripts/build_app.sh first" >&2
    exit 1
fi

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR" dist
cp -R "$APP_BUNDLE" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create -volname "Playdock" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"
hdiutil verify "$DMG_PATH"

rm -rf "$STAGING_DIR"
echo "==> Built $DMG_PATH"

# Real, previously-missing installer polish: the DMG above has no window layout at all - a raw
# Finder default with no sizing or icon positions, meaning whatever a user's Finder window
# settings happen to be, not a deliberate "app on the left, Applications on the right, drag
# between them" arrangement every other real Mac installer has. Re-opens the same DMG read-write,
# lays it out via a real Finder AppleScript (the standard technique - hdiutil itself has no icon-
# position API), then re-compresses back to the same read-only UDZO path.
echo "==> Laying out DMG window"
RW_DMG="build/Playdock-rw.dmg"
rm -f "$RW_DMG"
hdiutil convert "$DMG_PATH" -format UDRW -o "$RW_DMG"
MOUNT_DIR=$(hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen | grep -E '/Volumes/' | awk -F'\t' '{print $NF}')
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "Playdock"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 660, 420}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96
        set position of item "Playdock.app" of container window to {110, 150}
        set position of item "Applications" of container window to {350, 150}
        close
    end tell
end tell
APPLESCRIPT
hdiutil detach "$MOUNT_DIR"
rm -f "$DMG_PATH"
hdiutil convert "$RW_DMG" -format UDZO -o "$DMG_PATH"
rm -f "$RW_DMG"
hdiutil verify "$DMG_PATH"
echo "==> Laid out and re-compressed $DMG_PATH"
