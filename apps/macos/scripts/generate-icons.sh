#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
RESOURCES_DIR="$PROJECT_DIR/Packaging/Resources"
MASTER_PATH="$RESOURCES_DIR/Brand/AppIcon-master.png"
ICONSET_DIR="$RESOURCES_DIR/AppIcon.iconset"
ICNS_PATH="$RESOURCES_DIR/AppIcon.icns"

export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build-cache/clang"

if [[ ! -f "$MASTER_PATH" ]]; then
    echo "Missing app icon master: $MASTER_PATH" >&2
    exit 1
fi

mkdir -p "$ICONSET_DIR" "$CLANG_MODULE_CACHE_PATH"

make_icon() {
    local size=$1
    local filename=$2
    sips -z "$size" "$size" "$MASTER_PATH" --out "$ICONSET_DIR/$filename" >/dev/null
}

make_icon 16 icon_16x16.png
make_icon 32 icon_16x16@2x.png
make_icon 32 icon_32x32.png
make_icon 64 icon_32x32@2x.png
make_icon 128 icon_128x128.png
make_icon 256 icon_128x128@2x.png
make_icon 256 icon_256x256.png
make_icon 512 icon_256x256@2x.png
make_icon 512 icon_512x512.png
make_icon 1024 icon_512x512@2x.png

xcrun swift "$SCRIPT_DIR/build-icns.swift" "$ICONSET_DIR" "$ICNS_PATH"
echo "$ICNS_PATH"
