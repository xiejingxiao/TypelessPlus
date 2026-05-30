# TypelessPlus 开发与调试总结报告

> 项目路径：`/Users/carylab/Documents/实验资料/Project/TypelessPlus`
> 审核日期：2026-05-30
> 审核架构：三人协同（秘书 → 专家 → 评审）

---

## 一、项目概述

TypelessPlus 是一款完全离线的 macOS 本地语音输入工具。通过全局快捷键 `Ctrl+Shift` 触发录音，利用 faster-whisper 进行语音识别，再由 Python AI 模块进行文本处理，最后将处理后的文本通过模拟键盘输入输出到当前应用中。

### 技术栈

| 模块 | 技术 | 职责 |
|------|------|------|
| **TypelessUI** | SwiftUI (macOS 14.0+) | UI、录音、键盘模拟、IPC通信 |
| **TypelessAI** | Python 3 + faster-whisper | 语音识别、文本后处理（繁→简、去填充词等） |

### 核心架构

```
用户按 Ctrl+Shift
    ↓
AudioRecorder 录音 → WAV 文件
    ↓
WhisperBridge (stdin/stdout JSON IPC)
    ↓
server.py (Python 子进程)
    ├── faster-whisper 语音识别
    ├── TextProcessor 后处理
    │   ├── opencc 繁→简
    │   ├── 去填充词
    │   ├── 去重复
    │   └── 标点恢复
    └── 返回 JSON 结果
    ↓
KeyboardEmulator 模拟键盘输入到当前应用
```

---

## 二、发现的问题清单与修复方案

### 🔴 严重问题（阻断交付）

#### 问题 1：requirements.txt 为空

- **文件**：[TypelessAI/requirements.txt](TypelessAI/requirements.txt)
- **现象**：Python 依赖未声明，无法安装
- **修复**：添加 `faster-whisper>=1.0.0` 和 `opencc-python-reimplemented>=0.1.7`

#### 问题 2：模型下载脚本格式错误

- **文件**：[scripts/install_models.sh](scripts/install_models.sh)
- **现象**：原脚本下载 ggml 格式模型（给 whisper.cpp 用），但 server.py 使用 faster-whisper（需要 CTranslate2 格式），格式不兼容
- **修复**：重写为通过 Python faster-whisper 自动下载 CTranslate2 格式模型

#### 问题 3：构建脚本使用废弃 API

- **文件**：[scripts/build.sh](scripts/build.sh)
- **现象**：`swift package generate-xcodeproj` 在 Swift 5.9 已移除
- **修复**：重写为 swiftc 直接编译 + 自动依赖检查 + .app bundle 生成 + ad-hoc 签名

#### 问题 4：版本号不一致

- **文件**：[Info.plist](TypelessUI/Info.plist) vs [Constants.swift](TypelessUI/Constants.swift)
- **现象**：Info.plist 写 v0.2.0，Constants 写 v0.3.0
- **修复**：统一为 v0.3.0（build 号 3）

#### 问题 5：Bundle ID 不一致

- **文件**：[Info.plist](TypelessUI/Info.plist) vs [Constants.swift](TypelessUI/Constants.swift)
- **现象**：`com.typeless.plusplus` vs `com.typeless.app`
- **修复**：统一为 `com.typeless.plusplus`

#### 问题 6：KeyboardEmulator 特殊字符映射错误

- **文件**：[KeyboardEmulator.swift](TypelessUI/KeyboardEmulator.swift)
- **现象**："!" 和 "?" 映射到了错误的 keyCode
- **修复**：移除错误的映射，让其走粘贴板备选路径

---

### 🟡 中等问题

| # | 问题 | 文件 | 修复 |
|---|------|------|------|
| 7 | server.py 模型重复加载（run() 和 init 都加载） | [server.py](TypelessAI/server.py) | 移除 run() 中的预加载 |
| 8 | 中文去重复正则无效（\b 对中文无效） | [server.py](TypelessAI/server.py) | 新增 REPEAT_PATTERN_ZH 正则 |
| 9 | Python stderr 被丢弃 | [WhisperBridge.swift](TypelessUI/WhisperBridge.swift) | 改为 Pipe + readabilityHandler 输出 |
| 10 | E2E 测试未集成到构建系统 | [Package.swift](Package.swift) | 添加 testTarget |
| 11 | 缺少 .gitignore | 项目根目录 | 新建 .gitignore |

