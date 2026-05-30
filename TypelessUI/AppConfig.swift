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

    // MARK: - ASR Configuration

    var asrEngine: String {
        didSet { save(.asrEngine, value: asrEngine) }
    }

    var asrModel: String {
        didSet { save(.asrModel, value: asrModel) }
    }

    var language: String {
        didSet { save(.language, value: language) }
    }

    var hotwords: String {
        didSet { save(.hotwords, value: hotwords) }
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
        case asrEngine
        case asrModel
        case language
        case hotwords
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
        static let asrEngine: String = "vibevoice"
        static let asrModel: String = "vibevoice-asr-q4_k.gguf"
        static let language: String = "auto"
        static let hotwords: String = ""
        static let pythonPath: String = "/usr/bin/python3"
        static let projectDir: String = ""

        static var logFilePath: String {
            if let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Logs/TypelessPlus") {
                return logsDir.path + "/typeless_debug.log"
            }
            return "/tmp/typeless_debug.log"
        }
    }

    // MARK: - Initialization

    private init() {
        let defaults = UserDefaults.standard
        self.llmEnabled = Self.load(.llmEnabled, default: Defaults.llmEnabled, from: defaults)
        self.llmStyle = Self.load(.llmStyle, default: Defaults.llmStyle, from: defaults)
        self.llmApiBase = Self.load(.llmApiBase, default: Defaults.llmApiBase, from: defaults)
        self.llmModel = Self.load(.llmModel, default: Defaults.llmModel, from: defaults)
        self.clipboardSafeMode = Self.load(.clipboardSafeMode, default: Defaults.clipboardSafeMode, from: defaults)
        self.inputSpeedDelay = Self.load(.inputSpeedDelay, default: Defaults.inputSpeedDelay, from: defaults)
        self.maxRecordingDuration = Self.load(.maxRecordingDuration, default: Defaults.maxRecordingDuration, from: defaults)
        self.watchdogInterval = Self.load(.watchdogInterval, default: Defaults.watchdogInterval, from: defaults)
        self.autoRetryOnError = Self.load(.autoRetryOnError, default: Defaults.autoRetryOnError, from: defaults)
        self.enableVolumeIndicator = Self.load(.enableVolumeIndicator, default: Defaults.enableVolumeIndicator, from: defaults)
        self.logFilePath = Self.load(.logFilePath, default: Defaults.logFilePath, from: defaults)
        self.asrEngine = Self.load(.asrEngine, default: Defaults.asrEngine, from: defaults)
        self.asrModel = Self.load(.asrModel, default: Defaults.asrModel, from: defaults)
        self.language = Self.load(.language, default: Defaults.language, from: defaults)
        self.hotwords = Self.load(.hotwords, default: Defaults.hotwords, from: defaults)
        self.pythonPath = Self.load(.pythonPath, default: Defaults.pythonPath, from: defaults)
        self.projectDir = Self.load(.projectDir, default: Defaults.projectDir, from: defaults)

        validateAll()
    }

    // MARK: - Persistence

    private static func load<T>(_ key: Key, default defaultValue: T, from defaults: UserDefaults) -> T {
        guard let value = defaults.object(forKey: rawKey(key)) as? T else {
            return defaultValue
        }
        return value
    }

    private func save<T>(_ key: Key, value: T) {
        defaults.set(value, forKey: Self.rawKey(key))
    }

    private static func rawKey(_ key: Key) -> String {
        "com.typeless.appconfig.\(key.rawValue)"
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
        asrEngine = Defaults.asrEngine
        asrModel = Defaults.asrModel
        language = Defaults.language
        hotwords = Defaults.hotwords
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

        let validEngines = ["vibevoice", "whisper"]
        if !validEngines.contains(asrEngine) {
            warnings.append("asrEngine (\(asrEngine)) is not a valid engine, resetting to default")
            asrEngine = Defaults.asrEngine
        }

        let validModels = ["vibevoice-asr-q4_k.gguf", "vibevoice-asr-f16.gguf",
                           "tiny", "base", "small", "medium"]
        if !validModels.contains(asrModel) {
            warnings.append("asrModel (\(asrModel)) is not a known model")
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
          ASR: engine=\(asrEngine), model=\(asrModel), lang=\(language), hotwords=\(hotwords)
          Paths: python=\(pythonPath), project=\(projectDir)
        """
    }
}
