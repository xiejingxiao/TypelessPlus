import SwiftUI
import AppKit
import AVFoundation
import ApplicationServices
@preconcurrency import Combine

// MARK: - Error Presentation

enum ErrorPresenter {
    static func show(for error: Error, window: NSWindow? = nil) {
        let friendlyMessage = resolveFriendlyMessage(error)
        let alert = NSAlert()
        alert.messageText = "操作遇到问题"
        alert.informativeText = friendlyMessage
        alert.alertStyle = .warning
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "查看日志")

        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            openLogInFinder()
        }
    }

    static func resolveFriendlyMessage(_ error: Error) -> String {
        if let whisperErr = error as? WhisperError {
            return whisperErr.friendlyMessage
        }
        if let llmErr = error as? LLMBridgeError {
            return llmErr.friendlyMessage
        }

        let nsError = error as NSError
        switch nsError.domain {
        case NSPOSIXErrorDomain:
            return "系统资源暂时不可用，请稍后重试"
        case NSURLErrorDomain:
            let urlErrors: [Int: String] = [
                NSURLErrorTimedOut: "网络请求超时，请检查网络连接",
                NSURLErrorNetworkConnectionLost: "网络连接中断，请重新连接网络",
                NSURLErrorNotConnectedToInternet: "设备未连接到互联网",
                NSURLErrorCannotConnectToHost: "无法连接到目标服务器",
            ]
            if let msg = urlErrors[nsError.code] { return msg }
            return "网络错误 (\(nsError.code))"
        default:
            return error.localizedDescription
        }
    }

    private static func openLogInFinder() {
        let logPath = AppConfig.shared.logFilePath
        let logURL = URL(fileURLWithPath: logPath)
        NSWorkspace.shared.selectFile(logURL.path(), inFileViewerRootedAtPath: logURL.deletingLastPathComponent().path())
    }
}

// MARK: - Error Classification
enum ErrorCategory {
    case recoverable
    case userActionRequired
    case fatal

    static func classify(_ error: Error) -> ErrorCategory {
        let nsError = error as NSError
        switch nsError.domain {
        case NSPOSIXErrorDomain:
            return .recoverable
        case NSURLErrorDomain:
            let urlErrors: Set<Int> = [
                NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
                NSURLErrorNotConnectedToInternet, NSURLErrorCannotConnectToHost
            ]
            if urlErrors.contains(nsError.code) { return .recoverable }
            return .userActionRequired
        default:
            if let whisperErr = error as? WhisperError {
                switch whisperErr {
                case .processNotRunning, .serverError: return .recoverable
                default: return .fatal
                }
            }
            return .fatal
        }
    }
}

// MARK: - Retry Decorator
func withRetry<T>(
    maxRetries: Int = 1,
    operation: () async throws -> T
) async throws -> T {
    var lastError: Error?
    for attempt in 0...maxRetries {
        do {
            return try await operation()
        } catch {
            lastError = error
            guard attempt < maxRetries else { break }
            let category = ErrorCategory.classify(error)
            guard category == .recoverable else {
                print("[Retry] Non-recoverable error (\(category)), not retrying: \(error.localizedDescription)")
                throw error
            }
            let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
            print("[Retry] Attempt \(attempt + 1)/\(maxRetries + 1) failed: \(error.localizedDescription), retrying in \(delay / 1_000_000_000)s...")
            try? await Task.sleep(nanoseconds: delay)
        }
    }
    throw lastError!
}

// MARK: - 应用入口
@main
struct TypelessApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

