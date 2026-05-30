import Foundation

/// 集中管理 UserDefaults keys 和应用常量
///
/// - Important: `Constants.Keys` 中的 UserDefaults key 已标记为 deprecated。
///   请使用 `AppConfig.shared` 统一访问配置项。
///   示例: `AppConfig.shared.llmEnabled` 替代 `UserDefaults.standard.bool(forKey: Constants.Keys.llmEnabled)`
enum Constants {

    // MARK: - UserDefaults Keys (Deprecated)

    @available(*, deprecated, message: "Use AppConfig.shared instead. Example: AppConfig.shared.llmEnabled")
    enum Keys {
        static let whisperModel = "whisperModel"
        static let language = "language"
        static let llmEnabled = "llmEnabled"
        static let llmApiBase = "llmApiBase"
        static let llmModel = "llmModel"
        static let rewriteStyle = "rewriteStyle"
        static let pythonPath = "pythonPath"
        static let projectDir = "projectDir"
    }

    // MARK: - Defaults

    enum Defaults {
        static let whisperModel = "base"
        static let language = "auto"
        static let llmApiBase = "http://127.0.0.1:8000/v1"
        static let llmModel = "default"
        static let rewriteStyle = "clean"
        static let llmEnabled = false
    }

    // MARK: - Timing

    enum Timing {
        static let settleInterval: Double = 0.10
        static let pollInterval: Double = 0.03
        static let overlayShowDuration: Double = 0.8
        static let overlayFadeDuration: Double = 0.3
        static let clipboardRestoreDelay: Double = 0.5
        static let minRecordingDuration: Double = 0.3
        static let errorDisplayDuration: Double = 1.5
    }

    // MARK: - App Info

    enum App {
        static let name = "TypelessPlus"
        static let version = "0.3.0"
        static let bundleId = "com.typeless.plusplus"
    }
}
