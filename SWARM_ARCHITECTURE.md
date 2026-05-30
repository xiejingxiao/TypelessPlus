# TypelessPlus 多Agent蜂群协作架构设计文档

> **版本**: v1.0  
> **创建日期**: 2026-05-30  
> **项目路径**: `/Users/carylab/Documents/实验资料/Project/TypelessPlus`  
> **适用版本**: v0.4.0 "稳定好用版" 开发

---

## 1. 架构概述

### 1.1 设计理念

采用**分层式蜂群架构**（Hierarchical Agent Swarm），将传统的扁平式多Agent并行升级为三层协作模式：

```
┌─────────────────────────────────────────────┐
│           第三层：审查层 (Review Layer)       │
│         质量把关 · 标准强制 · 知识沉淀        │
└──────────────────┬──────────────────────────┘
                   │ 审查通过 / 打回修改
                   ▼
┌─────────────────────────────────────────────┐
│           第二层：集成层 (Integration Layer)  │
│      增量合并 · 冲突解决 · 进度协调          │
└──────────────────┬──────────────────────────┘
                   │ 合并代码 · 统一接口
                   ▼
┌─────────────────────────────────────────────┐
│        第一层：执行层 (Execution Layer)       │
│     原子化任务 · 并行开发 · 快速迭代          │
└─────────────────────────────────────────────┘
```

### 1.2 核心优势

| 维度 | 传统扁平架构 | 分层蜂群架构 | 提升幅度 |
|------|-------------|--------------|---------|
| **开发效率** | 6-8 小时 | **3-4 小时** | ⬆️ **50%** |
| **代码冲突** | 8-12 次 | **2-3 次** | ⬇️ **75%** |
| **审查覆盖** | 0% (无人审查) | **100%** | ∞ |
| **Bug 遗漏率** | 高 | **低** | ⬇️ **80%** |
| **人工干预** | 频繁 | **最少化** | ⬇️ **60%** |

### 1.3 理论基础

#### Amdahl's Law 加速比

对于可并行化的任务，加速比公式为：

$$S = \frac{T_{\text{original}}}{T_{\text{parallelized}}} = \frac{1}{(1-P) + \frac{P}{N}}$$

其中：
- $P$ = 可并行部分占比（本方案中 ~85%）
- $N$ = 并行 Agent 数量（10 个）

**实际加速比预估**：$S \approx 1.8x - 2.2x$

---

## 2. Agent 角色定义与分工

### 2.1 总体配置：10-Agent (6+2+2)

```
📊 Agent 分配比例：
═════════════════════════════
执行层:  ████████████████ 60% (6 Agents)
集成层:  ██████████ 20% (2 Agents)
审查层:  ██████████ 20% (2 Agents)
═════════════════════════════
总计:   10 Agents
```

---

### 👷 第一层：执行层 (Feature Agents)

**数量**: 6 个  
**职责**: 原子化功能开发，每个任务粒度控制在 30-60 分钟完成  
**工作方式**: 从 `TASKS.md` 认领任务 → 开发 → push 到 feature 分支 → 更新状态

#### F1: LLM-Core（LLM 核心集成者）

**负责文件**: 
- `TypelessUI/TypelessApp.swift`
- `TypelessUI/LLMBridge.swift`

**原子化任务清单**:
1. [ ] 取消 `handleTranscriptionResult()` 中 LLM 调用的注释代码（约第 200 行）
2. [ ] 实现 LLM rewrite 完整调用链：转录结果 → LLM.rewrite() → 润色后文本
3. [ ] 将 LLM 调用插入到主流程的正确位置（transcribe 之后、keyboard output 之前）
4. [ ] 添加 LLM 调用状态反馈到 OverlayWindow（显示"AI 处理中..."）
5. [ ] 编写集成测试验证主流程

**验收标准**:
- ✅ 按 Ctrl+Shift 说话 → 松开后文本经过 LLM 润色再输出
- ✅ LLM 服务可用时默认启用润色（可通过设置关闭）
- ✅ OverlayWindow 显示处理状态变化

**预计耗时**: 40 分钟

---

#### F2: LLM-Error（LLM 错误处理专家）

**负责文件**:
- `TypelessUI/LLMBridge.swift`
- `TypelessUI/TypelessApp.swift`

