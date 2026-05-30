# TypelessPlus 架构设计 (v0.3.0)

## 1. 项目定位

TypelessPlus 是 Typeless 的开源替代品，核心差异：
- **完全本地化**：语音识别 + AI 后处理全部本地运行，零网络依赖
- **开源可控**：MIT License，社区驱动
- **极简交互**：Ctrl+Shift 按住录音 → 松开即输出

## 2. 实际架构

```
┌─────────────────────────────────────────────┐
│               TypelessPlus (Swift)            │
├──────────┬──────────┬──────────┬────────────┤
│  UI 层   │  热键层   │  AI 层   │  输出层    │
│ SwiftUI  │ CGEventTap│ Python  │  AppKit    │
├──────────┼──────────┼──────────┼────────────┤
│菜单栏图标│ Push-to- │ Whisper  │ 键盘模拟   │
│悬浮预览窗│  Talk    │ TextProc │ 剪贴板粘贴 │
│设置面板  │ settle   │          │            │
│Constants │ 防误触   │          │            │
└──────────┴──────────┴──────────┴────────────┘
        │                │              │
        │    stdin/stdout JSON IPC      │
        │                │              │
        └──────┐    ┌────┘    ┌─────────┘
               │    │         │
         ┌─────▼────▼─────────▼─────┐
         │   Swift LLMBridge (HTTP) │
         │   OpenAI 兼容 API        │
         └──────────────────────────┘
```

### 技术选型

| 组件 | 技术 | 理由 |
|------|------|------|
| UI 框架 | SwiftUI + AppKit | macOS 原生，菜单栏模式 |
| 热键监听 | CGEventTap (.listenOnly) | 全局修饰键监听，Push-to-Talk |
| 语音识别 | faster-whisper (Python 子进程) | CTranslate2 后端，本地推理 |
| 文本后处理 | Python TextProcessor | 统一实现，去填充词/重复/标点 |
| LLM 润色 | Swift LLMBridge (HTTP) | 直接调 OpenAI 兼容 API |
| 进程通信 | stdin/stdout JSON | 简单可靠，Python 子进程 |
| 音频采集 | AVAudioEngine | macOS 原生，降采样到 16kHz |

### 数据流

```
按住 Ctrl+Shift → settle 0.1s → 开始录音
    → AVAudioEngine 采集 → 降采样 16kHz PCM
    → 松开 → 写临时 WAV → Python faster-whisper 转录
    → Python TextProcessor 后处理
    → (可选) Swift LLMBridge HTTP 调用润色
    → 悬浮窗预览 → 键盘模拟/剪贴板输入
```

## 3. 项目结构

```
TypelessPlus/
├── TypelessUI/              # Swift 主应用 (9 个文件)
│   ├── TypelessApp.swift    # 入口 + AppDelegate + AppState
│   ├── Constants.swift      # UserDefaults keys + 常量
│   ├── GlobalHotkeyMonitor.swift  # Push-to-Talk 热键 (listenOnly)
│   ├── AudioRecorder.swift  # AVAudioEngine 录音
│   ├── WhisperBridge.swift  # Python 子进程 IPC
│   ├── LLMBridge.swift      # OpenAI 兼容 HTTP 客户端
│   ├── OverlayWindow.swift  # 悬浮预览窗 + AppState enum
│   ├── KeyboardEmulator.swift   # 键盘模拟/剪贴板粘贴
│   ├── SettingsView.swift   # 设置面板 (通用/AI助手/关于)
│   └── Info.plist           # 权限声明
├── TypelessAI/              # Python AI 服务
│   ├── server.py            # IPCServer + WhisperTranscriber + TextProcessor
│   └── requirements.txt     # faster-whisper, sounddevice, numpy
├── LocalPackages/           # SPM 本地依赖 (KeyboardShortcuts, Defaults)
├── Tests/                   # E2E 测试
│   └── E2ETestApp.swift     # 自动化热键测试 (3 用例)
├── models/                  # Whisper 模型文件
├── scripts/                 # 构建和模型下载脚本
├── build.sh                 # swiftc 直接编译 → .app bundle
└── run.sh                   # 启动脚本
```

## 4. 功能状态

### 已实现 (v0.3.0)

| 功能 | 实现 | 说明 |
|------|------|------|
| Push-to-Talk | Ctrl+Shift | settle 0.1s 防误触，listenOnly |
| 语音识别 | faster-whisper | base 模型，支持 tiny/base/small/medium |
| 文本后处理 | Python TextProcessor | 去填充词、去重复、加标点 |
| LLM 润色 | Swift LLMBridge | 5 种风格，OpenAI 兼容 API |
| LLM 降级 | 自动 | LLM 不可用 → 直接使用 Python 处理后文本 |
| 悬浮预览窗 | OverlayWindow | AppState enum 状态，波形动画 |
| 键盘输出 | KeyboardEmulator | 中文走剪贴板，ASCII 短文本逐字符 |
| 菜单栏 | NSStatusItem | LLM 开关、润色风格、设置入口 |
| 设置面板 | SettingsView | 通用/AI助手/关于 3 个 Tab |

### 未实现（后续迭代）

| 功能 | 优先级 | 说明 |
|------|--------|------|
| 快捷键自定义 | P1 | 需要集成 KeyboardShortcuts 库 |
| 开机自启 | P1 | 需要 ServiceManagement |
| 模型热切换 | P2 | 当前需重启 |
| 个人词典 | P2 | |
| 流式识别 | P2 | 边说边出字 |
| 剪贴板备选输出 | P2 | |
| 悬浮窗可编辑 | P3 | |
| 应用感知 | P3 | |

## 5. 开发约束

- 所有 AI 组件必须在本地运行，不依赖云端 API（LLM 除外，由用户配置本地服务）
- macOS 14.0+ 最低系统要求
- Apple Silicon (ARM64) 优先支持
- Python venv 路径可配置（UserDefaults `pythonPath`）
