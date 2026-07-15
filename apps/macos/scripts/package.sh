#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
ROOT_DIR=${PROJECT_DIR:h:h}
DIST_DIR="$ROOT_DIR/dist"
STAGING_DIR="$PROJECT_DIR/.package"
APP_DIR="$STAGING_DIR/MiPopup.app"
CONTENTS_DIR="$APP_DIR/Contents"
DMG_DIR="$STAGING_DIR/dmg"
PKG_PATH="$DIST_DIR/MiPopup-0.1.0-arm64.pkg"
DMG_PATH="$DIST_DIR/MiPopup-0.1.0-arm64.dmg"

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build-cache/clang"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$DIST_DIR"

cd "$PROJECT_DIR"
swift build -c release --disable-sandbox

rm -rf "$STAGING_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp ".build/release/MiPopup" "$CONTENTS_DIR/MacOS/MiPopup"
cp "Packaging/Info.plist" "$CONTENTS_DIR/Info.plist"

xattr -cr "$APP_DIR"
codesign --force --deep --sign - "$APP_DIR"
COPYFILE_DISABLE=1 pkgbuild \
    --component "$APP_DIR" \
    --install-location /Applications \
    "$PKG_PATH"

mkdir -p "$DMG_DIR"
ditto "$APP_DIR" "$DMG_DIR/MiPopup.app"
ln -s /Applications "$DMG_DIR/Applications"
COPYFILE_DISABLE=1 hdiutil create \
    -volname "MiPopup" \
    -srcfolder "$DMG_DIR" \
    -format UDZO \
    -ov \
    "$DMG_PATH"

echo "$PKG_PATH"
echo "$DMG_PATH"
