import Foundation
import Observation
import Combine

@Observable
final class AppConfig {
    static let shared = AppConfig()

    private let defaults = UserDefaults.standard
    private let suiteName = "com.typeless.appconfig"

    // MARK: - LLM Configuration

    var llmEnabled: Bool {
        didSet { save(.llmEnabled, value: llmEnabled) }
    }

    var llmStyle: String {
        didSet { save(.llmStyle, value: llmStyle) }
    }

    var llmApiBase: String {
        didSet { save(.llmApiBase, value: llmApiBase) }
    }

    var llmModel: String {
        didSet { save(.llmModel, value: llmModel) }
    }

    // MARK: - Keyboard Configuration

    var clipboardSafeMode: Bool {
        didSet { save(.clipboardSafeMode, value: clipboardSafeMode) }
    }

    var inputSpeedDelay: Int {
        didSet {
            let clamped = max(0, min(inputSpeedDelay, 500))
            if clamped != inputSpeedDelay {
                inputSpeedDelay = clamped
            }
            save(.inputSpeedDelay, value: inputSpeedDelay)
        }
    }

    // MARK: - Stability Configuration

    var maxRecordingDuration: TimeInterval {
        didSet {
            let clamped = max(1.0, min(maxRecordingDuration, 300.0))
            if clamped != maxRecordingDuration {
                maxRecordingDuration = clamped
            }
            save(.maxRecordingDuration, value: maxRecordingDuration)
        }
    }

    var watchdogInterval: TimeInterval {
        didSet {
            let clamped = max(0.5, min(watchdogInterval, 60.0))
            if clamped != watchdogInterval {
                watchdogInterval = clamped
            }
            save(.watchdogInterval, value: watchdogInterval)
        }
    }

    var autoRetryOnError: Bool {
        didSet { save(.autoRetryOnError, value: autoRetryOnError) }
    }

    // MARK: - UX Configuration

    var enableVolumeIndicator: Bool {
        didSet { save(.enableVolumeIndicator, value: enableVolumeIndicator) }
    }

    var logFilePath: String {
        didSet { save(.logFilePath, value: logFilePath) }
    }

    // MARK: - Whisper Configuration

    var whisperModel: String {
        didSet { save(.whisperModel, value: whisperModel) }
    }

    var language: String {
        didSet { save(.language, value: language) }
    }

    // MARK: - Paths

    var pythonPath: String {
        didSet { save(.pythonPath, value: pythonPath) }
    }

    var projectDir: String {
        didSet { save(.projectDir, value: projectDir) }
    }

    // MARK: - Keys

    enum Key: String, CaseIterable {
        case llmEnabled
        case llmStyle
        case llmApiBase
        case llmModel
        case clipboardSafeMode
        case inputSpeedDelay
        case maxRecordingDuration
        case watchdogInterval
        case autoRetryOnError
        case enableVolumeIndicator
        case logFilePath
        case whisperModel
        case language
        case pythonPath
        case projectDir
    }

    // MARK: - Default Values

    struct Defaults {
        static let llmEnabled: Bool = false
        static let llmStyle: String = "clean"
        static let llmApiBase: String = "http://127.0.0.1:8000/v1"
        static let llmModel: String = "default"
        static let clipboardSafeMode: Bool = true
        static let inputSpeedDelay: Int = 8
        static let maxRecordingDuration: TimeInterval = 120.0
        static let watchdogInterval: TimeInterval = 5.0
        static let autoRetryOnError: Bool = true
        static let enableVolumeIndicator: Bool = true
        static let whisperModel: String = "base"
        static let language: String = "auto"
        static let pythonPath: String = "/usr/bin/python3"
        static let projectDir: String = ""

        static var logFilePath: String {
            let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Logs/TypelessPlus")?.path ?? "/tmp"
            return "\(logsDir)/typeless_debug.log"
        }
    }

    // MARK: - Initialization

    private init() {
        self.llmEnabled = load(.llmEnabled, default: Defaults.llmEnabled)
        self.llmStyle = load(.llmStyle, default: Defaults.llmStyle)
        self.llmApiBase = load(.llmApiBase, default: Defaults.llmApiBase)
        self.llmModel = load(.llmModel, default: Defaults.llmModel)
        self.clipboardSafeMode = load(.clipboardSafeMode, default: Defaults.clipboardSafeMode)
        self.inputSpeedDelay = load(.inputSpeedDelay, default: Defaults.inputSpeedDelay)
        self.maxRecordingDuration = load(.maxRecordingDuration, default: Defaults.maxRecordingDuration)
        self.watchdogInterval = load(.watchdogInterval, default: Defaults.watchdogInterval)
        self.autoRetryOnError = load(.autoRetryOnError, default: Defaults.autoRetryOnError)
        self.enableVolumeIndicator = load(.enableVolumeIndicator, default: Defaults.enableVolumeIndicator)
        self.logFilePath = load(.logFilePath, default: Defaults.logFilePath)
        self.whisperModel = load(.whisperModel, default: Defaults.whisperModel)
        self.language = load(.language, default: Defaults.language)
        self.pythonPath = load(.pythonPath, default: Defaults.pythonPath)
        self.projectDir = load(.projectDir, default: Defaults.projectDir)

        validateAll()
    }