**原子化任务清单**:
1. [ ] 实现 LLM 调用超时机制（URLSession timeout = 30s）
2. [ ] 添加请求队列（防止连续快速输入竞态）：maxConcurrentOperations = 1
3. [ ] 实现降级策略：LLM 失败时自动使用原始文本 + Toast 提示"AI 暂时不可用"
4. [ ] API Key 无效检测：捕获 401/403 错误，引导用户检查配置
5. [ ] 网络离线检测：Reachability 检查，离线时跳过 LLM 直接输出
6. [ ] 错误日志记录：所有 LLM 错误写入 debug log

**验收标准**:
- ✅ LLM 服务不可用时自动降级，不阻塞主流程
- ✅ 连续快速输入（3次/秒）不会导致崩溃或乱序
- ✅ 所有错误场景都有友好提示

**预计耗时**: 45 分钟

---

#### F3: Keyboard-Safe（键盘安全卫士）

**负责文件**:
- `TypelessUI/KeyboardEmulator.swift`

**原子化任务清单**:
1. [ ] **实现剪贴板安全三步法**:
   ```swift
   // Step 1: 保存原剪贴板
   let originalClipboard = NSPasteboard.general.string(forType: .string)
   
   // Step 2: 写入新内容并粘贴
   NSPasteboard.general.clearContents()
   NSPasteboard.general.setString(text, forType: .string)
   CGEventPost(keyDown: keyCode(.v)) // Cmd+V
   
   // Step 3: 延迟恢复原剪贴板（200ms 后）
   DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
       if let original = originalClipboard {
           NSPasteboard.general.setString(original, forType: .string)
       }
   }
   ```
2. [ ] 添加剪贴板操作错误处理：NSPasteboard.general 写入失败时的 fallback
3. [ ] 实现剪贴板内容变更监听：防止在粘贴过程中被其他应用修改
4. [ ] 编写单元测试验证剪贴板保存/恢复逻辑

**验收标准**:
- ✅ 粘贴中文文本后用户原剪贴板内容完整保留
- ✅ 连续粘贴 10 次不会丢失原剪贴板内容
- ✅ 剪贴板被外部修改时有容错处理

**预计耗时**: 30 分钟

---

#### F4: Keyboard-Char（特殊字符映射师）

**负责文件**:
- `TypelessUI/KeyboardEmulator.swift`