---

### 🟠 运行时问题（调试过程中发现并修复）

#### 问题 A：进程被 SIGKILL（Exit Code 137）

- **根因**：macOS 要求使用 CGEventTap 等 API 的应用必须有代码签名。未签名的 app 被 macOS 安全机制直接杀掉
- **修复**：构建流程末尾添加 `codesign --force --deep -s -`（ad-hoc 签名）
- **教训**：任何使用 CoreGraphics Event Tap / Accessibility API 的 macOS app 都必须签名

#### 问题 B：`open` 命令启动了旧版 Typeless.app

- **根因**：系统中已安装 `/Applications/Typeless.app`（旧版），`open TypelessPlus.app` 被 Launch Services 解析到了旧版
- **修复**：改用直接运行二进制 `.build/TypelessPlus.app/Contents/MacOS/TypelessPlus`
- **教训**：开发阶段应直接运行二进制而非通过 open，避免 Launch Services 缓存干扰

#### 问题 C：环境变量被清空导致 Python 进程异常

- **根因**：`process.environment = ["PYTHONUNBUFFERED": "1", ...]` 使用赋值语法**替换**了整个环境变量字典，Python 子进程拿不到 PATH/DYLD_LIBRARY_PATH 等
- **修复**：
  ```swift
  // 错误 ❌
  proc.environment = ["KEY": "value"]
  
  // 正确 ✅
  var env = ProcessInfo.processInfo.environment
  env["KEY"] = "value"
  proc.environment = env
  ```
- **教训**：Swift 的 Process.environment 是完整替换而非合并

#### 问题 D：workbuddy venv Python 代码签名冲突

- **根因**：workbuddy 安装的 faster-whisper 依赖 PyAV/FFmpeg 原生库，其 .so 文件的代码签名 Team ID 与从 Swift 子进程启动的 Python 不匹配，macOS 拒绝加载
- **修复**：
  1. 新增 `validatePython()` 方法，启动前实际测试 `import faster_whisper`
  2. 调整路径优先级：`/usr/bin/python3`（系统Python）排在最前面
  3. 自动跳过有问题的 Python 环境
- **教训**：venv 环境的原生库可能有签名问题，系统 Python 最稳定

#### 问题 E：WhisperBridge 初始化时序 Bug（"Not initialized"）

- **根因**：`isInitialized = true` 在 Python 进程启动后立即设置，但 init 命令的回调不管响应内容都调 `completion(true)`
- **修复**：改为 `isReady` 模式 — 只在收到 Python 返回 `{"status":"ok"}` 后才标记就绪
- **教训**：异步初始化必须以远端响应为准，不能以本地状态为准

#### 问题 F：错误悬浮窗无法消失

- **根因**：`appState == .idle` 时 `updateUI()` 中是空操作（`break`），不调用 `overlayWindow?.hide()`
- **修复**：改为 `overlayWindow?.hide()`
- **教训**：状态机每个分支都必须有完整的 UI 更新逻辑

#### 问题 G：悬浮窗不置顶

- **根因**：`window.level = .floating` 级别不够高，被其他应用窗口覆盖
- **修复**：
  ```swift
  window.level = .screenSaver              // 最高正常窗口层级
  window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
  ```

#### 问题 H：输出繁体字

- **根因**：TextProcessor.process() 完全没有繁体→简体转换步骤。faster-whisper 默认可能输出繁体中文
- **修复**：新增 opencc 库，在文本处理第一步执行 `to_simplified()` 转换

#### 问题 I：识别准确率低 / VAD 参数不兼容

- **根因**：
  1. beam_size=5 偏小
  2. 无中文 initial_prompt 引导
  3. vad_parameters 中使用了 `max_silence_duration_ms`，但 faster-whisper 1.2.1 不支持此参数
