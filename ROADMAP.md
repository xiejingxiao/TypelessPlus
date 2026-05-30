# TypelessPlus 项目复盘与迭代路线图

> **三人协同架构** — 秘书(全局梳理) × 专家(多维评估) × 评审(路线规划)
> 
> 项目版本：v0.3.0 | 复盘日期：2026-05-30
> 
> 代码仓库：`/Users/carylab/Documents/实验资料/Project/TypelessPlus`

---

## 第一部分：功能完成度全景（秘书视角）

### 1.1 已交付功能矩阵

| # | 功能模块 | 文件 | 完成度 | 当前状态 |
|---|---------|------|--------|----------|
| 1 | **Push-to-Talk 快捷键** | [GlobalHotkeyMonitor.swift](TypelessUI/GlobalHotkeyMonitor.swift) | ✅ 100% | Ctrl+Shift 按住录音，settle 0.1s 防误触，listenOnly 模式 |
| 2 | **音频采集** | [AudioRecorder.swift](TypelessUI/AudioRecorder.swift) | ✅ 100% | AVAudioEngine → 16kHz PCM → WAV 写入临时文件 |
| 3 | **语音识别** | [server.py:WhisperTranscriber](TypelessAI/server.py#L108-L172) | ✅ 100% | faster-whisper CTranslate2 后端，支持 tiny/base/small/medium 四档模型 |
| 4 | **文本后处理** | [server.py:TextProcessor](TypelessAI/server.py#L51-L105) | ✅ 95% | 去填充词 ✓ 去重复 ✓ 标点恢复 ✓ 繁→简转换 ✓ |
| 5 | **悬浮预览窗** | [OverlayWindow.swift](TypelessUI/OverlayWindow.swift) | ✅ 100% | screenSaver 级置顶，AppState 状态机，波形动画 |
| 6 | **键盘模拟输出** | [KeyboardEmulator.swift](TypelessUI/KeyboardEmulator.swift) | ✅ 85% | ASCII 逐字符 + 中文剪贴板粘贴双模式 |
| 7 | **Swift↔Python IPC** | [WhisperBridge.swift](TypelessUI/WhisperBridge.swift) | ✅ 90% | stdin/stdout JSON 协议，isReady 时序正确，validatePython 健康检查 |
| 8 | **LLM 润色** | [LLMBridge.swift](TypelessUI/LLMBridge.swift) | ⚠️ 60% | API 客户端完整（5种风格），但**主流程未接入** |
| 9 | **设置面板** | [SettingsView.swift](TypelessUI/SettingsView.swift) | ✅ 85% | 3个Tab（通用/AI助手/关于），LLM 连接检测可用 |
| 10 | **菜单栏集成** | [TypelessApp.swift](TypelessUI/TypelessApp.swift) | ✅ 80% | NSStatusItem 图标，偏好设置入口，activation policy 正确 |

### 1.2 功能完成度总评

```
核心链路完整性：██████████ 10/10
  (录音 → 识别 → 后处理 → 输出 全链路打通)

用户体验完整性：███████░░░ 7/10
  (缺少快捷键自定义、开机自启、模型热切换)

高级功能完整性：████░░░░░░ 4/10
  (LLM润色框架在但未接入主流程、无流式识别、无个人词典)
```

**一句话总结**：核心语音输入链路已完全跑通并验证可用，但"好用"的周边能力还有较大迭代空间。

---

## 第二部分：代码质量与架构评审（专家视角）

### 2.1 架构健康度

| 维度 | 评分 | 分析 |
|------|------|------|
| **模块解耦** | ★★★★☆ | Swift UI 层 / Python AI 层 / IPC 层 三层分离清晰。LLMBridge 通过 HTTP 解耦更优 |
| **状态管理** | ★★★☆☆ | AppState enum 设计良好，但 TypelessApp.swift 中状态散落在多处，建议引入统一 Store |
| **错误处理** | ★★★★☆ | WhisperError / LLMBridgeError 分类清晰，但部分错误只显示不重试（如 Python 进程崩溃后无自动重启） |
| **可测试性** | ★★☆☆☆ | E2E 测试文件存在但未自动化运行；单元测试为零；AudioRecorder/TextProcessor 无独立测试 |
| **配置管理** | ★★★☆☆ | UserDefaults 分散在各文件中，Constants.swift 集中定义了 key 但缺默认值校验 |

### 2.2 各模块详细评估

#### TypelessApp.swift（主入口）— 282 行

**优点**：
- AppDelegate + NSApplicationDelegateAdaptor 模式标准
- 录音→转录→输出的主流程清晰
- LLM 降级逻辑存在（LLM 不可用时跳过）

**问题**：
- `updateUI()` 方法过长（~60行），混合了状态判断和 UI 操作
- `handleTranscriptionResult()` 中 LLM 调用逻辑**被注释掉了**（第 ~200 行附近），导致 LLM 功能实际不可用
- 缺少应用生命周期管理（退出时未清理 Python 子进程）

#### AudioRecorder.swift — 161 行

**优点**：
- AVAudioEngine 使用规范
- 降采样到 16kHz 的实现正确
- 支持暂停/继续/停止的完整状态机

**问题**：
- 硬编码了采样率和格式参数
- 无音量级别反馈（用户不知道麦克风是否正常工作）
- 录音时长无上限保护（长时间误触会生成巨大 WAV）

#### KeyboardEmulator.swift — 125 行

**优点**：
- 双模式设计合理（ASCII 逐字 vs 中文剪贴板）
- CGEventPost 模拟真实按键

**问题**：
- 特殊字符映射表仍不完整（@, #, $, %, ^, &, *, (, ) 等缺失）
- 剪贴板模式会覆盖用户原有剪贴板内容（应先保存再恢复）
- 无输入速度控制（长文本瞬间输出可能触发输入限制）

#### WhisperBridge.swift — ~350 行

**优点**：
- isReady 时序修复后的初始化流程可靠
- validatePython() 健康检查避免启动有问题的环境
- stderr 可调试输出

**问题**：
- sendCommand() 中使用 Thread.sleep 做轮询（`readResponse()`），应改为 DispatchQueue 或 Combine 异步模式
- Python 进程崩溃后无自动重启机制
- 无连接超时和重试策略

#### server.py — 246 行

**优点**：
- TextProcessor 流水线清晰（繁→简 → 去填充词 → 去重复 → 标点）
- opencc 集成完善，fallback 到 zhconv
- 中文二次识别优化提升准确率

**问题**：
- 二次识别（中文强制 language="zh"）会使识别时间翻倍，对实时性要求高的场景不友好
- TextProcessor 的填充词列表太短（仅 9 个中文词）
- 无日志持久化（只有 stderr 输出，GUI 模式下看不到）
- 无性能指标采集（每次转录耗时、音频长度等）

#### LLMBridge.swift — 251 行

**优点**：
- 5 种润色风格的 system prompt 设计精良
- OpenAI 兼容 API 封装完整
- 健康检查和模型列表接口齐全

**问题**：
- **⚠️ 主流程未接入！** TypelessApp.swift 中的 LLM 调用被注释掉
- 无请求队列（连续快速输入可能产生竞态）
- 无超时取消机制（URLSession task 无法从外部 cancel）

### 2.3 技术债务清单

| # | 债务 | 影响 | 建议 |
|---|------|------|------|
| TD-1 | LLM 润色功能未接入主流程 | 用户无法使用 AI 增强 | P0：下版本必须接入 |
| TD-2 | 无自动化测试 | 回归风险高 | 补充单元测试 + CI |
| TD-3 | Python 进程无自动重启 | 服务异常后需手动重启 | 添加 watchdog 机制 |
| TD-4 | 剪贴板被覆盖 | 用户体验差 | 先保存→写入→恢复 |
| TD-5 | 配置分散 | 维护成本高 | 统一 Config 对象 |
| TD-6 | 无性能监控 | 无法量化优化效果 | 添加 metrics 上报 |

---

## 第三部分：迭代路线图（评审视角）

### 3.1 版本规划总览

```
v0.3.0 ──当前──→ v0.4.0 ──→ v0.5.0 ──→ v1.0.0 ──→ v1.x
  核心          完善         增强        成熟       扩展
  可用         好用         强大        稳定      生态
```

### 3.2 v0.4.0 — "稳定好用版"（建议优先级最高）

**目标**：修复已知缺陷，让日常使用体验流畅

| 任务 | 类型 | 工作量 | 说明 |
|------|------|--------|------|
| **P0: 接入 LLM 润色到主流程** | 功能 | 0.5d | 取消 TypelessApp.swift 中的注释，让 LLM rewrite 在 transcribe 之后、keyboard output 之前执行 |
| **P0: 剪贴板安全** | Bugfix | 0.25d | KeyboardEmulator 粘贴前保存原剪贴板，粘贴后恢复 |
| **P1: Python 进程看门狗** | 稳定性 | 0.5d | WhisperBridge 检测到 process.isRunning=false 时自动重新 initialize |
| **P1: 特殊字符映射补全** | Bugfix | 0.25d | 补全 @#$%^&*() 等常用特殊字符的 keyCode 映射 |
| **P1: 录音超时保护** | 稳定性 | 0.25d | AudioRecorder 添加最大录音时长（默认 120s），超时自动停止 |
| **P2: 麦克风音量指示** | UX | 0.5d | OverlayWindow 录音时显示实时音量条 |
| **P2: 错误自动重试** | 稳定性 | 0.25d | "Not initialized" / "服务进程未运行" 自动重试 1 次 |
| **P2: 日志面板** | Debug | 0.5d | 设置中添加"查看日志"按钮，打开 debug log 文件 |

### 3.3 v0.5.0 — "增强体验版"

**目标**：提升生产力，让工具真正融入工作流

| 任务 | 类型 | 工作量 | 说明 |
|------|------|--------|------|
| **P0: 快捷键自定义** | 功能 | 1d | 集成 LocalPackages/KeyboardShortcuts 库，支持用户自选组合键（已引入依赖但未使用！）|
| **P0: 开机自启** | 功能 | 0.5d | ServiceManagement SMLoginItemSetEnabled |
| **P1: 模型热切换** | 功能 | 1d | 设置中切换模型后无需重启，直接 re-initialize WhisperBridge |
| **P1: 多语言识别增强** | 功能 | 0.5d | 中英混合场景优化；日语/韩语基础支持 |
| **P1: 个人词典** | 功能 | 1d | 用户自定义词汇替换表（如 "typeless++" → "TypelessPlus"，专业术语纠错）|
| **P2: 输出历史记录** | 功能 | 1d | 最近 N 条识别结果可回看/重新编辑 |
| **P2: 应用感知输出** | 功能 | 1d | 检测当前焦点应用，自动适配格式（IDE→代码格式，聊天→纯文本）|
| **P2: 性能指标面板** | UX | 0.5d | 设置中显示平均识别延迟、模型加载时间等 |

### 3.4 v1.0.0 — "正式发布版"

**目标**：产品化，可以面向社区发布

| 任务 | 类型 | 工作量 | 说明 |
|------|------|--------|------|
| **P0: 自动化测试套件** | 质量 | 2d | 单元测试（TextProcessor/KeyboardEmulator）+ E2E 测试 + CI |
| **P0: DMG 安装包** | 发布 | 1d | 打包为 .dmg，包含签名+公证（notarization）|
| **P0: 完整文档** | 文档 | 1d | 用户手册 + FAQ + 故障排查指南 |
| **P1: 本地化** | i18n | 1d | 英文界面（SettingsView/OverlayWindow/菜单）|
| **P1: 暗色模式适配** | UX | 0.5d | OverlayWindow 和 SettingsView 适配系统外观 |
| **P1: 权限引导向导** | UX | 1d | 首次启动时引导用户授予辅助功能+麦克风权限 |
| **P2: 流式识别** | 功能 | 3d | 边说边出字（需要改造 WhisperBridge 为流式协议或使用 streaming API）|
| **P2: 插件系统** | 架构 | 3d | 允许用户编写自定义 TextProcessor 插件（Python 脚本）|

### 3.5 v1.x — 远期愿景

| 方向 | 说明 | 技术挑战 |
|------|------|----------|
| **多平台** | 移植到 Linux (X11/Wayland) + Windows (全局钩子) | 平台特定的热键/输入模拟 API |
| **端到端加密** | 敏感行业需求（医疗/法律） | 音频数据内存加密，不留磁盘 |
| **团队协作** | 会议纪要模式，多人说话者分离 | 说话人分离 diarization |
| **命令模式** | 语音触发特定操作（"打开终端"、"搜索 XXX"） | 自然语言理解 + 动作映射 |
| **离线 LLM 集成** | 内置小模型（如 Qwen2.5-1.5B）做本地润色 | MLX / llama.cpp 集成，内存占用权衡 |

---

## 第四部分：架构改进建议

### 4.1 推荐的短期重构（v0.4.0 同步进行）

```
当前架构的问题点：

TypelessApp.swift ← 太胖（282行，承担了太多职责）
    ├── 状态管理
    ├── UI 更新
    ├── 录音控制
    ├── 转录协调
    ├── LLM 协调
    └── 输出控制

建议拆分为：

TypelessApp.swift          ← 仅负责 App 生命周期 + 菜单栏
    │
    ├── RecordingCoordinator   ← 录音→转录→输出 的编排器
    │     ├── 管理 AppState 状态流转
    │     ├── 协调 WhisperBridge + LLMBridge + KeyboardEmulator
    │     └── 错误处理与重试
    │
    └── AppStore (Observable)  ← 集中的状态存储
          ├── appState: AppState
          ├── settings: AppSettings
          ├── history: [TranscriptionRecord]
          └── metrics: PerformanceMetrics
```

### 4.2 IPC 协议升级建议

当前 stdin/stdout JSON 协议是同步阻塞的（Swift 端用 Thread.sleep 轮询）。未来建议：

```json
// 当前协议（同步请求-响应）
{"command": "transcribe", "audio_path": "/tmp/xxx.wav", "language": "auto"}
→ {"status": "ok", "text": "识别结果"}

// 建议升级为（异步事件驱动）
// 请求
{"id": "req_001", "command": "transcribe", "audio_path": "/tmp/xxx.wav"}
// 事件流
{"event": "progress", "req_id": "req_001", "stage": "loading_model"}
{"event": "progress", "req_id": "req_001", "stage": "transcribing", "percent": 45}
{"event": "result", "req_id": "req_001", "status": "ok", "text": "..."}
```

这样可以支持进度条显示和真正的异步非阻塞通信。

---

## 第五部分：关键决策记录（ADR）

| # | 决策 | 选择 | 理由 | 备注 |
|---|------|------|------|------|
| ADR-01 | 语音引擎 | faster-whisper (CTranslate2) | 比 whisper.cpp 更好的中文支持；比 OpenAI Whisper API 完全离线 | base 模型约 150MB RAM |
| ADR-02 | IPC 方式 | stdin/stdout JSON | 最简单可靠；Python 作为子进程生命周期由 Swift 管理 | 未来可升级为 Unix Socket / gRPC |
| ADR-03 | 编译方式 | swiftc 直接编译 | 避免 Xcode 依赖；SPM 的 generate-xcodeproj 已废弃 | build.sh 一键构建 |
| ADR-04 | 窗口层级 | .screenSaver | 必须覆盖全屏应用（演示、视频等） | macOS 最高正常窗口级别 |
| ADR-05 | Python 环境 | 系统 /usr/bin/python3 | venv 有原生库签名冲突问题 | validatePython() 自动选择 |
| ADR-06 | 启动方式 | 直接运行二进制 | 避免 Launch Services 缓存干扰旧版 app | 开发阶段策略 |

---

## 附录：文件修改速查索引

| 文件 | 行数 | 职责 | 本次迭代改动重点 |
|------|------|------|------------------|
| [TypelessApp.swift](TypelessUI/TypelessApp.swift) | ~297 | 入口+主流程 | activation policy + idle hide + debug log |
| [AudioRecorder.swift](TypelessUI/AudioRecorder.swift) | ~161 | 音频采集 | 无改动（待加超时保护） |
| [KeyboardEmulator.swift](TypelessUI/KeyboardEmulator.swift) | ~125 | 键盘输出 | 特殊字符映射修复（待加剪贴板安全） |
| [WhisperBridge.swift](TypelessUI/WhisperBridge.swift) | ~353 | Python IPC | 环境变量修复 + isReady时序 + validatePython |
| [LLMBridge.swift](TypelessUI/LLMBridge.swift) | ~251 | LLM HTTP | 完整实现（待接入主流程） |
| [GlobalHotkeyMonitor.swift](TypelessUI/GlobalHotkeyMonitor.swift) | ~188 | 快捷键监听 | 无改动 |
| [OverlayWindow.swift](TypelessUI/OverlayWindow.swift) | ~187 | 悬浮窗 | screenSaver 置顶 + fullScreenAuxiliary |
| [SettingsView.swift](TypelessUI/SettingsView.swift) | ~229 | 设置面板 | 无改动 |
| [Constants.swift](TypelessUI/Constants.swift) | ~49 | 常量 | Bundle ID 统一 |
| [server.py](TypelessAI/server.py) | ~246 | AI 服务 | 繁→简 + 准确率优化 + VAD 参数修正 |