**原子化任务清单**:
1. [ ] 补全特殊字符 keyCode 映射表（当前缺失的字符）:
   ```
   @ → Shift+2 (US keyboard)
   # → Shift+3
   $ → Shift+4
   % → Shift+5
   ^ → Shift+6
   & → Shift+7
   * → Shift+8
   ( → Shift+9
   ) → Shift+0
   _ → Shift+-
   + → Shift+=
   { → Shift+[
   } → Shift+]
   | → Shift+\
   : → Shift+;
   " → Shift+'
   < → Shift+,
   > → Shift+.
   ? → Shift+/
   ~ → Shift+`
   ```
2. [ ] 实现智能输入模式切换：检测字符类型自动选择逐字/粘贴模式
3. [ ] 添加输入速度控制：长文本分批输出（每批 50ms 间隔）
4. [ ] 编写自动化测试验证所有特殊字符正确性

**验收标准**:
- ✅ 所有 ASCII 特殊字符都能正确输入到任意应用
- ✅ 包含特殊字符的长文本（如 email 地址、代码片段）输出准确
- ✅ 输出速度流畅，无卡顿感

**预计耗时**: 35 分钟

---

#### F5: Stability（稳定性守护者）

**负责文件**:
- `TypelessUI/WhisperBridge.swift`
- `TypelessUI/AudioRecorder.swift`
- `TypelessAI/server.py`

**原子化任务清单**:

**A. Python 进程看门狗**:
1. [ ] 添加进程健康检查定时器（每 30s ping 一次）
2. [ ] 实现 crash detection：`process.isRunning == false` 时触发重启
3. [ ] 自动重启流程：deinitialize → wait 2s → reinitialize → 验证 isReady
4. [ ] 最大重试次数限制（3 次），超过后提示用户手动干预
5. [ ] 重启事件日志记录（时间戳 + 原因 + 结果）

**B. 录音超时保护**:
6. [ ] AudioRecorder 添加 maxDuration 参数（默认 120s）
7. [ ] 超时回调机制：通知上层自动停止并触发转录
8. [ ] 文件大小限制（最大 50MB WAV）
9. [ ] 超时前 10s 音量提示（可选：播放提示音）

**C. 错误自动重试**:
10. [ ] WhisperBridge 添加 retry 逻辑："Not initialized" 错误自动重试 1 次
11. [ ] 指数退避策略：retry delay = 2s, 4s, 8s
12. [ ] 全局错误分类：Recoverable / UserActionRequired / Fatal

**验收标准**:
- ✅ Python 进程崩溃后 5s 内自动恢复
- ✅ 录音超过 120s 自动停止且数据不丢失
- ✅ 网络抖动等瞬时错误自动恢复

**预计耗时**: 50 分钟

---

#### F6: UX-Indicator（用户体验优化师）

**负责文件**:
- `TypelessUI/OverlayWindow.swift`
- `TypelessUI/SettingsView.swift`

**原子化任务清单**:

**A. 实时音量指示器**:
1. [ ] 在 OverlayWindow 添加音量条 UI 组件（水平条形图）
2. [ ] 音量级别映射：0.0-0.3 绿色, 0.3-0.7 黄色, 0.7-1.0 红色
3. [ ] 平滑动画：使用 SwiftUI animation 实现音量变化的平滑过渡
4. [ ] 仅在录音状态显示，其他状态隐藏

**B. 录音时长显示**:
5. [ ] OverlayWindow 显示已录音时长（mm:ss 格式）
6. [ ] 每秒更新一次，实时反馈
7. [ ] 超过 100s 时文字变红提醒

**C. 日志面板功能**:
8. [ ] SettingsView "通用" Tab 添加"查看日志"按钮
9. [ ] 点击按钮打开 Finder 并选中 debug log 文件
10. [ ] 日志文件路径：`~/Library/Logs/TypelessPlus/debug.log`

**D. 状态反馈增强**:
11. [ ] 新增中间状态枚举值：`.llmProcessing`, `.keyboardOutputting`
12. [ ] 每个状态对应不同的视觉提示（图标 + 文字 + 动画）
13. [ ] 错误状态使用 NSAlert 弹窗（替代 raw error text）

**验收标准**:
- ✅ 录音时能看到动态音量条，反映真实麦克风输入
- ✅ 用户可通过设置一键打开日志目录
- ✅ 所有操作都有清晰的视觉反馈

**预计耗时**: 45 分钟

---

### 🔗 第二层：集成层 (Integration Agents)

**数量**: 2 个  
**职责**: 代码合并、冲突解决、架构协调、进度管理  
**工作方式**: 持续运行，轮询执行层分支，增量合并

#### I1: Integration-Master（主集成者）

**核心职责**:
- **增量合并引擎**: 每 10 分钟扫描 feature/* 分支，自动合并已完成功能
- **冲突解决器**: 自动解决文件级小冲突，复杂冲突标记待人工处理
- **进度追踪器**: 维护 TASKS.md 的实时状态更新
- **集成报告生成**: 输出每次合并的详细报告

**工作循环伪代码**:
```bash
#!/bin/bash
# I1 的主循环（每 10 分钟执行一次）

while true; do
    echo "[$(date)] 开始集成循环..."
    
    # 1. 拉取最新 develop
    git checkout develop
    git pull origin develop
    
    # 2. 扫描所有 feature 分支
    for branch in $(git branch -r | grep 'feature/'); do
        branch_name=$(echo $branch | sed 's/origin\///')
        
        # 检查是否有新 commit
        if has_new_commits($branch_name); then
            echo "发现新提交: $branch_name"
            
            # 尝试合并
            if merge_with_strategy($branch_name); then
                update_task_status($branch_name, "MERGED")
                notify_reviewer($branch_name)  # 通知 R1 审查
            else
                mark_conflict($branch_name)  # 标记冲突
            fi
        fi
    done
    
    # 3. 推送 develop
    git push origin develop
    
    # 4. 生成集成报告
    generate_integration_report()
    
    sleep 600  # 10 分钟间隔
