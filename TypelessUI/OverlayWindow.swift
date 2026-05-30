import SwiftUI
import AppKit

/// 应用状态枚举（统一状态模型，替代字符串判断）
enum AppState {
    case idle
    case recording
    case transcribing
    case llmProcessing
    case ready(String)
    case error(String)

    var label: String {
        switch self {
        case .idle: return ""
        case .recording: return "正在聆听..."
        case .transcribing: return "识别中..."
        case .llmProcessing: return "AI 润色中..."
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

        if window == nil {
            createWindow()
        }
        window?.orderFrontRegardless()
        window?.makeKey()
    }

    func update(_ appState: AppState) {
        contentState.appState = appState
    }

    func hide() {
        contentState.isVisible = false
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
}

// MARK: - 悬浮窗内容
struct OverlayContentView: View {
    @ObservedObject var state: OverlayContentState

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.12), radius: 16, y: 4)

            HStack(spacing: 12) {
                // 状态图标（基于 enum，不再靠字符串判断）
                Image(systemName: state.appState.iconName)
                    .foregroundColor(state.appState.iconColor)
                    .font(.system(size: 16))

                // 文本内容
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

                // 波形动画（录音中）
                if state.appState.isRecording {
                    waveformAnimation
                }
            }
            .padding(.horizontal, 18)
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
