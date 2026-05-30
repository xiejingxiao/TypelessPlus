import SwiftUI
import AppKit
import AVFoundation
import ApplicationServices

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
        llmItem.state = UserDefaults.standard.bool(forKey: Constants.Keys.llmEnabled) ? .on : .off
        menu.addItem(llmItem)

        let styleMenu = NSMenu()
        styleMenu.title = "润色风格"
        let currentStyle = UserDefaults.standard.string(forKey: Constants.Keys.rewriteStyle) ?? Constants.Defaults.rewriteStyle
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

        audioRecorder.stopRecording { [weak self] audioData, sampleRate in
            guard let self = self else { return }

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

            self.whisperBridge.transcribe(audioData: audioData, sampleRate: sampleRate) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let text):
                        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            self.appState = .error("未识别到语音内容")
                            DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Timing.errorDisplayDuration) {
                                self.appState = .idle
                            }
                            return
                        }

                        let llmEnabled = UserDefaults.standard.bool(forKey: Constants.Keys.llmEnabled)
                        if llmEnabled {
                            self.processWithLLM(text: text)
                        } else {
                            self.finalizeOutput(text: text)
                        }

                    case .failure(let error):
                        self.appState = .error(error.localizedDescription)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            self.appState = .idle
                        }
                    }
                }
            }
        }
    }

    // MARK: - LLM 后处理

    private func processWithLLM(text: String) {
        appState = .llmProcessing

        let styleStr = UserDefaults.standard.string(forKey: Constants.Keys.rewriteStyle) ?? Constants.Defaults.rewriteStyle
        let style = LLMBridge.RewriteStyle(rawValue: styleStr) ?? .clean

        LLMBridge.shared.rewrite(text: text, style: style) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let rewritten):
                    self.finalizeOutput(text: rewritten)
                case .failure:
                    // LLM 失败，直接使用原始文本（Python 端已做过 TextProcessor）
                    print("[AppDelegate] LLM failed, using original text")
                    self.finalizeOutput(text: text)
                }
            }
        }
    }

    // MARK: - 最终输出

    private func finalizeOutput(text: String) {
        appState = .ready(text)
        overlayWindow?.show(with: appState)

        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Timing.overlayShowDuration) {
            self.keyboardEmulator.type(text: text)
            DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Timing.overlayFadeDuration) {
                self.overlayWindow?.hide()
                self.appState = .idle
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
        case .recording, .transcribing, .llmProcessing:
            overlayWindow?.show(with: appState)
        case .ready:
            overlayWindow?.update(appState)
        case .error:
            overlayWindow?.update(appState)
        }
    }

    // MARK: - 菜单动作

    @objc private func toggleLLM() {
        let newValue = !UserDefaults.standard.bool(forKey: Constants.Keys.llmEnabled)
        UserDefaults.standard.set(newValue, forKey: Constants.Keys.llmEnabled)
        LLMBridge.shared.config.enabled = newValue

        if let menu = statusItem.menu,
           let item = menu.items.first(where: { $0.action == #selector(toggleLLM) }) {
            item.state = newValue ? .on : .off
        }
    }

    @objc private func selectStyle(_ sender: NSMenuItem) {
        guard let styleRaw = sender.representedObject as? String else { return }
        UserDefaults.standard.set(styleRaw, forKey: Constants.Keys.rewriteStyle)

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
        NSApplication.shared.terminate(nil)
    }
}
