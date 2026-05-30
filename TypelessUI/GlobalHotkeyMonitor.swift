import AppKit
import Carbon
import CoreGraphics
import Foundation

/// 全局快捷键监听器 (v5 — 稳定版)
/// 模式: Push-to-Talk — 按住 Ctrl+Shift 开始录音，松开停止
///
/// 设计原则:
/// - 使用 CGEventTap (.defaultTap) 监听，兼容所有 macOS 版本
///   (.listenOnly 在部分 macOS 配置上不传 flagsChanged 事件)
/// - 事件透传：defaultTap 模式下回调必须返回原事件，不吞键
/// - 直接在回调中处理，不用 DispatchQueue.main.async（避免事件批量处理）
/// - settle 判定用时间戳比较 + Timer 轮询
final class GlobalHotkeyMonitor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var onStart: (() -> Void)?
    private var onStop: (() -> Void)?

    // ─── 状态（只在主线程访问）───
    private var ctrlDown = false
    private var shiftDown = false
    private var isRecording = false
    private var cancelledByShortcut = false

    /// 记录双键同时按下的时间戳，用于 settle 判定
    private var bothHeldSince: CFAbsoluteTime = 0

    /// settle 间隔（秒）
    private var settleInterval: Double = 0.10

    /// 定时轮询检查 settle
    private var pollTimer: Timer?

    /// 修饰键的 keycode 集合（Shift/Ctrl/Option/Command 各左右 + CapsLock + Fn）
    private static let modifierKeyCodes: Set<UInt16> = [
        56, 60, 59, 62, 58, 61, 55, 54, 57
    ]

    // MARK: - Public API

    func startListening(onStart: @escaping () -> Void, onStop: @escaping () -> Void) {
        self.onStart = onStart
        self.onStop = onStop
        registerCGEventTap()
        startPollTimer()
        print("[HotkeyMonitor] 启动完成，等待 Ctrl+Shift ...")
    }

    func stopListening() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        pollTimer?.invalidate()
        eventTap = nil
        runLoopSource = nil
        pollTimer = nil
    }

    // MARK: - CGEventTap 注册

    private func registerCGEventTap() {
        let eventMask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue)

        // 必须用 defaultTap：listenOnly 在部分 macOS 上不传 flagsChanged
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                let monitor = Unmanaged<GlobalHotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                monitor.handleCGEvent(proxy: proxy, type: type, event: event)
                // defaultTap 必须返回原事件（passUnretained，不增加引用计数）
                // passRetained 会阻止系统继续处理事件，导致后续 flagsChanged 不传递
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap = eventTap else {
            print("[HotkeyMonitor] ❌ CGEventTap 创建失败！需要辅助功能权限。2秒后重试...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.registerCGEventTap()
            }
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        print("[HotkeyMonitor] ✅ CGEventTap 注册成功 (defaultTap)")
    }

    // MARK: - CGEvent 回调（直接处理，不 async）

    private func handleCGEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) {
        switch type {
        case .flagsChanged:
            let flags = event.flags
            let ctrl = flags.contains(.maskControl)
            let shift = flags.contains(.maskShift)
            processFlagsChanged(ctrl: ctrl, shift: shift)

        case .keyDown:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            processKeyDown(keyCode: keyCode)

        case .tapDisabledByTimeout:
            print("[HotkeyMonitor] ⚠️ CGEventTap 超时被禁用，重新启用...")
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }

        default:
            break
        }
    }

    // MARK: - 核心逻辑（只在主线程调用）

    private func processFlagsChanged(ctrl: Bool, shift: Bool) {
        let prevCtrl = ctrlDown
        let prevShift = shiftDown
        ctrlDown = ctrl
        shiftDown = shift

        let bothHeld = ctrlDown && shiftDown
        let wasBothHeld = prevCtrl && prevShift

        if bothHeld && !wasBothHeld {
            // 刚刚同时按下了两个键
            if !isRecording && !cancelledByShortcut {
                bothHeldSince = CFAbsoluteTimeGetCurrent()
            }
        } else if !bothHeld && wasBothHeld {
            // 刚刚松开了至少一个键
            bothHeldSince = 0
            if isRecording {
                isRecording = false
                cancelledByShortcut = false
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
        guard !Self.modifierKeyCodes.contains(keyCode) else { return }

        if ctrlDown && shiftDown && !isRecording {
            cancelledByShortcut = true
            bothHeldSince = 0
        }
    }

    // MARK: - Settle 轮询定时器

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
            onStart?()
        }
    }
}
