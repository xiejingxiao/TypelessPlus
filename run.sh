#!/bin/bash
set -e
cd "$(dirname "$0")"

PROJECT_DIR="$(pwd)"
APP_PATH=".build/TypelessPlus.app"

# Python 环境（优先使用项目 venv）
PYTHON_VENV="/Users/carylab/.workbuddy/binaries/python/envs/typelesspp/bin/python3"
PYTHON_SYSTEM="/usr/bin/python3"

if [ -x "$PYTHON_VENV" ]; then
    export PYTHON="$PYTHON_VENV"
    echo "🐍 使用 venv Python: $PYTHON_VENV"
else
    export PYTHON="$PYTHON_SYSTEM"
    echo "🐍 使用系统 Python: $PYTHON_SYSTEM (faster-whisper 可能未安装)"
fi

export HF_ENDPOINT="https://hf-mirror.com"

# 检查是否需要编译
if [ ! -f "$APP_PATH/Contents/MacOS/TypelessPlus" ]; then
    echo "🔧 首次运行，编译中..."
    bash build.sh
fi

# 检查辅助功能权限
echo "⚠️  首次使用请在系统设置中授权："
echo "   - 隐私与安全性 → 麦克风"
echo "   - 隐私与安全性 → 辅助功能"
echo ""

# 启动应用
echo "🚀 启动 TypelessPlus..."
open "$APP_PATH"
