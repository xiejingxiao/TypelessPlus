import AppKit
import Carbon
import CoreGraphics
import os.log

/// 模拟键盘输入：将识别文本通过 CGEventPost 键入到当前焦点应用
final class KeyboardEmulator {

    // MARK: - Configuration

    /// 剪贴板安全模式开关（默认开启）
    private let clipboardSafeMode: Bool = true

    /// 剪贴板恢复延迟（纳秒）
    private let clipboardRestoreDelay: UInt64 = 200_000_000 // 200ms

    /// 逐字输入延迟（微秒），从 AppConfig 读取
    private var characterDelay: UInt32 {
        UInt32(AppConfig.shared.inputSpeedDelay) * 1000
    }

    // MARK: - State Protection

    /// 防重入锁：防止并发粘贴操作导致状态混乱
    private var isPasting: Bool = false

    /// 日志记录器
    private static let logger = Logger(subsystem: "com.typelessplus.keyboard", category: "KeyboardEmulator")

    // MARK: - Special Character Key Mapping

    /// 特殊字符 → (keyCode, modifiers) 映射表
    /// 覆盖 US ANSI 键盘布局下所有 Shift+BaseKey 生成的符号
    static let specialKeyMap: [Character: (keyCode: CGKeyCode, modifiers: CGEventFlags)] = [
        "@": (0x13, .maskShift),
        "#": (0x14, .maskShift),
        "$": (0x15, .maskShift),
        "%": (0x17, .maskShift),
        "^": (0x16, .maskShift),
        "&": (0x1A, .maskShift),
        "*": (0x1C, .maskShift),
        "(": (0x19, .maskShift),
        ")": (0x1D, .maskShift),
        "_": (0x1B, .maskShift),
        "+": (0x18, .maskShift),
        "{": (0x21, .maskShift),
        "}": (0x1E, .maskShift),
        "|": (0x2A, .maskShift),
        ":": (0x29, .maskShift),
        "\"": (0x27, .maskShift),
        "<": (0x2B, .maskShift),
        ">": (0x2F, .maskShift),
        "?": (0x2C, .maskShift),
        "~": (0x32, .maskShift),
    ]

    /// 将文本输出到当前焦点应用
    func type(text: String) {
        guard !text.isEmpty else { return }

        if shouldUseCharacterMode(text) {
            typeCharacterByCharacter(text)
        } else {
            Task {
                await pasteText(text)
            }
        }
    }

    // MARK: - 智能模式选择

    /// 判断是否使用逐字符输入模式
    /// 条件：纯 ASCII 且长度 < 20 → 逐字模式（更快，不污染剪贴板）
    /// 否则 → 剪贴板模式（支持中文/长文本）
    private func shouldUseCharacterMode(_ text: String) -> Bool {
        let isPureASCII = text.allSatisfy { $0.isASCII }
        let isShort = text.count < 20
        return isPureASCII && isShort
    }

    // MARK: - 逐字符输入（ASCII 文本，含完整特殊字符支持）

    private func typeCharacterByCharacter(_ text: String) {
        for char in text {
            if let mapping = Self.specialKeyMap[char] {
                postKeyEvent(keyCode: mapping.keyCode, flags: mapping.modifiers)
            } else if let keyCode = asciiKeyCodeMap(String(char).lowercased()) {
                postKeyEvent(keyCode: keyCode, shift: char.isUppercase)
            } else if char == " " {
                postKeyEvent(keyCode: 0x31, flags: [])
            } else if char == "\n" || char == "\r" {
                postKeyEvent(keyCode: 0x24, flags: [])
            } else if char == "\t" {
                postKeyEvent(keyCode: 0x30, flags: [])
            } else {
                Task {
                    await pasteText(String(char))
                }
            }
            usleep(characterDelay)
        }
    }

    // MARK: - 安全剪贴板粘贴（增强版）

