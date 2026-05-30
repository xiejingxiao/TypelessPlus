# TypelessPlus 开发状态

## v0.3.0 - 2026-05-30 重构版

### 架构重构（张一鸣视角诊断 → 三步走执行）

**Phase 0: 砍 — 删除空壳和死代码**
- ✅ 删除 TypelessCore/ 空目录（Rust 层 0 行代码）
- ✅ 删除 server_old.py, cli.py
- ✅ 删除 server.py 中 transcribe_raw, process, llm_rewrite, llm_status 死命令
- ✅ 删除 LocalPackages/swift-syntax（无关依赖）
- ✅ 删除 7 个过时测试文件（保留 E2ETestApp）
- ✅ 删除 SettingsView 中 6 项不生效 UI

**Phase 1: 收 — 统一实现、集中配置**
- ✅ 删除 Swift swiftTextProcess，文本处理统一到 Python TextProcessor
- ✅ 删除 Python LLMBridge，LLM 统一到 Swift LLMBridge（HTTP 直调）
- ✅ 新建 Constants.swift 集中管理 UserDefaults keys 和常量
- ✅ OverlayWindow 状态改 enum（不再靠字符串判断）
- ✅ GlobalHotkeyMonitor 移除 NSEvent 双保险，只用 CGEventTap listenOnly
- ✅ 更新 DESIGN.md 反映实际架构

**Phase 2: 固 — 测试验证**
- ✅ E2ETestApp 更新为 v4（匹配 listenOnly），3 项测试全部通过：
  - ✅ 正常按住 Ctrl+Shift 触发录音
  - ✅ 短暂按下 <100ms 不触发
  - ✅ Ctrl+Shift+Tab 防误触
- ✅ 主应用编译通过
- ✅ Python server.py IPC ping-pong 正常

### 编译状态
- Swift 二进制: `.build/TypelessPlus`
- Python 依赖: faster-whisper, sounddevice, numpy (venv: `~/.workbuddy/binaries/python/envs/typelesspp/`)
- .app Bundle: `.build/TypelessPlus.app` 构建成功

### 启动方式

```bash
cd "/Users/carylab/Documents/实验资料/Project/TypelessPlus"
./run.sh
# 或
open ".build/TypelessPlus.app"
```

### 首次使用需授权
- 麦克风权限（系统设置 → 隐私与安全性 → 麦克风）
- 辅助功能权限（系统设置 → 隐私与安全性 → 辅助功能）

### 快捷键
- Ctrl + Shift: 按住开始录音，松开停止
- settle 0.1s 防误触，防快捷键组合误触发

### 项目文件 (v0.3.0)
- `TypelessUI/` — 9 个 Swift 源文件（新增 Constants.swift）
- `TypelessAI/server.py` — Python AI 服务（精简：WhisperTranscriber + TextProcessor + IPCServer）
- `Tests/E2ETestApp.swift` — 端到端热键测试（3 用例）
- `build.sh` / `run.sh` — 构建和启动脚本
- `DESIGN.md` — 更新为实际架构
