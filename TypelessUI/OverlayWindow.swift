import SwiftUI
import AppKit
import Combine

/// 应用状态枚举（统一状态模型，替代字符串判断）
enum AppState {
    case idle
    case recording
    case transcribing
    case llmProcessing
    case keyboardOutputting
    case ready(String)
    case error(String)

    var label: String {
        switch self {
        case .idle: return ""
        case .recording: return "正在聆听..."
        case .transcribing: return "识别中..."
        case .llmProcessing: return "AI 润色中..."
        case .keyboardOutputting: return "输入中..."
        case .ready(let text): return text
        case .error(let msg): return "错误: \(msg)"
        }
    }

    var iconName: String {
        switch self {
        case .idle: return "mic.fill"
        case .recording: return "mic.badge.plus"
        case .transcribing: return "waveform.circle.fill"
        case .llmProcessing: return "sparkles"
        case .keyboardOutputting: return "keyboard"
        case .ready: return "checkmark.circle.fill"
        case .error: return "exclamationmark.circle.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .idle: return .primary
        case .recording: return .red
        case .transcribing: return .blue
        case .llmProcessing: return .purple
        case .keyboardOutputting: return .orange
        case .ready: return .green
        case .error: return .red
        }
    }

    var isProcessing: Bool {
        switch self {
        case .transcribing, .llmProcessing: return true
        default: return false
        }
    }

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}

/// 悬浮预览窗：在屏幕上方显示识别状态和结果
final class OverlayWindow {
    private var window: NSWindow?
    private var hostingView: NSHostingView<OverlayContentView>?
    private var contentState = OverlayContentState()

    func show(with appState: AppState) {
        contentState.appState = appState
        contentState.isVisible = true

        if case .recording = appState {
            contentState.startRecordingTimer()
        }

        if window == nil {
            createWindow()
        }
        window?.orderFrontRegardless()
        window?.makeKey()
    }

    func update(_ appState: AppState) {
        contentState.appState = appState

        if case .recording = appState {
            if contentState.recordingDuration == 0 {
                contentState.startRecordingTimer()
            }
        } else {
            contentState.stopRecordingTimer()
        }
    }

    func updateVolumeLevel(_ level: Double) {
        contentState.volumeLevel = level
    }

    func hide() {
        contentState.isVisible = false
        contentState.stopRecordingTimer()
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Timing.overlayFadeDuration) {
            self.window?.orderOut(nil)
        }
    }

    private func createWindow() {
        let contentView = OverlayContentView(state: contentState)
        let hostingView = NSHostingView(rootView: contentView)
        self.hostingView = hostingView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = false
        window.ignoresMouseEvents = true
        window.center()

        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let windowWidth: CGFloat = 520
            let windowHeight: CGFloat = 100
            let x = screenFrame.midX - windowWidth / 2
            let y = screenFrame.maxY - windowHeight - 20
            window.setFrame(NSRect(x: x, y: y, width: windowWidth, height: windowHeight), display: true)
        }

        window.contentView = hostingView
        self.window = window
    }
}

// MARK: - 状态对象
final class OverlayContentState: ObservableObject {
    @Published var appState: AppState = .idle
    @Published var isVisible: Bool = false
    @Published var volumeLevel: Double = 0.0
    @Published var recordingDuration: TimeInterval = 0
    private var recordingTimer: Timer?
    private var startTime: Date?

    func startRecordingTimer() {
        startTime = Date()
        recordingDuration = 0
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let start = self?.startTime else { return }
            self?.recordingDuration = Date().timeIntervalSince(start)
        }
    }

    func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        startTime = nil
        recordingDuration = 0
    }
}

// MARK: - 悬浮窗内容
struct OverlayContentView: View {
    @ObservedObject var state: OverlayContentState

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.12), radius: 16, y: 4)

            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: state.appState.iconName)
                        .foregroundColor(state.appState.iconColor)
                        .font(.system(size: 16))

                    VStack(alignment: .leading, spacing: 4) {
                        if state.appState.isProcessing {
                            Text(state.appState.label)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                        } else {
                            Text(state.appState.label.isEmpty ? "正在聆听..." : state.appState.label)
                                .font(.system(size: 15))
                                .foregroundColor(.primary)
                                .lineLimit(2)
                        }
                    }

                    Spacer()

                    if state.appState.isRecording {
                        RecordingTimerView(duration: state.recordingDuration)
                    }
                }
                .padding(.horizontal, 18)

                if state.appState.isRecording && AppConfig.shared.enableVolumeIndicator {
                    VolumeIndicatorView(level: state.volumeLevel)
                        .padding(.horizontal, 18)
                }
            }
            .padding(.vertical, 14)
        }
    }

    // MARK: - 波形动画

    private var waveformAnimation: some View {
        HStack(spacing: 2) {
            ForEach(0..<12, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.red.opacity(0.5))
                    .frame(width: 2, height: CGFloat(4 + (i % 5) * 3))
                    .animation(
                        .easeInOut(duration: 0.4)
                            .repeatForever()
                            .delay(Double(i) * 0.05),
                        value: state.isVisible
                    )
            }
        }
    }
}

// MARK: - 音量指示器

struct VolumeIndicatorView: View {
    let level: Double
    @State private var displayLevel: Double = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.1))
                        .frame(height: 6)

                    RoundedRectangle(cornerRadius: 3)
                        .fill(volumeGradient)
                        .frame(width: max(geometry.size.width * CGFloat(displayLevel), 3), height: 6)
                        .animation(.easeOut(duration: 0.1), value: displayLevel)
                }
            }
            .frame(height: 6)
        }
        .onChange(of: level) { _, newValue in
            withAnimation(.easeOut(duration: 0.1)) {
                displayLevel = newValue
            }
        }
        .onAppear {
            displayLevel = level
        }
    }

    private var volumeGradient: LinearGradient {
        let colors: [Color]
        if displayLevel < 0.3 {
            colors = [Color.green.opacity(0.8), Color.green]
        } else if displayLevel < 0.7 {
            colors = [Color.yellow.opacity(0.9), Color.orange]
        } else {
            colors = [Color.orange, Color.red]
        }
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }
}

// MARK: - 录音计时器

struct RecordingTimerView: View {
    let duration: TimeInterval

    private var formattedTime: String {
        let totalSeconds = Int(duration)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var isWarning: Bool {
        duration >= 100
    }

    var body: some View {
        Text(formattedTime)
            .font(.system(size: 15, weight: .monospacedDigit, design: .monospaced))
            .foregroundColor(isWarning ? .red : .secondary)
            .animation(.easeInOut(duration: 0.3), value: isWarning)
    }
}
