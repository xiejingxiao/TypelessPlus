# TypelessPlus 项目记忆

## 项目信息
- 类型: macOS 语音输入法，基于 Typeless 开源替代
- 技术栈: SwiftUI + Python (faster-whisper) + OpenAI 兼容 LLM API
- 位置: ~/Documents/实验资料/Project/TypelessPlus/
- 系统要求: macOS 14.0+, Apple Silicon

## Python 环境
- venv: ~/.workbuddy/binaries/python/envs/typelesspp/
- 关键依赖: faster-whisper, sounddevice, numpy
- ⚠️ 安装后必须 ad-hoc 签名所有 .so 和 python3 二进制（managed Python hardened runtime 限制）
- 签名命令: `find ~/.workbuddy/binaries/python/envs/typelesspp/lib -name "*.so" -exec codesign -s - -f {} \;` + `codesign -s - -f --deep ~/.workbuddy/binaries/python/envs/typelesspp/bin/python3`

## 构建方式
- SPM build 因中文路径 sandbox 问题不可用，改用 swiftc 直接编译
- `bash build.sh` 编译 + 生成 .app bundle
- `./run.sh` 启动（检查 Python venv + 打开 .app）

## LLM API
- 地址: http://127.0.0.1:8000/v1（OpenAI 兼容）
- 可用模型: DeepSeek-R1-Distill-Llama-70B-4bit 等
- 润色风格: clean/formal/casual/expand/compact
- Swift LLMBridge 是纯原生 HTTP 客户端，不依赖 Python
