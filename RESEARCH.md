# TypelessPlus 技术调研报告

## 1. whisper.cpp macOS 集成

**推荐方案**：Swift Package Manager + module.modulemap 直接集成 C whisper

```swift
// module.modulemap
module CWhisper {
    header "whisper.h"
    link "whisper"
    export *
}
```

参考：whisper.cpp 官方 `examples/whisper.swiftui` 示例，支持实时音频流转录，使用 5 秒滑动窗口 + 1 秒步进。

**模型推荐**：
- tiny (39MB) / base (74MB) / small (466MB)
- macOS Apple Silicon 上 small 模型实时推理延迟 < 500ms

## 2. 键盘模拟 (CGEventPost)

```swift
let src = CGEventSource(stateID: .privateState)
let event = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
event?.post(tap: .cghidEventTap)
```

关键：使用 `.privateState` 而非 `.hidSystemState`，确保模拟按键被目标应用接收。

## 3. 全局快捷键监听

macOS 上 Fn 键本身不产生标准 key event。推荐方案：
- 使用 `CGEvent.tapCreate` 监听 NX_SYSDEFINED 事件捕获 Fn 键
- 或使用 `NSEvent.addGlobalMonitorForEvents` + 自定义快捷键（如 Option+Space）
- 备选：使用 `MASShortcut` / `HotKey` 等第三方库

**推荐**：自定义快捷键（如 `Ctrl+Shift+Space`）触发录音，避免 Fn 键的兼容性问题。

## 4. 音频采集 (AVAudioEngine)

```swift
let engine = AVAudioEngine()
let inputNode = engine.inputNode
let format = inputNode.outputFormat(forBus: 0)
inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
    // 处理音频缓冲区 → 喂给 whisper
}
try engine.start()
```

44.1kHz/48kHz 采样率，16-bit PCM。

## 5. 简化架构结论

原 DESIGN.md 中 Rust 层可移除：
- macOS 原生 AVAudioEngine 已足够高效
- whisper.cpp 直接通过 C FFI 集成到 Swift，无需 Python 中转
- 文本后处理可用 Swift 原生实现或轻量 Python 子进程

**最终推荐栈**：
- SwiftUI (UI + 音频采集 + 键盘模拟)
- whisper.cpp C library (通过 SPM systemLibrary)
- Python 子进程 (可选，仅用于 LLM 后处理)