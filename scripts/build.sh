#!/bin/bash
# TypelessPlus 构建脚本 v0.3.0
# 使用 swiftc 直接编译 → 生成 .app bundle

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
BUILD_DIR="$PROJECT_DIR/.build"
APP_NAME="TypelessPlus.app"
APP_DIR="$BUILD_DIR/$APP_NAME"

echo "=== TypelessPlus 构建脚本 v0.3.0 ==="
echo "项目目录: $PROJECT_DIR"

# Step 1: 检查依赖
echo ""
echo "--- 检查系统依赖 ---"

check_tool() {
    if command -v "$1" &> /dev/null; then
        echo "  [OK] $1 ($(command -v "$1"))"
    else
        echo "  [MISSING] $1"
    fi
}

check_tool swiftc
check_tool python3

# Step 2: 安装 Python 依赖
echo ""
echo "--- 安装 Python 依赖 ---"
if python3 -c "import faster_whisper" 2>/dev/null; then
    echo "  [OK] faster-whisper 已安装"
else
    echo "  安装 faster-whisper..."
    python3 -m pip install -r "$PROJECT_DIR/TypelessAI/requirements.txt"
fi

# Step 3: 下载模型（如果不存在）
echo ""
echo "--- 检查模型 ---"
if [ -d "$PROJECT_DIR/models/models--Systran--faster-whisper-base" ]; then
    echo "  [OK] faster-whisper base 模型已存在"
else
    echo "  模型未下载，运行 install_models.sh..."
    bash "$PROJECT_DIR/scripts/install_models.sh"
fi

# Step 4: 编译 Swift 应用
echo ""
echo "--- 编译 Swift 应用 ---"

mkdir -p "$BUILD_DIR"

swiftc -target arm64-apple-macos14.0 \
  -framework AppKit \
  -framework AVFoundation \
  -framework CoreGraphics \
  -framework Foundation \
  "$PROJECT_DIR/TypelessUI/TypelessApp.swift" \
  "$PROJECT_DIR/TypelessUI/Constants.swift" \
  "$PROJECT_DIR/TypelessUI/AudioRecorder.swift" \
  "$PROJECT_DIR/TypelessUI/KeyboardEmulator.swift" \
  "$PROJECT_DIR/TypelessUI/WhisperBridge.swift" \
  "$PROJECT_DIR/TypelessUI/LLMBridge.swift" \
  "$PROJECT_DIR/TypelessUI/GlobalHotkeyMonitor.swift" \
  "$PROJECT_DIR/TypelessUI/OverlayWindow.swift" \
  "$PROJECT_DIR/TypelessUI/SettingsView.swift" \
  -o "$BUILD_DIR/TypelessPlus"

echo "  [OK] 编译成功: $BUILD_DIR/TypelessPlus"

# Step 5: 创建 .app bundle
echo ""
echo "--- 创建 .app bundle ---"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources/TypelessAI"
mkdir -p "$APP_DIR/Contents/Resources/models"

cp "$BUILD_DIR/TypelessPlus" "$APP_DIR/Contents/MacOS/"
cp "$PROJECT_DIR/TypelessUI/Info.plist" "$APP_DIR/Contents/"
cp "$PROJECT_DIR/TypelessAI/server.py" "$APP_DIR/Contents/Resources/TypelessAI/"

# 复制模型（如果通过 install_models.sh 下载到了 models/ 目录）
if [ -d "$PROJECT_DIR/models/models--Systran--faster-whisper-base" ]; then
    cp -R "$PROJECT_DIR/models/" "$APP_DIR/Contents/Resources/models/" 2>/dev/null || true
fi

# Ad-hoc 签名（macOS 要求使用 CGEventTap 等 API 的应用必须签名）
codesign --force --deep -s - "$APP_DIR" 2>/dev/null

echo "  [OK] .app bundle: $APP_DIR"

echo ""
echo "=== 构建完成 ==="
echo "运行方式:"
echo "  open $APP_DIR"