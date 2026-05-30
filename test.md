# 测试计划

## 测试项

| # | 测试项 | 测试方式 | 状态 |
|---|--------|----------|------|
| T1 | 编译构建 | `make build` 编译 | ❌ 失败 |
| T2 | 应用启动 | 双击 TypelessPlus.app | ❌ 无法测试 - 有安全权限问题 |
| T3 | 快捷键 | 按快捷键开始录音 | ❌ 无法测试 - 有安全权限问题 |
| T4 | 录音功能 | 开始录音 | ❌ 无法测试 - 有安全权限问题 |
| T5 | 麦克风输入 | 录音中包含麦克风 | ❌ 无法测试 - 有安全权限问题 |
| T6 | 剪贴板输出 | 查看剪贴板内容 | ❌ 无法测试 - 有安全权限问题 |
| T7 | 模型选择 | 切换不同模型 | ❌ 无法测试 - 有安全权限问题 |
| T8-T12 | 其余功能 | 按模块功能测试 | ❌ 无法测试 - 有安全权限问题 |

## 问题分析

1. **make build** 执行时报 `Operation not permitted`
2. **xcodebuild -list** 报错：`requires Xcode, but active developer directory '/Library/Developer/CommandLineTools' is a command line tools instance`

## 已解决

T1 已发现：`make build` 确实可以执行，但会报 Operation not permitted 错误

## 需要手动完成的测试

- T2-T12 需要手动在 Xcode 中完成

## 下一步

请按以下步骤操作：

1. **打开 Xcode**
   - 打开 Finder
   - 按 `Cmd + Shift + G`
   - 输入路径：`/Users/carylab/Documents/实验资料/Project/TypelessPlus/TypelessPlus`
   - 双击 `Typeless.xcodeproj` 文件

2. **编译测试**
   - 在 Xcode 中确保 top bar 选择 `Typeless Mac.app`
   - 按 `Cmd + B` 编译
   - 或者点击 Run 按钮启动

3. **功能测试**
   - T2: 启动后尝试使用功能
   - T3: 按快捷键看是否开始录音
   - T4: 尝试使用麦克风
   - T5-T12: 按模块功能测试

4. **记录结果**
   - 完成每项测试后告诉我结果（通过或失败）