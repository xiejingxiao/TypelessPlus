import AppKit
import Carbon
import CoreGraphics

/// 模拟键盘输入：将识别文本通过 CGEventPost 键入到当前焦点应用
final class KeyboardEmulator {

    /// 将文本输出到当前焦点应用
    func type(text: String) {
        guard !text.isEmpty else { return }

        // 中文等多字节文本，统一用剪贴板粘贴（更快更可靠）
        // 纯 ASCII 短文本可以用逐字符输入
        let isPureASCII = text.allSatisfy { $0.isASCII }
        let isShort = text.count <= 50

        if isPureASCII && isShort {
            typeCharacterByCharacter(text)
        } else {
            pasteSafely(text: text)
        }
    }

    // MARK: - 逐字符输入（仅 ASCII 短文本）

    private func typeCharacterByCharacter(_ text: String) {
        for char in text {
            if let keyCode = asciiKeyCodeMap(String(char).lowercased()) {
                postKeyEvent(keyCode: keyCode, shift: char.isUppercase)
            } else if char == " " {
                postKeyEvent(keyCode: 0x31, shift: false)
            } else {
                // 无法映射的字符，走剪贴板
                pasteSafely(text: String(char))
            }
            usleep(3000) // 3ms 间隔
        }
    }

    // MARK: - 安全剪贴板粘贴

    /// 安全的剪贴板粘贴：保存原始内容 → 写入 → 粘贴 → 恢复
    private func pasteSafely(text: String) {
        let pasteboard = NSPasteboard.general

        // 保存原始剪贴板内容
        let oldContent = pasteboard.string(forType: .string)
        let oldData = pasteboard.data(forType: .rtf)
        let oldFileURL = pasteboard.string(forType: .fileURL)

        // 写入新内容
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // 模拟 Cmd+V
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

        // 延迟恢复剪贴板（给粘贴操作足够的处理时间）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            pasteboard.clearContents()
            if let old = oldContent {
                pasteboard.setString(old, forType: .string)
            }
            if let data = oldData {
                pasteboard.setData(data, forType: .rtf)
            }
            if let url = oldFileURL {
                pasteboard.setString(url, forType: .fileURL)
            }
        }
    }

    // MARK: - CGEvent 工具

    private func postKeyEvent(keyCode: CGKeyCode, shift: Bool) {
        let source = CGEventSource(stateID: .privateState)

        if shift {
            let shiftDown = CGEvent(keyboardEventSource: source, virtualKey: 0x38, keyDown: true)
            shiftDown?.post(tap: .cghidEventTap)
        }

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyUp?.post(tap: .cghidEventTap)

        if shift {
            let shiftUp = CGEvent(keyboardEventSource: source, virtualKey: 0x38, keyDown: false)
            shiftUp?.post(tap: .cghidEventTap)
        }
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
