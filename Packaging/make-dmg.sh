#!/bin/bash
#
#  make-dmg.sh — build Isle in Release and package it as a drag-to-install DMG.
#
#  Usage (from anywhere):
#      ./Packaging/make-dmg.sh
#
#  Output:
#      dist/Isle.dmg   (upload this to a GitHub Release)
#
#  What you get: a window with Isle on the left, an arrow, and the Applications
#  folder on the right, on Isle's own background, with Isle's icon on the volume.
#
#  Signing: the build is ad-hoc signed (no Apple Developer ID). It runs fine on
#  this Mac. On someone else's Mac, Gatekeeper will say it "can't be opened";
#  they right-click Isle ▸ Open once (or System Settings ▸ Privacy & Security ▸
#  Open Anyway). Set DEVELOPER_ID below to sign + notarize properly instead.
#
set -euo pipefail

# Optional: "Developer ID Application: Your Name (TEAMID)" — leave empty for ad-hoc.
DEVELOPER_ID="${DEVELOPER_ID:-}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Isle"
BUILD_DIR="$ROOT/build"
DIST_DIR="$ROOT/dist"
BG_1X="$ROOT/Packaging/dmg-background.png"
BG_2X="$ROOT/Packaging/dmg-background@2x.png"
ICONSET_SRC="$ROOT/Isle/Assets.xcassets/AppIcon.appiconset"

WINDOW_W=660
WINDOW_H=420
ICON_SIZE=128
APP_X=165; APP_Y=215          # must match the arrow drawn on the background
APPS_X=495; APPS_Y=215

step() { printf "\n\033[1;35m▸ %s\033[0m\n" "$1"; }

# ── 1. Build ────────────────────────────────────────────────────────────────
step "Building $APP_NAME (Release)…"
xcodebuild \
    -project "$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    clean build \
    | grep -E "error:|warning: .*deprecated|BUILD (SUCCEEDED|FAILED)" || true

APP="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
if [ ! -d "$APP" ]; then
    echo "✗ Build failed — run the xcodebuild command above without the grep to see why."
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 1.0)"
DMG_NAME="$APP_NAME"   # fixed name, so the website link (releases/latest/download/Isle.dmg) always works
FINAL_DMG="$DIST_DIR/$DMG_NAME.dmg"

# ── 2. Sign ─────────────────────────────────────────────────────────────────
if [ -n "$DEVELOPER_ID" ]; then
    step "Signing with $DEVELOPER_ID…"
    codesign --force --deep --options runtime \
        --entitlements "$ROOT/Config/Isle.entitlements" \
        --sign "$DEVELOPER_ID" "$APP"
else
    step "Ad-hoc signing…"
    codesign --force --deep --sign - "$APP"
fi

# ── 3. Stage the DMG contents ───────────────────────────────────────────────
step "Preparing disk image…"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

mkdir "$STAGING/.background"
if command -v tiffutil >/dev/null && [ -f "$BG_2X" ]; then
    # One TIFF with both resolutions, so the background is sharp on Retina.
    tiffutil -cathidpicheck "$BG_1X" "$BG_2X" -out "$STAGING/.background/background.tiff" >/dev/null 2>&1
    BG_FILE="background.tiff"
else
    cp "$BG_1X" "$STAGING/.background/background.png"
    BG_FILE="background.png"
fi

# Volume icon = the app icon.
if command -v iconutil >/dev/null; then
    ICONSET="$(mktemp -d)/Isle.iconset"
    mkdir -p "$ICONSET"
    cp "$ICONSET_SRC"/icon_*.png "$ICONSET/"
    iconutil -c icns "$ICONSET" -o "$STAGING/.VolumeIcon.icns" 2>/dev/null || true
fi

# ── 4. Create a writable image and lay out its window ───────────────────────
mkdir -p "$DIST_DIR"
RW_DMG="$(mktemp -u).dmg"
VOLUME="/Volumes/$APP_NAME"

# A previous run that crashed can leave the volume mounted.
if [ -d "$VOLUME" ]; then hdiutil detach "$VOLUME" -force >/dev/null 2>&1 || true; fi

hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" \
    -fs HFS+ -format UDRW -ov "$RW_DMG" >/dev/null

DEVICE="$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG" | grep -E '^/dev/' | head -1 | awk '{print $1}')"

# Mark the custom volume icon as active.
if [ -f "$VOLUME/.VolumeIcon.icns" ] && command -v SetFile >/dev/null; then
    SetFile -c icnC "$VOLUME/.VolumeIcon.icns" 2>/dev/null || true
    SetFile -a C "$VOLUME" 2>/dev/null || true
fi

step "Arranging the window (macOS may ask to let Terminal control Finder — allow it)…"
osascript <<APPLESCRIPT || echo "  (Couldn't style the window — the DMG still works, just without the layout.)"
tell application "Finder"
    tell disk "$APP_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 200 + $WINDOW_W, 120 + $WINDOW_H}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to $ICON_SIZE
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:$BG_FILE"
        set position of item "$APP_NAME.app" of container window to {$APP_X, $APP_Y}
        set position of item "Applications" of container window to {$APPS_X, $APPS_Y}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$DEVICE" >/dev/null 2>&1 || hdiutil detach "$DEVICE" -force >/dev/null

# ── 5. Compress into the final read-only DMG ────────────────────────────────
step "Compressing…"
rm -f "$FINAL_DMG"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$FINAL_DMG" >/dev/null
rm -f "$RW_DMG"

if [ -n "$DEVELOPER_ID" ]; then
    codesign --sign "$DEVELOPER_ID" "$FINAL_DMG"
    echo "  Signed. To notarize:"
    echo "  xcrun notarytool submit \"$FINAL_DMG\" --keychain-profile <profile> --wait && xcrun stapler staple \"$FINAL_DMG\""
fi

SIZE="$(du -h "$FINAL_DMG" | cut -f1)"
printf "\n\033[1;32m✓ %s  (%s)\033[0m\n" "$FINAL_DMG" "$SIZE"
open -R "$FINAL_DMG"
