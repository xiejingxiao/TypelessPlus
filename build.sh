#!/bin/bash
set -e
cd "$(dirname "$0")"

PROJECT_DIR="$(pwd)"
echo "🔧 编译 TypelessPlus ..."
echo "   项目目录: $PROJECT_DIR"

# 1. 创建输出目录
mkdir -p .build

# 2. 编译 Swift 可执行文件
swiftc -target arm64-apple-macos14.0 \
  -framework AppKit \
  -framework AVFoundation \
  -framework CoreGraphics \
  -framework Foundation \
  TypelessUI/TypelessApp.swift \
  TypelessUI/Constants.swift \
  TypelessUI/AudioRecorder.swift \
  TypelessUI/KeyboardEmulator.swift \
  TypelessUI/WhisperBridge.swift \
  TypelessUI/LLMBridge.swift \
  TypelessUI/GlobalHotkeyMonitor.swift \
  TypelessUI/OverlayWindow.swift \
  TypelessUI/SettingsView.swift \
  -o .build/TypelessPlus

echo "✅ 编译成功: .build/TypelessPlus"

# 3. 创建 .app bundle
APP_NAME="TypelessPlus.app"
APP_DIR=".build/$APP_NAME"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/Resources/TypelessAI"

# 复制可执行文件
cp .build/TypelessPlus "$APP_DIR/Contents/MacOS/"

# 复制 Info.plist
cp TypelessUI/Info.plist "$APP_DIR/Contents/"

# 复制 Python AI 服务
cp TypelessAI/server.py "$APP_DIR/Contents/Resources/TypelessAI/"

# 复制模型目录（软链接）
ln -s "$PROJECT_DIR/models" "$APP_DIR/Contents/Resources/models" 2>/dev/null || true

echo "✅ .app bundle 已创建: .build/$APP_NAME"
echo ""
echo "运行方式:"
echo "  open $APP_DIR"
echo "  或: ./run.sh"