- **修复**：
  - beam_size → 10
  - 添加 initial_prompt="以下是普通话的句子。请用简体中文输出。"
  - 移除不兼容的 VAD 参数，只保留 `min_silence_duration_ms`
  - 检测到中文后强制 language="zh" 二次识别

---

## 三、调试方法论总结

### 3.1 排查 "Not initialized" 类错误的流程图

```
报错 "Not initialized"
    ↓
① 检查 Python 进程是否存活？（pgrep python3）
    ├─ 不存活 → 查看进程为什么崩溃（SIGKILL? 签名问题?）
    └─ 存活 ↓
② 手动测试 Python IPC 是否正常？
    echo '{"command":"init","model":"base"}' | python3 server.py
    ├─ 返回 error → Python 端问题（模型加载？依赖？参数？）
    └─ 返回 ok ↓
③ 检查 Swift 端 isReady 标志位设置时机？
    ├─ 在 sendCommand 之前设置 → 时序 bug ✅
    └─ 在 response 回调中根据 status 判断 → 正确
```

### 3.2 GUI App 日志调试技巧

macOS GUI 应用在后台运行时 `print()` 不会输出到终端 stdout。解决方案：

```swift
// 方案：写入缓存目录日志文件
private func log(_ message: String) {
    print(message)  // 终端（前台模式有效）
    
    let logPath = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask).first!
        .appendingPathComponent("typeless_debug.log").path
    
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write("\(ISO8601DateFormatter().string(from: Date())) \(message)\n".data(using: .utf8)!)
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: message.data(using: .utf8))
    }
}
```

查看日志：`cat ~/Library/Caches/typeless_debug.log`

### 3.3 Python IPC 快速测试脚本

```python
#!/usr/bin/env python3
"""快速测试 server.py IPC 通信"""
import subprocess, json, os, sys, time

os.environ['HF_ENDPOINT'] = 'https://hf-mirror.com'

proc = subprocess.Popen(
    [sys.executable, 'TypelessAI/server.py'],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE,
    stderr=subprocess.PIPE, text=True,
    env={**os.environ, 'PYTHONUNBUFFERED': '1'}
)

def send(cmd):
    proc.stdin.write(json.dumps(cmd) + '\n')
    proc.stdin.flush()
    line = proc.stdout.readline().strip()
    return json.loads(line)

time.sleep(3)
print("Init:", send({"command": "init", "model": "base"}))
print("Ping:", send({"command": "ping"}))

proc.terminate()
```

### 3.4 faster-whisper 版本兼容性检查

不同版本的 faster-whisper 支持的 VAD 参数不同：

```python
# 检查已安装版本
import faster_whisper
print(faster_whisper.__version__)

# 检查支持的 VAD 参数
from faster_whisper.vad import VadOptions
import inspect
for name, param in inspect.signature(VadOptions).parameters.items():
    if name != 'self':
        print(f'  {name}: default={param.default}')
```

**faster-whisper 1.2.1 支持的 VAD 参数**：

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| threshold | float | 0.5 | 语音检测阈值 |
| min_speech_duration_ms | int | 0 | 最短语音时长(ms) |
| max_speech_duration_s | float | inf | 最长语音时长(s) |
| min_silence_duration_ms | int | 2000 | 最短静音时长(ms) |
| speech_pad_ms | int | 400 | 语音前后填充(ms) |

⚠️ **不要使用 `max_silence_duration_ms`**，这个参数在某些版本不存在。

---

## 四、修改文件清单

