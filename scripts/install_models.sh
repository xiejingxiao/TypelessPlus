#!/bin/bash
# TypelessPlus 模型下载脚本
# 通过 Python faster-whisper 自动下载 CTranslate2 格式模型

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
MODELS_DIR="$PROJECT_DIR/models"

mkdir -p "$MODELS_DIR"

echo ">>> 开始下载 Whisper 模型（faster-whisper / CTranslate2 格式）"

# 查找 Python 解释器
PYTHON=""
for candidate in "$PROJECT_DIR/.venv/bin/python3" "/usr/local/bin/python3" "/usr/bin/python3"; do
    if [ -x "$candidate" ]; then
        PYTHON="$candidate"
        break
    fi
done

if [ -z "$PYTHON" ]; then
    echo "[错误] 未找到 Python3，请先安装 Python3"
    exit 1
fi

echo "  使用 Python: $PYTHON"

# 安装 faster-whisper（如果未安装）
if ! "$PYTHON" -c "import faster_whisper" 2>/dev/null; then
    echo "  安装 faster-whisper..."
    "$PYTHON" -m pip install faster-whisper
fi

# 使用 Python 预下载 base 模型（faster-whisper 会自动缓存到 HuggingFace hub）
echo "  预下载 base 模型..."
"$PYTHON" -c "
import os
os.environ['HF_ENDPOINT'] = 'https://hf-mirror.com'
from faster_whisper import WhisperModel
print('  下载中...')
model = WhisperModel('base', device='cpu', compute_type='int8', download_root='$MODELS_DIR')
print('  base 模型下载完成')
"

# 可选：预下载其他尺寸模型
echo ""
echo ">>> base 模型下载完成"
echo ">>> 如需其他模型（tiny/small/medium），请在设置中切换后重启应用，模型将自动下载"
ls -lh "$MODELS_DIR" 2>/dev/null || echo "  (模型存储在 HuggingFace cache 中)"