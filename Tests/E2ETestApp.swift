import AppKit
import CoreGraphics
import Carbon
import Foundation

/// 端到端自测试 v5 — 匹配 GlobalHotkeyMonitor v5 (defaultTap)
/// 测试用例:
/// 1. 正常按住 Ctrl+Shift 触发录音
/// 2. Ctrl+Shift+其他键 防误触
/// 3. 短暂按下（<100ms）不触发

final class E2ETestMonitor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pollTimer: Timer?

    private var ctrlDown = false
    private var shiftDown = false
    private var isRecording = false
    private var cancelledByShortcut = false
    private var bothHeldSince: CFAbsoluteTime = 0
    private let settleInterval: Double = 0.10

    private var testResults: [String: Bool] = [:]
    private var currentTest = ""
    private var onStartCount = 0
    private var onStopCount = 0

    var onStart: (() -> Void)?
    var onStop: (() -> Void)?

    func start() {
        print("=== E2E Test v5 (defaultTap) ===")
        print("AXIsProcessTrusted: \(AXIsProcessTrusted())")

        registerCGEventTap()
        startPollTimer()

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.runAllTests()
        }
    }

    // MARK: - CGEventTap (defaultTap — 和实际应用一致)

    private func registerCGEventTap() {
        let eventMask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue)

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                let monitor = Unmanaged<E2ETestMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                monitor.handleCGEvent(proxy: proxy, type: type, event: event)
                // defaultTap 必须返回原事件（passUnretained，不增加引用计数）
                // passRetained 会阻止系统继续处理事件，导致后续 flagsChanged 不传递
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        if let tap = eventTap {
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            print("[CGEventTap] registered (defaultTap)")
        } else {
            print("[CGEventTap] FAILED — need accessibility permission")
        }
    }

    private func handleCGEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) {
        switch type {
        case .flagsChanged:
            let flags = event.flags
            processFlagsChanged(ctrl: flags.contains(.maskControl), shift: flags.contains(.maskShift))
        case .keyDown:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            processKeyDown(keyCode: keyCode)
        case .tapDisabledByTimeout:
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        default:
            break
        }
    }

    // MARK: - Core Logic (和 GlobalHotkeyMonitor v5 完全一致)

    private let modifierKeyCodes: Set<UInt16> = [56, 60, 59, 62, 58, 61, 55, 54, 57]

    private func processFlagsChanged(ctrl: Bool, shift: Bool) {
        let prevCtrl = ctrlDown
        let prevShift = shiftDown
        ctrlDown = ctrl
        shiftDown = shift

        let bothHeld = ctrlDown && shiftDown
        let wasBothHeld = prevCtrl && prevShift

        if bothHeld && !wasBothHeld {
            if !isRecording && !cancelledByShortcut {
                bothHeldSince = CFAbsoluteTimeGetCurrent()
            }
        } else if !bothHeld && wasBothHeld {
            bothHeldSince = 0
            if isRecording {
                isRecording = false
                cancelledByShortcut = false
                onStopCount += 1
                onStop?()
            } else {
                cancelledByShortcut = false
            }
        } else if !bothHeld && !wasBothHeld {
            bothHeldSince = 0
            cancelledByShortcut = false
        }
    }

    private func processKeyDown(keyCode: UInt16) {
        guard !modifierKeyCodes.contains(keyCode) else { return }
        if ctrlDown && shiftDown && !isRecording {
            cancelledByShortcut = true
            bothHeldSince = 0
        }
    }

    // MARK: - Poll Timer

    private func startPollTimer() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            self?.checkSettle()
        }
        pollTimer?.tolerance = 0.01
        RunLoop.current.add(pollTimer!, forMode: .common)
    }

    private func checkSettle() {
        guard !isRecording && !cancelledByShortcut && bothHeldSince > 0 else { return }
        let elapsed = CFAbsoluteTimeGetCurrent() - bothHeldSince
        if elapsed >= settleInterval {
            isRecording = true
            bothHeldSince = 0
            onStartCount += 1
            onStart?()
        }
    }

    // MARK: - Test Runner

    private func runAllTests() {
        guard AXIsProcessTrusted() else {
            print("❌ 需要辅助功能权限才能运行测试")
            NSApplication.shared.terminate(nil)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            self.runTest1_NormalHold()
            usleep(500_000)

            self.runTest2_ShortPress()
            usleep(500_000)

            self.runTest3_ShortcutCombo()
            usleep(500_000)

            DispatchQueue.main.async {
                self.printResults()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    // Test 1: 正常按住 Ctrl+Shift 1秒 → 应触发录音
    private func runTest1_NormalHold() {
        currentTest = "normal_hold"
        onStartCount = 0
        onStopCount = 0

        // 按下 Ctrl
        let cDown = CGEvent(keyboardEventSource: nil, virtualKey: 59, keyDown: true)
        cDown?.flags = .maskControl
        cDown?.post(tap: .cghidEventTap)
        usleep(80_000)

        // 按下 Shift
        let sDown = CGEvent(keyboardEventSource: nil, virtualKey: 56, keyDown: true)
        sDown?.flags = [.maskControl, .maskShift]
        sDown?.post(tap: .cghidEventTap)
        usleep(800_000)  // 按住 800ms

        // 松开
        let sUp = CGEvent(keyboardEventSource: nil, virtualKey: 56, keyDown: false)
        sUp?.flags = .maskControl
        sUp?.post(tap: .cghidEventTap)
        usleep(50_000)
        let cUp = CGEvent(keyboardEventSource: nil, virtualKey: 59, keyDown: false)
        cUp?.flags = []
        cUp?.post(tap: .cghidEventTap)
        usleep(200_000)

        testResults["normal_hold"] = (onStartCount >= 1 && onStopCount >= 1)
        print("[Test1] normal_hold: onStart=\(onStartCount) onStop=\(onStopCount) → \(testResults["normal_hold"]! ? "PASS" : "FAIL")")
    }

    // Test 2: 短暂按住 <100ms → 不应触发
    private func runTest2_ShortPress() {
        currentTest = "short_press"
        onStartCount = 0
        onStopCount = 0
        isRecording = false

        let cDown = CGEvent(keyboardEventSource: nil, virtualKey: 59, keyDown: true)
        cDown?.flags = .maskControl
        cDown?.post(tap: .cghidEventTap)
        usleep(30_000)

        let sDown = CGEvent(keyboardEventSource: nil, virtualKey: 56, keyDown: true)
        sDown?.flags = [.maskControl, .maskShift]
        sDown?.post(tap: .cghidEventTap)
        usleep(30_000)  // 只按 30ms，低于 settle 间隔

        let sUp = CGEvent(keyboardEventSource: nil, virtualKey: 56, keyDown: false)
        sUp?.flags = .maskControl
        sUp?.post(tap: .cghidEventTap)
        usleep(30_000)
        let cUp = CGEvent(keyboardEventSource: nil, virtualKey: 59, keyDown: false)
        cUp?.flags = []
        cUp?.post(tap: .cghidEventTap)
        usleep(200_000)

        testResults["short_press"] = (onStartCount == 0)
        print("[Test2] short_press: onStart=\(onStartCount) → \(testResults["short_press"]! ? "PASS" : "FAIL")")
    }

    // Test 3: Ctrl+Shift+Tab 防误触 → 不应触发
    private func runTest3_ShortcutCombo() {
        currentTest = "shortcut_combo"
        onStartCount = 0
        onStopCount = 0
        isRecording = false

        let cDown = CGEvent(keyboardEventSource: nil, virtualKey: 59, keyDown: true)
        cDown?.flags = .maskControl
        cDown?.post(tap: .cghidEventTap)
        usleep(50_000)

        let sDown = CGEvent(keyboardEventSource: nil, virtualKey: 56, keyDown: true)
        sDown?.flags = [.maskControl, .maskShift]
        sDown?.post(tap: .cghidEventTap)
        usleep(50_000)

        // 按下 Tab（keyCode 0x30）— 模拟 Ctrl+Shift+Tab
        let tabDown = CGEvent(keyboardEventSource: nil, virtualKey: 0x30, keyDown: true)
        tabDown?.flags = [.maskControl, .maskShift]
        tabDown?.post(tap: .cghidEventTap)
        usleep(30_000)
        let tabUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x30, keyDown: false)
        tabUp?.flags = [.maskControl, .maskShift]
        tabUp?.post(tap: .cghidEventTap)
        usleep(100_000)

        // 松开修饰键
        let sUp = CGEvent(keyboardEventSource: nil, virtualKey: 56, keyDown: false)
        sUp?.flags = .maskControl
        sUp?.post(tap: .cghidEventTap)
        usleep(30_000)
        let cUp = CGEvent(keyboardEventSource: nil, virtualKey: 59, keyDown: false)
        cUp?.flags = []
        cUp?.post(tap: .cghidEventTap)
        usleep(200_000)

        testResults["shortcut_combo"] = (onStartCount == 0)
        print("[Test3] shortcut_combo: onStart=\(onStartCount) → \(testResults["shortcut_combo"]! ? "PASS" : "FAIL")")
    }

    private func printResults() {
        print("")
        print("═══════════════════════════════════")
        print("  E2E Test Results (v5 defaultTap)")
        print("═══════════════════════════════════")
        var allPass = true
        for (name, pass) in testResults.sorted(by: { $0.key < $1.key }) {
            let mark = pass ? "✅ PASS" : "❌ FAIL"
            print("  \(mark)  \(name)")
            if !pass { allPass = false }
        }
        print("═══════════════════════════════════")
        print("  Overall: \(allPass ? "✅ ALL PASS" : "❌ SOME FAILED")")
        print("═══════════════════════════════════")
    }
}

// ─── Main ───

final class E2ETestApp: NSObject, NSApplicationDelegate {
    let monitor = E2ETestMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        monitor.onStart = {
            print("  → onStart triggered")
        }
        monitor.onStop = {
            print("  → onStop triggered")
        }
        monitor.start()

        // 安全超时
        DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) {
            NSApplication.shared.terminate(nil)
        }
    }
}

let app = NSApplication.shared
let delegate = E2ETestApp()
app.delegate = delegate
app.run()