| 文件 | 修改类型 | 主要变更 |
|------|----------|----------|
| [TypelessAI/server.py](TypelessAI/server.py) | 重写 | 繁→简转换、准确率优化、VAD参数修正、移除重复初始化 |
| [TypelessAI/requirements.txt](TypelessAI/requirements.txt) | 重写 | 添加 faster-whisper + opencc 依赖 |
| [TypelessUI/WhisperBridge.swift](TypelessUI/WhisperBridge.swift) | 重写 | 环境变量修复、isReady时序、validatePython健康检查、stderr可调试 |
| [TypelessUI/OverlayWindow.swift](TypelessUI/OverlayWindow.swift) | 修改 | 窗口层级升级为 screenSaver + fullScreenAuxiliary |
| [TypelessUI/TypelessApp.swift](TypelessUI/TypelessApp.swift) | 修改 | activation policy、idle隐藏悬浮窗、调试日志 |
| [TypelessUI/KeyboardEmulator.swift](TypelessUI/KeyboardEmulator.swift) | 修改 | 特殊字符映射修复 |
| [TypelessUI/Info.plist](TypelessUI/Info.plist) | 修改 | 版本号 v0.3.0 |
| [TypelessUI/Constants.swift](TypelessUI/Constants.swift) | 修改 | Bundle ID 统一 |
| [scripts/build.sh](scripts/build.sh) | 重写 | swiftc直接编译 + 依赖检查 + 签名 |
| [scripts/install_models.sh](scripts/install_models.sh) | 重写 | faster-whisper 格式模型下载 |
| [Package.swift](Package.swift) | 修改 | 添加 E2E 测试 target |
| [README.md](README.md) | 修正 | 更新文档反映真实技术栈 |
| [.gitignore](.gitignore) | 新建 | 排除 build产物和模型文件 |

---

## 五、构建与运行指南

### 5.1 首次构建

```bash
cd /Users/carylab/Documents/实验资料/Project/TypelessPlus

# 1. 安装 Python 依赖
/usr/bin/python3 -m pip install -r TypelessAI/requirements.txt

# 2. 下载模型（可选，首次运行会自动下载）
bash scripts/install_models.sh

# 3. 构建
bash scripts/build.sh
```

### 5.2 启动（重要！不要用 open）

```bash
# ✅ 正确方式：直接运行二进制
./.build/TypelessPlus.app/Contents/MacOS/TypelessPlus

# ❌ 错误方式：可能启动旧版 Typeless.app
# open .build/TypelessPlus.app
```

### 5.3 系统权限要求

| 权限 | 用途 | 设置路径 |
|------|------|----------|
| 辅助功能 | 监听全局快捷键 Ctrl+Shift | 系统设置 → 隐私与安全性 → 辅助功能 |
| 麦克风 | 录制语音输入 | 系统设置 → 隐私与安全性 → 麦克风 |

### 5.4 使用方法

1. 打开任意文本编辑器（备忘录、TextEdit、浏览器等）
2. **按住** `Ctrl + Shift` → 屏幕上方出现悬浮窗"正在聆听..."
3. 说话
4. **松开**按键 → 显示"识别中..." → 识别结果 → 自动输入到编辑器

### 5.5 查看调试日志

```bash
cat ~/Library/Caches/typeless_debug.log
```

---

## 六、经验教训与最佳实践

### macOS 开发注意事项

1. **CGEventTap 必须签名** — 未签名的 app 使用 CoreGraphics Event Tap 会被 SIGKILL
2. **Process.environment 是替换不是合并** — 必须先读取 ProcessInfo.processInfo.environment 再修改
3. **GUI app 的 print() 不输出到终端** — 需要写文件日志或使用 OSLog
4. **open 命令受 Launch Services 缓存影响** — 开发阶段直接运行二进制更可靠
5. **venv 的原生库可能有签名问题** — 系统 Python (`/usr/bin/python3`) 最稳定

### faster-whisper 使用注意事项

1. **版本差异大** — 不同版本的 VAD 参数、API 签名都可能不同，务必用 `inspect.signature()` 检查
2. **beam_size 越大越准确但越慢** — base 模型建议 5~10
3. **initial_prompt 能显著提升中文准确率** — 尤其是"请用简体中文输出"这类引导
4. **temperature=0.0 减少幻觉** — 适合短语音输入场景

### Swift + Python IPC 注意事项

1. **stdin/stdout JSON 协议要加换行符** — `\n` 作为消息分隔符
2. **PYTHONUNBUFFERED=1 必须设置** — 否则 Python 输出会被缓冲导致死锁
3. **子进程 stderr 要单独处理** — 用 Pipe + readabilityHandler 实时获取
4. **异步初始化要以远端响应为准** — 不要在发送命令后就假设成功