#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
ROOT_DIR=${PROJECT_DIR:h:h}
DIST_DIR="$ROOT_DIR/dist"
STAGING_DIR="$PROJECT_DIR/.package"
APP_DIR="$STAGING_DIR/MiPopup.app"
CONTENTS_DIR="$APP_DIR/Contents"

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build-cache/clang"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

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
    "$DIST_DIR/MiPopup-0.1.0-arm64.pkg"

echo "$DIST_DIR/MiPopup-0.1.0-arm64.pkg"