    /// 安全的剪贴板粘贴：保存原始内容 → 写入 → 粘贴 → 恢复
    /// 实现三步法 + 防重入保护 + 线程安全 + 错误处理
    func pasteText(_ text: String) async {
        guard !text.isEmpty else { return }
        
        // 防重入检查
        guard !isPasting else {
            Self.logger.warning("⚠️ Clipboard operation already in progress, skipping concurrent call")
            return
        }
        
        isPasting = true
        defer { isPasting = false }

        // 如果安全模式关闭，直接粘贴不保存
        guard clipboardSafeMode else {
            await directPaste(text: text)
            return
        }

        // Step 1: 在主线程保存原剪贴板
        let originalClipboard = await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let pasteboard = NSPasteboard.general
                let originalContent = pasteboard.string(forType: .string)
                continuation.resume(returning: originalContent)
            }
        }

        // Step 2: 写入新内容并粘贴
        do {
            try await writeAndPaste(text: text)
            
            // Step 3: 200ms 后恢复原剪贴板
            try? await Task.sleep(nanoseconds: clipboardRestoreDelay)
            
            await restoreClipboard(originalContent: originalClipboard)
            
        } catch {
            Self.logger.error("❌ Paste failed: \(error.localizedDescription), falling back to character-by-character input")
            // Fallback: 使用逐字输入模式
            fallbackToCharacterInput(text)
        }
    }
    
    // MARK: - Private Helpers
    
    /// 直接粘贴（不保存剪贴板，用于安全模式关闭时）
    private func directPaste(text: String) async {
        DispatchQueue.main.async {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            self.postCommandV()
        }
    }
    
    /// 写入内容并执行 Cmd+V
    private func writeAndPaste(text: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                let pasteboard = NSPasteboard.general
                
                do {
                    // 清空并写入新内容
                    pasteboard.clearContents()
                    let success = pasteboard.setString(text, forType: .string)
                    
                    guard success else {
                        continuation.resume(throwing: NSError(
                            domain: "KeyboardEmulator",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Failed to write to clipboard"]
                        ))
                        return
                    }
                    
                    // 执行 Cmd+V
                    self.postCommandV()
                    
                    continuation.resume(())
                    
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// 恢复原剪贴板内容
    private func restoreClipboard(originalContent: String?) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                guard let original = originalContent else {
                    continuation.resume(())
                    return
                }
                
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(original, forType: .string)
                
                Self.logger.info("✅ Clipboard restored successfully")
                continuation.resume(())
            }
        }
    }
    
    /// Fallback: 逐字输入模式
    private func fallbackToCharacterInput(_ text: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.typeCharacterByCharacter(text)
        }
    }
    
    /// 发送 Cmd+V 快捷键
    private func postCommandV() {
        let source = CGEventSource(stateID: .privateState)

        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true)
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)

        vDown?.flags = .maskCommand
        vUp?.flags = .maskCommand

        cmdDown?.post(tap: .cghidEventTap)
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)
    }

    // MARK: - CGEvent 工具

    private func postKeyEvent(keyCode: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .privateState)

        var activeModifiers: [CGKeyCode] = []
        if flags.contains(.maskShift) { activeModifiers.append(0x38) }
        if flags.contains(.maskCommand) { activeModifiers.append(0x37) }
        if flags.contains(.maskAlternate) { activeModifiers.append(0x3A) }
        if flags.contains(.maskControl) { activeModifiers.append(0x3B) }

        for modKeyCode in activeModifiers {
            let modDown = CGEvent(keyboardEventSource: source, virtualKey: modKeyCode, keyDown: true)
            modDown?.post(tap: .cghidEventTap)
        }

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = flags
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = flags
        keyUp?.post(tap: .cghidEventTap)

        for modKeyCode in activeModifiers.reversed() {
            let modUp = CGEvent(keyboardEventSource: source, virtualKey: modKeyCode, keyDown: false)
            modUp?.post(tap: .cghidEventTap)
        }
    }

    @available(*, deprecated, renamed: "postKeyEvent(keyCode:flags:)")
    private func postKeyEvent(keyCode: CGKeyCode, shift: Bool) {
        postKeyEvent(keyCode: keyCode, flags: shift ? .maskShift : [])
    }

    // ASCII 到 CGKeyCode 映射
    private func asciiKeyCodeMap(_ char: String) -> CGKeyCode? {
        let map: [String: CGKeyCode] = [
            "a": 0x00, "b": 0x0B, "c": 0x08, "d": 0x02, "e": 0x0E,
            "f": 0x03, "g": 0x05, "h": 0x04, "i": 0x22, "j": 0x26,
            "k": 0x28, "l": 0x25, "m": 0x2E, "n": 0x2D, "o": 0x1F,
            "p": 0x23, "q": 0x0C, "r": 0x0F, "s": 0x01, "t": 0x11,
            "u": 0x20, "v": 0x09, "w": 0x0D, "x": 0x07, "y": 0x10,
            "z": 0x06,
            "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "5": 0x17,
            "6": 0x16, "7": 0x1A, "8": 0x1C, "9": 0x19, "0": 0x1D,
            ".": 0x2F, ",": 0x2B, "-": 0x1B, "=": 0x18,
            ";": 0x29, "'": 0x27, "/": 0x2C, "\\": 0x2A,
            "[": 0x21, "]": 0x1E, "`": 0x32,
        ]
        return map[char]
    }
}
