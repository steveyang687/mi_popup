#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build-cache/clang"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

cd "$PROJECT_DIR"
echo "MiPopup debug 模式已启动；按 Ctrl+C 退出。修改源码后需要重新运行此命令。"
exec swift run --disable-sandbox MiPopup