// MARK: - App Delegate (菜单栏模式)
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var audioRecorder = AudioRecorder()
    private var keyboardEmulator = KeyboardEmulator()
    private var whisperBridge = WhisperBridge()
    private var hotkeyMonitor = GlobalHotkeyMonitor()
    private var overlayWindow: OverlayWindow?
    private var appState: AppState = .idle {
        didSet { updateUI() }
    }
    private var volumeObservation: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let logPath = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("typeless_debug.log").path ?? "/tmp/typeless_debug.log"
        let appLog: (String) -> Void = { msg in
            print("[App] \(msg)")
            if let h = FileHandle(forWritingAtPath: logPath) {
                h.seekToEndOfFile()
                h.write("\(ISO8601DateFormatter().string(from: Date())) [App] \(msg)\n".data(using: .utf8)!)
                h.closeFile()
            } else {
                FileManager.default.createFile(atPath: logPath, contents: "\(msg)\n".data(using: .utf8), attributes: nil)
            }
        }
        appLog("applicationDidFinishLaunching")

        setupMenuBar()
        setupOverlayWindow()

        hotkeyMonitor.startListening(
            onStart: { [weak self] in
                self?.startRecording()
            },
            onStop: { [weak self] in
                self?.stopRecording()
            }
        )

        requestPermissions()

        whisperBridge.initialize { success in
            appLog("WhisperBridge initialized: \(success)")
        }
    }

    // MARK: - 菜单栏
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "mic.fill",
                accessibilityDescription: Constants.App.name
            )
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "开始录音", action: #selector(toggleRecordingAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        let llmItem = NSMenuItem(title: "AI 润色增强", action: #selector(toggleLLM), keyEquivalent: "l")
        llmItem.state = AppConfig.shared.llmEnabled ? .on : .off
        menu.addItem(llmItem)

        let styleMenu = NSMenu()
        styleMenu.title = "润色风格"
        let currentStyle = AppConfig.shared.llmStyle
        for style in LLMBridge.RewriteStyle.allCases {
            let item = NSMenuItem(title: style.displayName, action: #selector(selectStyle(_:)), keyEquivalent: "")
            item.representedObject = style.rawValue
            if style.rawValue == currentStyle { item.state = .on }
            styleMenu.addItem(item)
        }
        let styleParent = NSMenuItem(title: "润色风格", action: nil, keyEquivalent: "")
        styleParent.submenu = styleMenu
        menu.addItem(styleParent)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "偏好设置...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出 \(Constants.App.name)", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func setupOverlayWindow() {
        overlayWindow = OverlayWindow()
        volumeObservation = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.overlayWindow?.updateVolumeLevel(self?.audioRecorder.volumeLevel ?? 0.0)
            }
        }
    }

    private func requestPermissions() {
        if #available(macOS 14.0, *) {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if !granted {
                    DispatchQueue.main.async {
                        self.showPermissionAlert()
                    }
                }
            }
        }

        if !AXIsProcessTrusted() {
            let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true]
            AXIsProcessTrustedWithOptions(options)
        }
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "需要麦克风权限"
        alert.informativeText = "\(Constants.App.name) 需要麦克风权限来进行语音识别。请在系统设置中授权。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }

    // MARK: - 录音控制

    @objc private func toggleRecordingAction() {
        toggleRecording()
    }

    private func toggleRecording() {
        if case .recording = appState {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        appState = .recording
        audioRecorder.startRecording()
    }

    private func stopRecording() {
        appState = .transcribing

        audioRecorder.stopRecording { [weak self] audioData, sampleRate, stopReason in
            guard let self = self else { return }

            switch stopReason {
            case .timeout:
                print("[App] Recording stopped due to timeout")
            case .sizeLimitExceeded:
                print("[App] Recording stopped due to size limit")
            case .error(let err):
                print("[App] Recording stopped due to error: \(err)")
            case .userReleased:
                break
            }

            let duration = Double(audioData.count) / 2.0 / Double(sampleRate)
            guard duration > Constants.Timing.minRecordingDuration else {
                DispatchQueue.main.async {
                    self.appState = .error("录音时间太短")
                    DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Timing.errorDisplayDuration) {
                        self.appState = .idle
                    }
                }
                return
            }

            Task {
                do {
                    let text = try await withRetry(maxRetries: 1) {
                        try await self.transcribeWithBridge(audioData: audioData, sampleRate: sampleRate)
                    }
                    await self.handleTranscriptionResult(text)
                } catch {
                    DispatchQueue.main.async {
                        let friendlyMsg = ErrorPresenter.resolveFriendlyMessage(error)
                        self.appState = .error(friendlyMsg)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            self.appState = .idle
                        }
                    }
                }
            }
        }
    }

    private func transcribeWithBridge(audioData: Data, sampleRate: Int) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
            whisperBridge.transcribe(audioData: audioData, sampleRate: sampleRate) { result in
                switch result {
                case .success(let text):
                    continuation.resume(returning: text)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func handleTranscriptionResult(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            DispatchQueue.main.async {
                self.appState = .error("未识别到语音内容")
                DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Timing.errorDisplayDuration) {
                    self.appState = .idle
                }
            }
            return
        }

        let llmEnabled = AppConfig.shared.llmEnabled
        if llmEnabled {
            await processWithLLMRetry(text: text)
        } else {
            finalizeOutput(text: text)
        }
    }

    // MARK: - LLM 后处理

    private func processWithLLM(text: String) {
        appState = .llmProcessing
        Task { await processWithLLMRetry(text: text) }
    }

    private func processWithLLMRetry(text: String) async {
        appState = .llmProcessing

        let styleStr = AppConfig.shared.llmStyle
        let style = LLMBridge.RewriteStyle(rawValue: styleStr) ?? .clean

        do {
            let rewritten = try await withRetry(maxRetries: 1) {
                try await self.rewriteWithLLM(text: text, style: style)
            }
            finalizeOutput(text: rewritten)
        } catch {
            print("[AppDelegate] LLM retry failed, using original text: \(error.localizedDescription)")
            finalizeOutput(text: text)
        }
    }

    private func rewriteWithLLM(text: String, style: LLMBridge.RewriteStyle) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
            LLMBridge.shared.rewrite(text: text, style: style) { result in
                switch result {
                case .success(let rewritten):
                    continuation.resume(returning: rewritten)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - 最终输出

    private func finalizeOutput(text: String) {
        print("[AppDelegate] Finalizing output with text: \(text.prefix(50))...")
        appState = .ready(text)
        overlayWindow?.show(with: appState)

        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Timing.overlayShowDuration) {
            self.appState = .keyboardOutputting
            self.overlayWindow?.update(self.appState)

            print("[AppDelegate] Starting keyboard emulation")
            self.keyboardEmulator.type(text: text)

            DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Timing.overlayFadeDuration) {
                self.overlayWindow?.hide()
                self.appState = .idle
                print("[AppDelegate] Output cycle completed")
            }
        }
    }

    // MARK: - UI 更新

    private func updateUI() {
        let symbolName = appState.iconName
        statusItem.button?.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: Constants.App.name
        )

        switch appState {
        case .idle:
            overlayWindow?.hide()
        case .recording, .transcribing, .llmProcessing, .keyboardOutputting:
            overlayWindow?.show(with: appState)
        case .ready:
            overlayWindow?.update(appState)
        case .error:
            overlayWindow?.update(appState)
        }
    }

    // MARK: - 菜单动作

    @objc private func toggleLLM() {
        let newValue = !AppConfig.shared.llmEnabled
        AppConfig.shared.llmEnabled = newValue
        LLMBridge.shared.config.enabled = newValue

        if let menu = statusItem.menu,
           let item = menu.items.first(where: { $0.action == #selector(toggleLLM) }) {
            item.state = newValue ? .on : .off
        }
    }

    @objc private func selectStyle(_ sender: NSMenuItem) {
        guard let styleRaw = sender.representedObject as? String else { return }
        AppConfig.shared.llmStyle = styleRaw

        if let menu = statusItem.menu,
           let styleParent = menu.items.first(where: { $0.submenu?.title == "润色风格" }),
           let styleMenu = styleParent.submenu {
            for item in styleMenu.items {
                item.state = (item.representedObject as? String == styleRaw) ? .on : .off
            }
        }
    }

    @objc private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func quitApp() {
        hotkeyMonitor.stopListening()
        whisperBridge.shutdown()
        volumeObservation?.invalidate()
        volumeObservation = nil
        NSApplication.shared.terminate(nil)
    }
}