    // MARK: - Persistence

    private func load<T>(_ key: Key, default defaultValue: T) -> T {
        guard let value = defaults.object(forKey: rawKey(key)) as? T else {
            return defaultValue
        }
        return value
    }

    private func save<T>(_ key: Key, value: T) {
        defaults.set(value, forKey: rawKey(key))
    }

    private func rawKey(_ key: Key) -> String {
        "\(suiteName).\(key.rawValue)"
    }

    func resetToDefaults() {
        llmEnabled = Defaults.llmEnabled
        llmStyle = Defaults.llmStyle
        llmApiBase = Defaults.llmApiBase
        llmModel = Defaults.llmModel
        clipboardSafeMode = Defaults.clipboardSafeMode
        inputSpeedDelay = Defaults.inputSpeedDelay
        maxRecordingDuration = Defaults.maxRecordingDuration
        watchdogInterval = Defaults.watchdogInterval
        autoRetryOnError = Defaults.autoRetryOnError
        enableVolumeIndicator = Defaults.enableVolumeIndicator
        logFilePath = Defaults.logFilePath
        whisperModel = Defaults.whisperModel
        language = Defaults.language
        pythonPath = Defaults.pythonPath
        projectDir = Defaults.projectDir
    }

    // MARK: - Validation

    @discardableResult
    func validateAll() -> [String] {
        var warnings: [String] = []

        if maxRecordingDuration < 1.0 || maxRecordingDuration > 300.0 {
            warnings.append("maxRecordingDuration (\(maxRecordingDuration)) out of range [1.0, 300.0], resetting to default")
            maxRecordingDuration = Defaults.maxRecordingDuration
        }

        if watchdogInterval < 0.5 || watchdogInterval > 60.0 {
            warnings.append("watchdogInterval (\(watchdogInterval)) out of range [0.5, 60.0], resetting to default")
            watchdogInterval = Defaults.watchdogInterval
        }

        if inputSpeedDelay < 0 || inputSpeedDelay > 500 {
            warnings.append("inputSpeedDelay (\(inputSpeedDelay)) out of range [0, 500], resetting to default")
            inputSpeedDelay = Defaults.inputSpeedDelay
        }

        if !isValidURL(llmApiBase) {
            warnings.append("llmApiBase (\(llmApiBase)) is not a valid URL")
        }

        if !FileManager.default.fileExists(atPath: pythonPath) {
            warnings.append("pythonPath (\(pythonPath)) does not exist on disk")
        }

        let validStyles = ["clean", "formal", "casual", "concise"]
        if !validStyles.contains(llmStyle) {
            warnings.append("llmStyle (\(llmStyle)) is not a valid style, resetting to default")
            llmStyle = Defaults.llmStyle
        }

        let validModels = ["tiny", "base", "small", "medium"]
        if !validModels.contains(whisperModel) {
            warnings.append("whisperModel (\(whisperModel)) is not a valid model, resetting to default")
            whisperModel = Defaults.whisperModel
        }

        if !warnings.isEmpty {
            print("[AppConfig] Validation warnings:")
            warnings.forEach { print("  - \($0)") }
        }

        return warnings
    }

    // MARK: - Helpers

    private func isValidURL(_ string: String) -> Bool {
        guard let url = URL(string: string) else { return false }
        return url.scheme != nil && url.host != nil
    }

    // MARK: - Description

    var description: String {
        """
        AppConfig:
          LLM: enabled=\(llmEnabled), style=\(llmStyle), api=\(llmApiBase), model=\(llmModel)
          Keyboard: clipboardSafe=\(clipboardSafeMode), speedDelay=\(inputSpeedDelay)ms
          Stability: maxRecord=\(maxRecordingDuration)s, watchdog=\(watchdogInterval)s, retry=\(autoRetryOnError)
          UX: volumeIndicator=\(enableVolumeIndicator), log=\(logFilePath)
          Whisper: model=\(whisperModel), lang=\(language)
          Paths: python=\(pythonPath), project=\(projectDir)
        """
    }
}
