#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-${1:-}}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
APP_NAME="Apple Music Lyrics"
SLUG="Apple-Music-Lyrics"
ARTIFACT_DIR="$ROOT/dist/release"
STAGING_DIR="$ROOT/dist/dmg-staging"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Usage: VERSION=1.2.3 $0 (or pass 1.2.3 as the first argument)" >&2
  exit 1
fi

VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" UNIVERSAL=1 \
  "$ROOT/scripts/package-app.sh"

APP="$ROOT/dist/$APP_NAME.app"
BIN="$APP/Contents/MacOS/AppleMusicLyrics"
ARCHS="$(lipo -archs "$BIN")"
if [[ "$ARCHS" != *"arm64"* || "$ARCHS" != *"x86_64"* ]]; then
  echo "Expected a universal binary, found: $ARCHS" >&2
  exit 1
fi

rm -rf "$ARTIFACT_DIR" "$STAGING_DIR"
mkdir -p "$ARTIFACT_DIR" "$STAGING_DIR"

ZIP="$ARTIFACT_DIR/$SLUG-$VERSION-macos-universal.zip"
DMG="$ARTIFACT_DIR/$SLUG-$VERSION-macos-universal.dmg"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
ditto "$APP" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create \
  -volname "$APP_NAME $VERSION" \
  -srcfolder "$STAGING_DIR" \
  -format UDZO \
  -ov \
  "$DMG" >/dev/null

rm -rf "$STAGING_DIR"
(
  cd "$ARTIFACT_DIR"
  shasum -a 256 "$(basename "$ZIP")" "$(basename "$DMG")" > SHA256SUMS.txt
)

echo "→ Release artifacts:"
ls -lh "$ARTIFACT_DIR"