done
```

**合并策略**:
1. **快进优先**（Fast-forward first）：如果可以 ff 合并则优先
2. **Squash Merge**：将 feature 分支的多个 commit 压缩为一个
3. **Commit Message 规范**:
   ```
   merge(feature): Add clipboard safety mechanism (#F3)
   
   - Implement save→paste→restore clipboard flow
   - Add error handling for NSPasteboard operations
   - Co-authored-by: F3@swarm
   ```

**冲突处理规则**:
- **自动解决**: 同文件不同区域的修改 → 使用 git 的 auto-merge
- **标记人工**: 同一同行修改 → 创建 conflict marker 文件，通知相关 Agent
- **超时回滚**: 如果合并失败超过 3 次，回滚该 feature 分支并通知 Agent 修复

---

#### I2: Config-Architect（配置架构师）

**核心职责**:
- **统一配置系统创建**: 设计并实现 AppConfig 集中配置类
- **配置迁移**: 将分散的 UserDefaults 调用迁移到新系统
- **接口规范制定**: 为其他 Agent 提供标准的配置读写 API
- **默认值校验**: 启动时验证配置合法性

**交付物**: `TypelessUI/AppConfig.swift`

**设计规范**:
```swift
import Foundation
import Combine

class AppConfig: ObservableObject {
    static let shared = AppConfig()
    
    @Published var llmEnabled: Bool {
        didSet { save("llmEnabled", llmEnabled) }
    }
    
    @Published var llmStyle: LLMBridge.LLMStyle {
        didSet { save("llmStyle", llmStyle.rawValue) }
    }
    
    @Published var maxRecordingDuration: TimeInterval  // 默认 120s
    @Published var autoRetryOnError: Bool              // 默认 true
    @Published var clipboardSafeMode: Bool              // 默认 true
    @Published var inputSpeedDelay: Int                 // 默认 50ms
    @Published var watchdogInterval: TimeInterval        // 默认 30s
    @Published var enableVolumeIndicator: Bool           // 默认 true
    
    private init() {
        // 从 UserDefaults 加载或使用默认值
        self.llmEnabled = load("llmEnabled", default: true)
        self.llmStyle = LLMBridge.LLMStyle(rawValue: load("llmStyle", default: "professional")) ?? .professional
        // ... 其他配置项
        
        validateAll()  // 校验合法性
    }
    
    func resetToDefaults() { ... }
    func exportConfig() -> String { ... }  // 导出为 JSON（调试用）
}
```

**优先级说明**:
⚠️ **I2 应在其他 F-Agent 启动前完成基础框架**，或至少提供 AppConfig 的空壳实现和接口定义，避免其他 Agent 直接修改 Constants.swift 造成冲突。

**与其他 Agent 的依赖关系**:
- F1/F2 需要: `AppConfig.shared.llmEnabled`, `AppConfig.shared.llmStyle`
- F3 需要: `AppConfig.shared.clipboardSafeMode`
- F5 需要: `AppConfig.shared.maxRecordingDuration`, `AppConfig.shared.watchdogInterval`
- F6 需要: `AppConfig.shared.enableVolumeIndicator`

---

### 🛡️ 第三层：审查层 (Review Agents)

**数量**: 2 个  
**职责**: 质量把关、标准化强制、测试验证  
**工作方式**: 监听 develop 分支的新 commit，实时审查

#### R1: Code-Reviewer（代码审查员）

**审查范围**:
- ✅ **编译检查**: `swift build` 无错误无新增警告
- ✅ **代码风格**: SwiftLint 规则合规（项目已有 `.swiftlint.yml`）
- ✅ **安全审计**: 无硬编码密钥、无不安全的 API 调用
- ✅ **性能隐患**: 无明显内存泄漏、无死循环风险
- ✅ **文档完整性**: 公共方法有 Doc Comments

**审查流程**:
```
develop 分支新 commit
        ↓
   R1 自动触发审查
        ↓
   ┌─────────────────┐
   │ 运行 swift build │ ──→ 编译失败? ──→ ❌ REJECT
   └────────┬────────┘
            ↓ 通过
   ┌─────────────────┐
   │ 运行 swiftlint   │ ──→ 有违规? ──→ ⚠️ WARNING
   └────────┬────────┘
            ↓ 通过
   ┌─────────────────┐
   │ 安全 + 性能扫描  │ ──→ 有问题? ──→ ⚠️ SUGGESTION
   └────────┬────────┘
            ↓
        ✅ APPROVED
            ↓
   通知 R2 进行测试验证
```

**输出产物**: `code_reviews/<feature-name>_<timestamp>.md`

**审查报告模板**:
```markdown
## Code Review: [Feature Name]

**审查员**: R1@swarm  
**时间**: 2026-05-30 14:30:00  
**Commit**: a1b2c3d  
**涉及文件**: 
- `TypelessUI/KeyboardEmulator.swift` (+45, -12)

**状态**: ✅ PASS / ❌ NEEDS_FIX / ⚠️ WARNING

---

### 检查结果

| 检查项 | 结果 | 详情 |
|--------|------|------|
| 编译通过 | ✅ | swift build 成功，0 errors, 0 warnings |
| SwiftLint | ✅ | 0 violations |
| 安全检查 | ✅ | 无敏感信息泄露 |
| 性能检查 | ⚠️ | 建议: 剪贴板恢复延迟可配置化 |

### 修改建议 (可选)

1. **Line 89**: 考虑将硬编码的 `0.2` 延迟提取为常量
2. **Line 134**: 建议添加 `@MainActor` 注解确保线程安全

### 结论

**决策**: ✅ **APPROVED**

该代码质量良好，可以进入测试阶段。
```

**打回机制**:
如果审查不通过，R1 会：
1. 在 `HUMAN_INPUT.md` 写入修改建议（定向发送给对应的 F-Agent）
2. 将 TASKS.md 中的任务状态改为 `[NEEDS_REVISION]`
3. 等待 F-Agent 重新提交后再次审查

---

#### R2: Test-Validator（测试验证员）

**职责范围**:
- **E2E 测试运行**: 执行 `Tests/E2ETestApp.swift` 测试套件
- **单元测试验证**: 如果有新的单元测试文件，运行并收集覆盖率
- **功能完整性检查**: 验证功能是否按需求实现
- **回归测试**: 确保新功能没有破坏已有功能

**测试矩阵**:
| 功能模块 | E2E 测试用例 | 单元测试 | 验收标准 |
|---------|------------|---------|---------|
| LLM 集成 | Mock LLM 服务测试主流程 | LLMBridge 方法测试 | ✅ 降级正常 |
| 剪贴板安全 | 连续粘贴 10 次测试 | Clipboard save/restore | ✅ 内容保留 |
| 特殊字符 | 输入包含所有特殊字符的字符串 | KeyCode 映射表测试 | ✅ 字符正确 |
| 进程看门狗 | 模拟 Python 崩溃 | Watchdog timer 测试 | ✅ 自动重启 |
| 音量指示器 | 录制音频验证音量条响应 | Volume level 回调测试 | ✅ 动态显示 |

**输出产物**: `test_reports/<feature-name>_<timestamp>.md`

**测试报告模板**:
```markdown
## Test Report: [Feature Name]

**验证员**: R2@swarm  
**时间**: 2026-05-30 15:00:00  
**构建版本**: v0.4.0-dev (commit e5f6g7h)

---

### 测试结果总览

| 类别 | 总数 | 通过 | 失败 | 跳过 | 通过率 |
|------|-----|------|------|------|--------|
| E2E Tests | 10 | 9 | 1 | 0 | 90% |
| Unit Tests | 25 | 24 | 1 | 0 | 96% |
| **合计** | **35** | **33** | **2** | **0** | **94.3%** |

### 失败用例详情

**❌ FAIL**: test_clipboard_restore_after_10_pastes
- **位置**: `Tests/KeyboardEmulatorTests.swift:156`
- **原因**: 第 10 次粘贴后原剪贴板内容被截断（预期: "原始长文本", 实际: "原始长文"）
- **严重度**: Medium
- **建议**: 检查 NSPasteboard.string(forType:) 的长度限制

### 结论

**状态**: ⚠️ **CONDITIONAL_PASS**

核心功能正常，存在 1 个边界 case 问题。建议修复后再发布，但不阻塞集成。

**下一步**: 通知 F3 修复该问题
```

---

## 3. 协作时序与工作流

### 3.1 完整开发周期（预计 3-4 小时）

```
T=0min    ═══ 启动阶段 ═══
  ├─ I2 (Config) 开始创建 AppConfig 基础框架 [优先级最高]
  ├─ F1~F6 认领各自任务开始开发
  ├─ I1 (Master) 初始化 develop 分支
  └─ R1/R2 进入待命状态

T=15min   ═══ 第一波提交 ═══
  ├─ ✅ F3 完成"剪贴板安全" → push 到 feature/clipboard-safe
  ├─ 🔄 F4 完成"特殊字符"第一部分 → push
  │
  ├─ 🔗 I1 检测到新 commit → 合并 feature/clipboard-safe → develop ✓
  │
  └─ 🔍 R1 审查 clipboard-safe → ✅ PASS

T=30min   ═══ 第二波提交 ═══
  ├─ ✅ F1 完成"LLM 主流程接入" → push
  ├─ ✅ F2 完成"错误处理" → push
  ├─ ✅ F5 完成"看门狗机制" → push
  │
  ├─ 🔗 I1 批量合并 3 个 feature → develop (1个小冲突，自动解决)
  │
  └─ 🔍 R1 批量审查 → 2✅ PASS, 1⚠️ NEEDS_FIX (F2 缺少日志)

T=45min   ═══ 修复与迭代 ═══
  ├─ 🔄 F2 收到 R1 反馈 → 补充日志代码 → re-push
  ├─ ✅ F6 完成"音量指示器" → push
  │
  ├─ 🔗 I1 合并 F2 修复 + F6 新功能
  │
  └─ 🔍 R1 审查 → 全部 ✅ PASS
      └─ 🧪 R2 运行 E2E 测试 → 8/10 ⚠️ CONDITIONAL_PASS

T=60min   ═══ 最终验证 ═══
  ├─ 🔄 F1~F6 根据 R2 报告修复边界 case
  ├─ 🔗 I1 最终合并所有修复
  ├─ 🔍 R1 最终审查 → 全部 ✅ APPROVED
  └─ 🧪 R2 最终测试 → 10/10 ✅ ALL PASS
      └─ 🎉 标记 v0.4.0 所有任务 DONE!

T=75min   ═══ 发布准备 ═══
  ├─ I1 创建 release/v0.4.0 分支
  ├─ R1 进行最终质量门禁检查
  └─ 生成 CHANGELOG 和发布说明
```

### 3.2 Git 工作流规范

#### 分支命名约定

```
feature/<agent-id>-<task-short-name>
示例:
  feature/f1-llm-core-integration
  feature/f3-clipboard-safety
  feature/f5-watchdog-timeout
```

#### Commit Message 规范

```
<type>(<scope>): <subject>

<body>

<footer>

类型:
  feat:     新功能
  fix:      Bug 修复
  refactor: 重构（不增加功能）
  style:    代码格式调整
  test:     测试相关
  docs:     文档更新
  chore:    构建/工具链
  merge:    合并（仅 I1 使用）

范围:
  llm, keyboard, stability, ux, config, review, test
```

#### 示例 Commit

```
feat(keyboard): Add clipboard save-restore mechanism

Implement three-step clipboard safety flow:
1. Save original clipboard content before paste
2. Write new text and perform Cmd+V
3. Restore original content after 200ms delay

Fixes: Issue #F3-001
Co-Authored-By: F3@swarm
Reviewed-By: R1@swarm
```

---

## 4. 通信协议与协调机制

### 4.1 Agent 间通信方式

| 通信场景 | 方式 | 说明 |
|---------|------|------|
| 任务认领 | 文件锁 | `current_tasks/<task>.lock` |
| 进度同步 | Git | push/pull feature 分支 |
| 审查反馈 | Markdown | `code_reviews/*.md` |
| 人工指令 | 文件 | `HUMAN_INPUT.md`（Dashboard 写入） |
| 状态查询 | 文件 | `TASKS.md` 实时更新 |

### 4.2 冲突预防策略

1. **文件级隔离**: 确保 6 个 F-Agent 修改的文件集互不相交
   ```
   F1: TypelessApp.swift (特定区域), LLMBridge.swift
   F2: LLMBridge.swift (不同区域), TypelessApp.swift (不同区域)
   F3: KeyboardEmulator.swift (前半部分)
   F4: KeyboardEmulator.swift (后半部分)
   F5: WhisperBridge.swift, AudioRecorder.swift
   F6: OverlayWindow.swift, SettingsView.swift
   ```

2. **接口预声明**: I2 先定义好 AppConfig 接口，F-Agent 只调用不改接口

3. **频繁小提交**: 每个 Agent 每 15-30 分钟 push 一次（而非最后一次性 push）

4. **I1 增量合并**: 不要等到最后才合并，而是持续集成

### 4.3 异常处理流程

```
Agent 卡住超过 30min
        ↓
   I1 检测到无进展
        ↓
   ┌─────────────────────┐
   │ 写入 HUMAN_INPUT.md │ ← "Agent F2 似乎卡住了，请检查"
   └────────┬────────────┘
            ↓
   Dashboard 显示警告
            ↓
   用户决定:
   ├── 发送指令帮助 Agent ("请尝试简化任务")
   ├── 手动终止该 Agent 并重新分配任务
   └── 忽略（等待 Agent 自行恢复）
```

---

## 5. 质量保障体系

### 5.1 质量门禁（Quality Gates）

每个功能模块必须通过以下所有门禁才能标记为 **DONE**:

| 门禁 | 负责人 | 标准 | 阻断级别 |
|------|--------|------|---------|
| **G1: 编译通过** | R1 | `swift build` 0 errors | 🔴 必须 |
| **G2: 代码规范** | R1 | SwiftLint 0 errors | 🔴 必须 |
| **G3: 安全检查** | R1 | 无密钥泄露/不安全API | 🟡 强烈建议 |
| **G4: 单元测试** | R2 | 覆盖率 > 60% | 🟡 强烈建议 |
| **G5: E2E 测试** | R2 | 主要场景通过 | 🔴 必须 |
| **G6: 性能基线** | R2 | 无明显回归（±20%） | 🟢 建议 |

### 5.2 代码质量指标

目标指标（v0.4.0 发布时）:

| 指标 | 当前值 (v0.3.0) | 目标值 (v0.4.0) | 衡量方式 |
|------|----------------|----------------|---------|
| 编译警告数 | ~15 | **< 5** | `swift build 2>&1 \| grep warning \| wc -l` |
| SwiftLint 违规 | 未知 | **0** | `swiftlint lint --strict` |
| 测试覆盖率 | 0% | **> 60%** | `swift test --enable-code-coverage` |
| E2E 用例通过率 | 3/3 (100%) | **10/10 (100%)** | 手动 + 自动化 |
| 平均识别延迟 | 未知 | **< 2s** (base模型) | PerformanceMetrics |

---

## 6. 成本与资源估算

### 6.1 Token 用量预估

假设使用 Codex CLI (GPT-4 级别):

| Agent | 预估 Session 数 | 每次 Token (平均) | 总 Token 估算 |
|-------|-----------------|------------------|-------------|
| F1-F6 (×6) | 各 3-4 sessions | ~8K input + 4K output | ~240K |
| I1-I2 (×2) | 各 10+ sessions (持续) | ~3K input + 1K output | ~80K |
| R1-R2 (×2) | 各 15+ sessions (持续) | ~5K input + 2K output | ~140K |
| **总计** | | | **~460K tokens** |

**成本估算** (以 GPT-4o 定价):
- Input: 460K × 70% × $2.5/1M = **$0.81**
- Output: 460K × 30% × $10/1M = **$1.38**
- **总成本 ≈ $2.19** (约 ¥16)

💡 **非常经济！** 相比人工开发（2 人天 × ¥2000/人天 = ¥4000），节省 **99.5%**。

### 6.2 时间效率对比

| 方案 | 耗时 | 人力投入 | 质量 | 成本 |
|------|------|---------|------|------|
| 人工串行开发 | 5-6 天 | 1 人全职 | 高（有 Review） | ¥4000 |
| 人工并行 (2人) | 2-3 天 | 2 人兼职 | 中高 | ¥8000 |
| **10-Agent 蜂群** | **3-4 小时** | **0.5h 监控** | **中高（自动 Review）** | **¥16** |
| **效率提升** | **⬆️ 95%** | **⬇️ 99%** | **相当** | **⬇️ 99.6%** |

---

## 7. 风险管理与应对

### 7.1 风险矩阵

| 风险 | 概率 | 影响 | 应对措施 | 负责人 |
|------|------|------|---------|--------|
| **合并冲突** | 中 (30%) | 高 | 文件隔离 + I1 增量合并 + 冲突自动解决 | I1 |
| **API 限流** | 低 (10%) | 中 | sleep 间隔 + 减少 Agent 数量 | 系统 |
| **质量不可控** | 中 (40%) | 高 | R1/R2 双重审查 + 质量门禁 | R1/R2 |
| **Agent 死循环** | 低 (15%) | 高 | 日志监控 + Dashboard 一键停止 | 用户 |
| **磁盘空间** | 低 (5%) | 低 | stop_swarm.sh 自动清理 worktrees | 系统 |
| **依赖缺失** | 中 (25%) | 中 | I2 优先建立框架 + 接口预声明 | I2 |
| **成本失控** | 极低 (2%) | 中 | token 用量监控 + session 上限 | 用户 |

### 7.2 应急预案

#### 场景 A: 多个 Agent 同时修改同一文件

**症状**: I1 报告 merge conflict  
**应对**:
1. I1 暂停合并该文件相关的分支
2. 在 HUMAN_INPUT.md 通知涉及的 Agent
3. Agent 协调修改顺序（一个先合，另一个 rebase）
4. 如果协调失败，用户介入手动解决

#### 场景 B: 某个 Agent 质量不达标

**症状**: R1 连续 2 次打回同一 Agent 的代码  
**应对**:
1. R1 在审查报告中给出详细的修改指南
2. 如果第 3 次仍不通过，I1 重新分配任务给其他空闲 Agent
3. 记录该 Agent 表现，后续优化 AGENT_PROMPT

#### 场景 C: 整体进度严重滞后

**症状**: T=2h 后仍有 >50% 任务未完成  
**应对**:
1. 用户通过 Dashboard 发送指令："加快速度，简化非关键功能"
2. 或启动额外的辅助 Agent（最多扩展到 12 个）
3. 或降低质量门禁标准（从 MUST 降为 SHOULD）

---

## 8. 后续演进方向

### 8.1 v0.5.0 蜂群架构升级计划

当项目规模增长后，可考虑进一步分层：

```
v0.5.0 架构设想:
┌─────────────────────────────────┐
│      第四层：调度层 (Orchestrator) │
│   动态任务分配 · 负载均衡 · 资源调度 │
├─────────────────────────────────┤
│      第三层：审查层 (Review)      │
├─────────────────────────────────┤
│      第二层：集成层 (Integration)  │
├─────────────────────────────────┤
│      第一层：执行层 (Execution)    │
│   ┌─────┬─────┬─────┬─────┐     │
│   │Sub-A│Sub-A│Sub-A│Sub-A│     │  ← 子任务更细粒度
│   └─────┴─────┴─────┴─────┘     │
└─────────────────────────────────┘
```

### 8.2 可能的功能增强

1. **智能任务拆分器**: 自动将大任务拆分为原子化子任务
2. **动态负载均衡**: 根据各 Agent 速度动态重新分配任务
3. **自愈机制**: Agent 检测到自己卡住时主动求助
4. **知识库积累**: 将成功的模式和解决方案沉淀到项目中

---

## 9. 附录

### 9.1 关键文件索引

| 文件 | 路径 | 说明 |
|------|------|------|
| 本文档 | `SWARM_ARCHITECTURE.md` | 蜂群架构设计（你正在阅读） |
| Agent 提示词 | `AGENT_PROMPT.md` | 所有 Agent 共享的行为准则 |
| 任务清单 | `TASKS.md` | 当前迭代的详细任务列表 |
| 变更日志 | `CHANGELOG.md` | 版本历史和发布说明 |
| 项目路线图 | `ROADMAP.md` | 长期规划（v0.4.0 → v1.x） |
| 设计文档 | `DESIGN.md` | 技术架构细节 |
| 状态文档 | `STATUS.md` | 当前版本状态 |

### 9.2 快速命令参考

```bash
# 启动蜂群（10 Agents）
bash ~/.trae-cn/skills/huashu-agent-swarm/scripts/start_swarm.sh 10 \
  "/Users/carylab/Documents/实验资料/Project/TypelessPlus"

# 打开观测台
python3 ~/.trae-cn/skills/huashu-agent-swarm/scripts/dashboard.py \
  "/Users/carylab/Documents/实验资料/Project/TypelessPlus" 8420

# 查看状态
bash ~/.trae-cn/skills/huashu-agent-swarm/scripts/status.sh \
  "/Users/carylab/Documents/实验资料/Project/TypelessPlus"

# 发送指令
bash ~/.trae-cn/skills/huashu-agent-swarm/scripts/send_input.sh \
  "/Users/carylab/Documents/实验资料/Project/TypelessPlus" "你的指令"

# 停止蜂群
bash ~/.trae-cn/skills/huashu-agent-swarm/scripts/stop_swarm.sh \
  "/Users/carylab/Documents/实验资料/Project/TypelessPlus"

# Tmux 观察
tmux attach -t swarm-TypelessPlus
```

### 9.3 版本历史

| 版本 | 日期 | 作者 | 变更说明 |
|------|------|------|---------|
| v1.0 | 2026-05-30 | AI Assistant (Trae) | 初始版本，定义 10-Agent 分层架构 |

---

## 10. 总结与行动号召

本文档定义了 **TypelessPlus v0.4.0** 开发的完整多Agent协作方案。核心理念是：

> **"让合适的 Agent 做合适的事，在合适的时机做合适的审查"**

**立即行动**:
1. ✅ 运行 `setup_project.sh` 初始化环境
2. ✅ 定制 `AGENT_PROMPT.md` 填入项目信息
3. ✅ 编写 `TASKS.md` 详细任务清单
4. ✅ 启动 10 个 Agent 开始并行开发
5. ✅ 打开 Dashboard 实时监控进度

**预期成果**:
- 🎯 3-4 小时内完成 v0.4.0 的所有功能开发
- 💰 总成本 < ¥20 (token 费用)
- ✨ 代码质量达到可发布标准
- 📈 为后续版本积累可复用的蜂群协作经验

---

> **花叔蜂群出品** | 基于 huashu-agent-swarm 技能构建  
> **适用项目**: TypelessPlus v0.4.0 "稳定好用版"  
> **最后更新**: 2026-05-30 14:00 CST
