#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-}"
VERSION="${2:-}"
OUTPUT_DMG="${3:-}"
APP_NAME="Apple Music Lyrics"
BACKGROUND_GENERATOR="$ROOT/scripts/generate-dmg-background.swift"
INSTALL_GUIDE="$ROOT/Resources/InstallGuide.txt"

if [[ ! -d "$APP" || "$(basename "$APP")" != "$APP_NAME.app" ]]; then
  echo "Usage: $0 <Apple Music Lyrics.app> <version> <output.dmg>" >&2
  exit 1
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || "$OUTPUT_DMG" != *.dmg ]]; then
  echo "Version must use numeric SemVer and output must end in .dmg" >&2
  exit 1
fi
if [[ ! -f "$BACKGROUND_GENERATOR" || ! -f "$INSTALL_GUIDE" ]]; then
  echo "DMG installer resources are missing" >&2
  exit 1
fi

OUTPUT_DIR="$(dirname "$OUTPUT_DMG")"
mkdir -p "$OUTPUT_DIR"
WORK_DIR="$(mktemp -d "$OUTPUT_DIR/dmg-build.XXXXXX")"
STAGING_DIR="$WORK_DIR/staging"
RW_DMG="$WORK_DIR/read-write.dmg"
MOUNT_DIR="$WORK_DIR/mount"
VOLUME_NAME="$APP_NAME $VERSION"
MOUNT_DEVICE=""

cleanup() {
  if [[ -n "$MOUNT_DEVICE" ]]; then
    hdiutil detach "$MOUNT_DEVICE" -force >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$STAGING_DIR/.background" "$MOUNT_DIR"
ditto "$APP" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"
cp "$INSTALL_GUIDE" "$STAGING_DIR/安装与权限说明.txt"
xcrun swift "$BACKGROUND_GENERATOR" \
  "$VERSION" "$STAGING_DIR/.background/background.png"
cp "$ROOT/Resources/AppIcon.icns" "$STAGING_DIR/.VolumeIcon.icns"

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -format UDRW \
  -ov \
  "$RW_DMG" >/dev/null

ATTACH_OUTPUT="$(hdiutil attach \
  -readwrite \
  -noverify \
  -noautoopen \
  -mountpoint "$MOUNT_DIR" \
  "$RW_DMG")"
MOUNT_DEVICE="$(awk '/^\/dev\/disk/ { print $1; exit }' <<<"$ATTACH_OUTPUT")"
if [[ -z "$MOUNT_DEVICE" ]]; then
  echo "Unable to determine mounted DMG device" >&2
  exit 1
fi

/usr/bin/SetFile -a V "$MOUNT_DIR/.background" "$MOUNT_DIR/.VolumeIcon.icns"
/usr/bin/SetFile -a C "$MOUNT_DIR"

osascript <<APPLESCRIPT
tell application "Finder"
  set dmgFolder to POSIX file "$MOUNT_DIR" as alias
  open dmgFolder
  set dmgWindow to container window of dmgFolder
  set current view of dmgWindow to icon view
  set toolbar visible of dmgWindow to false
  set statusbar visible of dmgWindow to false
  set pathbar visible of dmgWindow to false
  set bounds of dmgWindow to {120, 120, 840, 645}
  set viewOptions to the icon view options of dmgWindow
  set arrangement of viewOptions to not arranged
  set icon size of viewOptions to 112
  set text size of viewOptions to 12
  set shows item info of viewOptions to false
  set shows icon preview of viewOptions to true
  set background picture of viewOptions to file ".background:background.png" of dmgFolder
  set position of item "$APP_NAME.app" of dmgFolder to {180, 235}
  set position of item "Applications" of dmgFolder to {540, 235}
  set position of item "安装与权限说明.txt" of dmgFolder to {360, 425}
  update dmgFolder without registering applications
  delay 2
  close dmgWindow
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT_DEVICE" >/dev/null
MOUNT_DEVICE=""
hdiutil convert \
  "$RW_DMG" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  -o "$OUTPUT_DMG" >/dev/null

cleanup
trap - EXIT
echo "→ DMG ready: $OUTPUT_DMG"
