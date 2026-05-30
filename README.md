# TypelessPlus

> 完全离线的 macOS 本地语音识别工具  
> Speak naturally. Type effortlessly. Zero cloud.

## 功能

| 功能 | 状态 | 说明 |
|------|------|------|
| 全局快捷键触发 | ✅ 已实现 | Ctrl+Shift+Space，可配置 |
| 实时录音 | ✅ 已实现 | AVAudioEngine，降采样 16kHz |
| whisper.cpp 识别 | ✅ 已实现 | faster-whisper (CTranslate2)，Base 模型，内存约 1GB |
| AI 后处理 | ✅ 已实现 | 去填充词、去重复、标点恢复 |
| 模拟键盘输出 | ✅ 已实现 | CGEventPost + 剪贴板粘贴 |
| 菜单栏驻留 | ✅ 已实现 | LSUIElement，无 Dock 图标 |
| 悬浮预览窗 | ✅ 已实现 | 毛玻璃效果，显示识别文本 |
| 100+ 语言支持 | ✅ | whisper 多语言模型 |
| 个人词典 | 🔜 待开发 | 自定义热词替换 |
| 写作辅助 | 🔜 待开发 | 段落润色、格式优化 |

## 架构

```
┌─────────────────────────────────────────────┐
│                  TypelessPlus                 │
│                                             │
│  ┌─────────────┐  ┌──────────────────────┐  │
│  │  SwiftUI App │──▶  Python AI Service   │  │
│  │             │  │  (stdin/stdout IPC)   │  │
│  │  - Audio    │  │                      │  │
│  │  - Hotkeys  │  │  - faster-whisper    │  │
│  │  - Overlay  │  │  - Text Processing   │  │
│  │  - Output   │  │  - Fillers Removal   │  │
│  └─────────────┘  └──────────────────────┘  │
│                                             │
│  全部本地运行 · 零网络 · macOS 14.0+        │
└─────────────────────────────────────────────┘
```

## 快速开始

```bash
# 1. 安装 Python 依赖并下载模型
bash scripts/install_models.sh

# 2. 构建应用
bash scripts/build.sh

# 3. 打开 TypelessPlus.app
open .build/TypelessPlus.app
```

## 项目结构

```
TypelessPlus/
├── TypelessUI/           # SwiftUI 主应用
│   ├── TypelessApp.swift           # 入口 + 菜单栏
│   ├── AudioRecorder.swift         # 音频采集
│   ├── KeyboardEmulator.swift      # 键盘模拟
│   ├── WhisperBridge.swift         # AI 服务通信
│   ├── GlobalHotkeyMonitor.swift   # 快捷键监听
│   ├── OverlayWindow.swift         # 悬浮预览窗
│   ├── SettingsView.swift          # 设置面板
│   └── Info.plist                  # 应用配置
├── TypelessAI/           # Python AI 服务
│   ├── server.py                   # faster-whisper 封装 + 文本处理
│   └── requirements.txt            # Python 依赖
├── TypelessCore/         # (预留，无 Rust)
├── scripts/              # 工具脚本
│   ├── build.sh                    # 构建脚本
│   └── install_models.sh           # 模型下载（faster-whisper CTranslate2 格式）
├── models/               # Whisper 模型文件
├── DESIGN.md             # 功能设计文档
├── RESEARCH.md           # 技术调研报告
├── Package.swift         # SPM 项目定义
└── README.md             # 本文档
```

## 技术栈

- **UI**: SwiftUI 5.9+ (macOS 14.0+)
- **音频**: AVAudioEngine (原生)
- **识别**: faster-whisper (CTranslate2，通过 Python 子进程调用)
- **键盘**: CoreGraphics CGEventPost
- **快捷键**: CoreGraphics Event Tap
- **AI 服务**: Python 3, stdin/stdout JSON IPC

## 许可

MIT License