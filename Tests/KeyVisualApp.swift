import AppKit
import CoreGraphics
import Carbon

// ─────────────────────────────────────────────
// 按键可视化诊断工具
// 在桌面显示当前修饰键状态，帮助判断 CGEventTap 是否收到 flagsChanged
// ─────────────────────────────────────────────

class KeyVisualApp: NSApplication, NSApplicationDelegate {
    var window: NSWindow!
    var label: NSTextField!
    var detailLabel: NSTextField!
    var eventTap: CFMachPort?
    var runLoopSource: CFRunLoopSource?
    
    var lastFlags: CGEventFlags = []
    var flagsChangedCount = 0
    var keyDownCount = 0
    var lastEventTime: String = ""
    var tapMode: String = "listenOnly"
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        let screen = NSScreen.main!
        let frame = NSRect(x: screen.frame.midX - 220, y: screen.frame.maxY - 160, width: 440, height: 140)
        
        window = NSPanel(contentRect: frame, styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = NSColor(white: 0.1, alpha: 0.92)
        window.title = "TypelessPlus 按键诊断"
        window.titlebarAppearsTransparent = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        label = NSTextField(labelWithString: "等待按键事件...")
        label.font = NSFont.monospacedSystemFont(ofSize: 16, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 10, y: 75, width: 420, height: 30)
        
        detailLabel = NSTextField(labelWithString: "")
        detailLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = NSColor(white: 0.7, alpha: 1.0)
        detailLabel.alignment = .center
        detailLabel.frame = NSRect(x: 10, y: 20, width: 420, height: 50)
        detailLabel.cell?.wraps = true
        
        window.contentView?.addSubview(label)
        window.contentView?.addSubview(detailLabel)
        window.orderFrontRegardless()
        window.makeKey()
        
        startEventTap()
        updateDisplay()
    }
    
    func startEventTap() {
        let eventMask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue)
        
        let callback: CGEventTapCallBack = { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
            let app = Unmanaged<KeyVisualApp>.fromOpaque(refcon!).takeUnretainedValue()
            app.handleEvent(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }
        
        var refcon = Unmanaged.passUnretained(self).toOpaque()
        
        // 先试 listenOnly（使用 Swift API）
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: refcon
        )
        
        if eventTap == nil {
            // listenOnly 失败，降级到 defaultTap
            tapMode = "defaultTap (listenOnly失败,降级)"
            eventTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: eventMask,
                callback: callback,
                userInfo: refcon
            )
        }
        
        if let tap = eventTap {
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        } else {
            label.stringValue = "❌ 无法创建 EventTap（需要辅助功能权限）"
            detailLabel.stringValue = "请在 系统设置 → 隐私与安全性 → 辅助功能 中授权"
        }
    }
    
    func handleEvent(type: CGEventType, event: CGEvent) {
        let now = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        lastEventTime = now
        
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        
        let flags = event.flags
        lastFlags = flags
        
        if type == .flagsChanged {
            flagsChangedCount += 1
        } else if type == .keyDown {
            keyDownCount += 1
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.updateDisplay()
        }
    }
    
    func updateDisplay() {
        let ctrl = lastFlags.contains(.maskControl)
        let shift = lastFlags.contains(.maskShift)
        let cmd = lastFlags.contains(.maskCommand)
        let alt = lastFlags.contains(.maskAlternate)
        
        let ctrlStr = ctrl ? "⌃Ctrl" : "  ·  "
        let shiftStr = shift ? "⇧Shift" : "  ·  "
        let cmdStr = cmd ? "⌘Cmd" : "  ·  "
        let altStr = alt ? "⌥Alt" : "  ·  "
        
        let bothHeld = ctrl && shift
        
        label.stringValue = "\(ctrlStr)  \(shiftStr)  \(cmdStr)  \(altStr)"
        label.textColor = bothHeld ? NSColor(red: 0.2, green: 1.0, blue: 0.4, alpha: 1.0) : .white
        
        detailLabel.stringValue =
            "flagsChanged: \(flagsChangedCount) 次 | keyDown: \(keyDownCount) 次 | 模式: \(tapMode)\n" +
            "Ctrl+Shift 同时按下: \(bothHeld ? "✅ 是 — 应触发录音" : "❌ 否") | 最后事件: \(lastEventTime)"
    }
}

let app = KeyVisualApp()
app.delegate = app
app.run()
