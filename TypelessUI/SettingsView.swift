import SwiftUI
import AppKit

/// 设置面板（v2 — 精简版：只保留实际生效的功能）
struct SettingsView: View {
    @AppStorage("whisperModel") private var whisperModel: String = "base"
    @AppStorage("language") private var language: String = "auto"
    @AppStorage("llmApiBase") private var llmApiBase: String = "http://127.0.0.1:8000/v1"
    @AppStorage("llmModel") private var llmModel: String = "default"
    @AppStorage("llmEnabled") private var llmEnabled: Bool = false
    @AppStorage("rewriteStyle") private var rewriteStyle: String = "clean"

    private let models = ["tiny", "base", "small", "medium"]
    private let languages = [
        ("auto", "自动检测"),
        ("zh", "中文"),
        ("en", "English"),
        ("ja", "日本語"),
        ("ko", "한국어"),
        ("fr", "Français"),
        ("de", "Deutsch"),
    ]

    @State private var llmStatus: LLMStatus = .unknown

    private enum LLMStatus {
        case unknown, checking, available, unavailable
        var label: String {
            switch self {
            case .unknown: return "未检测"
            case .checking: return "检测中..."
            case .available: return "可用"
            case .unavailable: return "不可用"
            }
        }
        var color: Color {
            switch self {
            case .unknown: return .secondary
            case .checking: return .secondary
            case .available: return .green
            case .unavailable: return .red
            }
        }
    }

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("通用", systemImage: "gearshape")
                }
            llmTab
                .tabItem {
                    Label("AI 助手", systemImage: "sparkles")
                }
            aboutTab
                .tabItem {
                    Label("关于", systemImage: "info.circle")
                }
        }
        .frame(width: 480, height: 380)
    }

    // MARK: - 通用设置
    private var generalTab: some View {
        Form {
            Section("快捷键") {
                HStack {
                    Text("触发录音:")
                    Text("Ctrl + Shift")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.accentColor)
                }
                Text("按住 Ctrl+Shift 开始录音，松开停止")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("语言") {
                Picker("识别语言:", selection: $language) {
                    ForEach(languages, id: \.0) { lang in
                        Text(lang.1).tag(lang.0)
                    }
                }
            }

            Section("Whisper 模型") {
                Picker("模型大小:", selection: $whisperModel) {
                    ForEach(models, id: \.self) { model in
                        Text(modelDescription(model)).tag(model)
                    }
                }
                Text("切换模型需要重启应用")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("调试") {
                Button {
                    openLogDirectory()
                } label: {
                    Label("查看日志", systemImage: "doc.text.magnifyingglass")
                }
                .help("在 Finder 中打开日志目录")
                Text(AppConfig.shared.logFilePath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - AI 助手设置
    private var llmTab: some View {
        Form {
            Section("LLM 增强") {
                Toggle("启用 LLM 后处理", isOn: $llmEnabled)

                if llmEnabled {
                    HStack {
                        Text("API 地址:")
                        TextField("http://127.0.0.1:8000/v1", text: $llmApiBase)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }

                    HStack {
                        Text("模型名称:")
                        TextField("default", text: $llmModel)
                            .textFieldStyle(.roundedBorder)
                    }

                    Picker("润色风格:", selection: $rewriteStyle) {
                        ForEach(LLMBridge.RewriteStyle.allCases, id: \.rawValue) { style in
                            Text(style.displayName).tag(style.rawValue)
                        }
                    }

                    HStack {
                        Text("状态:")
                        Text(llmStatus.label)
                            .foregroundColor(llmStatus.color)
                        Spacer()
                        Button("检测连接") {
                            checkLLMConnection()
                        }
                    }
                }
            }

            Section("说明") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("LLM 增强模式会在语音识别后调用本地 AI 模型进行文本润色，包括：")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("  - 去除填充词和口语重复")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("  - 智能标点和分段")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("  - 语法修正和语气调整")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("  - LLM 不可用时自动降级到本地规则处理")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            if llmEnabled {
                checkLLMConnection()
            }
        }
    }

    // MARK: - 关于
    private var aboutTab: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)

            Text("TypelessPlus")
                .font(.title)
                .fontWeight(.bold)

            Text("v0.3.0")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text("本地优先  隐私至上  开源免费")
                .font(.caption)
                .foregroundColor(.secondary)

            Divider()
                .frame(width: 200)

            Text("完全离线的 macOS 语音识别工具\n支持本地 LLM 增强润色")
                .font(.body)
                .multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(width: 350, height: 280)
    }

    // MARK: - Helpers

    private func modelDescription(_ model: String) -> String {
        switch model {
        case "tiny": return "Tiny (最快, 39MB)"
        case "base": return "Base (推荐, 74MB)"
        case "small": return "Small (准确, 466MB)"
        case "medium": return "Medium (最准, 1.5GB)"
        default: return model
        }
    }

    private func checkLLMConnection() {
        llmStatus = .checking
        var cfg = LLMBridge.Config.fromDefaults()
        cfg.apiBase = llmApiBase
        let bridge = LLMBridge()
        bridge.config = cfg

        bridge.checkHealth { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let available):
                    self.llmStatus = available ? .available : .unavailable
                case .failure:
                    self.llmStatus = .unavailable
                }
            }
        }
    }

    private func openLogDirectory() {
        let logPath = AppConfig.shared.logFilePath
        let logURL = URL(fileURLWithPath: logPath)
        let directoryURL = logURL.deletingLastPathComponent()

        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }

        NSWorkspace.shared.selectFile(logPath, inFileViewerRootedAtPath: directoryURL.path)
    }
}
