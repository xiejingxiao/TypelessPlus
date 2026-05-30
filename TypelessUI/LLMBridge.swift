import Foundation
import Network

/// 本地 LLM API 客户端（OpenAI 兼容格式）
/// 支持 Ollama、LM Studio、vLLM 等本地推理引擎
///
/// ## F2 增强功能：
/// - ✅ 请求串行队列（防止并发竞态）
/// - ✅ 30秒超时机制（Task Group + race）
/// - ✅ 全面错误处理与降级策略矩阵
/// - ✅ 网络可达性检测（NWPathMonitor）
/// - ✅ 请求取消支持（Task.cancel()）
final class LLMBridge {
    static let shared = LLMBridge()

    // MARK: - 配置

    struct Config {
        var apiBase: String = "http://127.0.0.1:8000/v1"
        var model: String = "default"
        var maxTokens: Int = 512
        var temperature: Double = 0.3
        var timeout: TimeInterval = 15
        var enabled: Bool = false

        static func fromDefaults() -> Config {
            var cfg = Config()
            cfg.apiBase = UserDefaults.standard.string(forKey: "llmApiBase") ?? cfg.apiBase
            cfg.model = UserDefaults.standard.string(forKey: "llmModel") ?? cfg.model
            cfg.enabled = UserDefaults.standard.bool(forKey: "llmEnabled")
            return cfg
        }
    }

    var config = Config.fromDefaults()

    // MARK: - F2: 请求串行队列

    private let operationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        queue.name = "com.typelessplus.llm.request.queue"
        return queue
    }()

    // MARK: - F2: 当前活跃任务（用于取消）

    private var currentCancelHandler: (() -> Void)?

    // MARK: - F2: 网络可达性监控器

    private let networkMonitor = NWPathMonitor()
    private let networkQueue = DispatchQueue(label: "com.typelessplus.llm.network.monitor")
    @Published private(set) var isNetworkAvailable: Bool = true

    // MARK: - F2: Session 级禁用标志

    private var isSessionDisabled: Bool = false

    // MARK: - 初始化

    init() {
        startNetworkMonitoring()
    }

    deinit {
        networkMonitor.cancel()
    }

    // MARK: - 润色风格

    enum RewriteStyle: String, CaseIterable {
        case clean = "clean"
        case formal = "formal"
        case casual = "casual"
        case expand = "expand"
        case compact = "compact"

        var displayName: String {
            switch self {
            case .clean:   return "清理润色"
            case .formal:  return "正式书面"
            case .casual:  return "轻松口语"
            case .expand:  return "扩写润色"
            case .compact: return "精简压缩"
            }
        }

        var systemPrompt: String {
            switch self {
            case .clean:
                return """
                你是语音转写文本的后处理助手。用户给你的是语音识别的原始文本，可能包含：
                - 填充词（嗯、啊、那个、这个、就是说、um、uh、like）
                - 口语重复
                - 缺失的标点
                - 轻微的语法错误

                请执行以下操作：
                1. 去除所有填充词
                2. 去除口语重复
                3. 添加正确的标点符号
                4. 修正明显的语法错误
                5. 保持原文的语气和含义不变

                只输出处理后的文本，不要任何解释或标注。
                """
            case .formal:
                return """
                你是语音转写文本的正式化助手。将口语化的语音识别文本改写为正式的书面文本：
                1. 去除所有填充词和口语重复
                2. 将口语表达转换为正式书面语
                3. 添加正确的标点符号
                4. 优化句子结构和用词
                5. 保持原文的核心含义

                只输出处理后的文本，不要任何解释或标注。
                """
            case .casual:
                return """
                你是语音转写文本的口语化助手。将语音识别文本整理为自然流畅的口语风格：
                1. 去除填充词
                2. 保持口语化的表达方式
                3. 适当添加标点
                4. 让文本读起来像自然的对话

                只输出处理后的文本，不要任何解释或标注。
                """
            case .expand:
                return """
                你是语音转写文本的扩写助手。在语音识别文本的基础上进行适度扩写：
                1. 去除填充词和重复
                2. 补充必要的上下文和细节
                3. 添加正确的标点
                4. 让表述更完整流畅

                只输出扩写后的文本，不要任何解释或标注。
                """
            case .compact:
                return """
                你是语音转写文本的精简助手。将语音识别文本压缩为简洁精炼的表述：
                1. 去除填充词和冗余
                2. 压缩啰嗦的表述
                3. 保留核心信息
                4. 适当添加标点

                只输出精简后的文本，不要任何解释或标注。
                """
            }
        }
    }

    // MARK: - F2: 增强版润色接口

    func rewrite(text: String, style: RewriteStyle = .clean, completion: @escaping (Result<String, Error>) -> Void) {
        guard config.enabled else {
            completion(.failure(LLMBridgeError.disabled))
            return
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion(.success(""))
            return
        }

        guard !isSessionDisabled else {
            print("[LLMBridge] Session disabled due to auth error")
            completion(.failure(LLMBridgeError.sessionDisabled))
            return
        }

        guard isNetworkAvailable else {
            print("[LLMBridge] Network offline, skipping LLM call")
            completion(.failure(LLMBridgeError.networkOffline))
            return
        }

        cancelCurrentRequest()

        let operation = AsyncBlockOperation { [weak self] in
            await self?.performRewrite(text: text, style: style, completion: completion)
        }

        operationQueue.addOperation(operation)
    }

    // MARK: - F2: 执行润色请求（含超时和重试）

    private func performRewrite(text: String, style: RewriteStyle, completion: @escaping (Result<String, Error>) -> Void) async {
        let task = Task {
            await withTaskGroup(of: Result<String, Error>.self) { group in
                group.addTask {
                    await self.executeLLMRequest(text: text, style: style)
                }

                group.addTask {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    return .failure(LLMBridgeError.timeout)
                }

                if let result = await group.next() {
                    group.cancelAll()
                    return result
                }
                return .failure(LLMBridgeError.timeout)
            }
        }

        currentCancelHandler = { task.cancel() }

        let result = await task.value

        switch result {
        case .success(let rewrittenText):
            completion(.success(rewrittenText))
        case .failure(let error):
            handleLLMError(error, originalText: text, completion: completion)
        }
    }

    // MARK: - F2: 执行实际 LLM 请求

    private func executeLLMRequest(text: String, style: RewriteStyle, retryCount: Int = 0) async -> Result<String, Error> {
        await withCheckedContinuation { continuation in
            guard let url = URL(string: "\(config.apiBase)/chat/completions") else {
                print("[LLMBridge] ❌ Invalid API base URL: \(config.apiBase)")
                continuation.resume(returning: .failure(LLMBridgeError.connectionFailed("Invalid API base URL: \(config.apiBase)")))
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = config.timeout

            let body: [String: Any] = [
                "model": config.model,
                "messages": [
                    ["role": "system", "content": style.systemPrompt],
                    ["role": "user", "content": text],
                ],
                "max_tokens": config.maxTokens,
                "temperature": config.temperature,
            ]

            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                if Task.isCancelled {
                    continuation.resume(returning: .failure(LLMBridgeError.cancelled))
                    return
                }

                if let error = error {
                    let nsError = error as NSError
                    let statusCode = (response as? HTTPURLResponse)?.statusCode

                    if let code = statusCode {
                        switch code {
                        case 401, 403:
                            self?.isSessionDisabled = true
                            continuation.resume(returning: .failure(LLMBridgeError.authFailed("API Key 无效或权限不足")))
                        case 429:
                            if retryCount < 1 {
                                Task {
                                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                                    let retryResult = await self?.executeLLMRequest(text: text, style: style, retryCount: retryCount + 1) ?? .failure(error)
                                    continuation.resume(returning: retryResult)
                                }
                                return
                            } else {
                                continuation.resume(returning: .failure(LLMBridgeError.rateLimited("请求过于频繁，请稍后再试")))
                            }
                        case 500...599:
                            if retryCount < 1 {
                                Task {
                                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                                    let retryResult = await self?.executeLLMRequest(text: text, style: style, retryCount: retryCount + 1) ?? .failure(error)
                                    continuation.resume(returning: retryResult)
                                }
                                return
                            } else {
                                continuation.resume(returning: .failure(LLMBridgeError.serverError("服务器错误 (\(code))")))
                            }
                        default:
                            continuation.resume(returning: .failure(LLMBridgeError.connectionFailed(error.localizedDescription)))
                        }
                    } else if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorNotConnectedToInternet {
                        continuation.resume(returning: .failure(LLMBridgeError.networkOffline))
                    } else {
                        continuation.resume(returning: .failure(LLMBridgeError.connectionFailed(error.localizedDescription)))
                    }
                    return
                }

                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continuation.resume(returning: .failure(LLMBridgeError.invalidResponse))
                    return
                }

                if let apiError = json["error"] as? [String: Any],
                   let message = apiError["message"] as? String {
                    continuation.resume(returning: .failure(LLMBridgeError.apiError(message)))
                    return
                }

                if let choices = json["choices"] as? [[String: Any]],
                   let firstChoice = choices.first,
                   let message = firstChoice["message"] as? [String: Any],
                   let content = message["content"] as? String {
                    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: .success(trimmed))
                } else {
                    continuation.resume(returning: .failure(LLMBridgeError.invalidResponse))
                }
            }.resume()
        }
    }

    // MARK: - F2: 错误处理与降级策略

    private func handleLLMError(_ error: Error, originalText: String, completion: @escaping (Result<String, Error>) -> Void) {
        switch error {
        case LLMBridgeError.timeout:
            print("[LLMBridge] ⏰ Request timeout, using original text")
            NotificationCenter.default.post(name: .llmToastNotification, object: nil, userInfo: [
                "message": "AI 暂时繁忙",
                "type": "warning"
            ])
            completion(.success(originalText))

        case LLMBridgeError.authFailed(let message):
            print("[LLMBridge] 🔒 Auth failed: \(message)")
            NotificationCenter.default.post(name: .llmAlertNotification, object: nil, userInfo: [
                "title": "API 配置错误",
                "message": "请检查 API Key 或服务地址配置"
            ])
            completion(.failure(error))

        case LLMBridgeError.rateLimited(let message):
            print("[LLMBridge] ⚠️ Rate limited: \(message)")
            NotificationCenter.default.post(name: .llmToastNotification, object: nil, userInfo: [
                "message": "稍等片刻...",
                "type": "info"
            ])
            completion(.success(originalText))

        case LLMBridgeError.serverError(let message):
            print("[LLMBridge] 💥 Server error: \(message)")
            NotificationCenter.default.post(name: .llmToastNotification, object: nil, userInfo: [
                "message": "AI 服务异常",
                "type": "error"
            ])
            completion(.success(originalText))

        case LLMBridgeError.networkOffline:
            print("[LLMBridge] 📡 Network offline, silent degradation")
            completion(.success(originalText))

        case LLMBridgeError.cancelled:
            print("[LLMBridge] ❌ Request cancelled by user")
            completion(.failure(error))

        default:
            print("[LLMBridge] ❓ Unknown error: \(error.localizedDescription)")
            completion(.failure(error))
        }
    }

    // MARK: - F2: 取消当前请求

    func cancelCurrentRequest() {
        currentCancelHandler?()
        currentCancelHandler = nil
        operationQueue.cancelAllOperations()
    }

    // MARK: - F2: 网络监控

    private func startNetworkMonitoring() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isNetworkAvailable = (path.status == .satisfied)
                if path.status != .satisfied {
                    print("[LLMBridge] 📡 Network status changed: \(path.status)")
                }
            }
        }
        networkMonitor.start(queue: networkQueue)
    }

    // MARK: - 重置 session 状态

    func resetSession() {
        isSessionDisabled = false
        cancelCurrentRequest()
        print("[LLMBridge] ✅ Session reset")
    }

    // MARK: - 健康检查

    func checkHealth(completion: @escaping (Result<Bool, Error>) -> Void) {
        let url = URL(string: "\(config.apiBase)/models")!

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(LLMBridgeError.connectionFailed(error.localizedDescription)))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                completion(.success(false))
                return
            }
            completion(.success(true))
        }.resume()
    }

    // MARK: - 获取可用模型

    func listModels(completion: @escaping (Result<[String], Error>) -> Void) {
        let url = URL(string: "\(config.apiBase)/models")!

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(LLMBridgeError.connectionFailed(error.localizedDescription)))
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["data"] as? [[String: Any]] else {
                completion(.success([]))
                return
            }

            let modelIds = models.compactMap { $0["id"] as? String }
            completion(.success(modelIds))
        }.resume()
    }
}

// MARK: - F2: 异步 Block 操作（用于队列）

private class AsyncBlockOperation: Operation {
    private let block: () async -> Void
    private var task: Task<Void, Never>?

    init(_ block: @escaping () async -> Void) {
        self.block = block
    }

    override func main() {
        let semaphore = DispatchSemaphore(value: 0)
        task = Task {
            await block()
            semaphore.signal()
        }
        semaphore.wait()
    }

    override func cancel() {
        super.cancel()
        task?.cancel()
    }
}

// MARK: - F2: 通知名称扩展

extension Notification.Name {
    static let llmToastNotification = Notification.Name("com.typelessplus.llm.toast")
    static let llmAlertNotification = Notification.Name("com.typelessplus.llm.alert")
}

// MARK: - F2: 增强版错误类型

enum LLMBridgeError: LocalizedError {
    case disabled
    case connectionFailed(String)
    case invalidResponse
    case apiError(String)
    case apiKeyInvalid
    case timeout
    case networkOffline
    case authFailed(String)
    case rateLimited(String)
    case serverError(String)
    case sessionDisabled
    case cancelled

    var errorDescription: String? {
        switch self {
        case .disabled:
            return "LLM 增强功能未启用"
        case .connectionFailed(let msg):
            return "LLM 服务连接失败: \(msg)"
        case .invalidResponse:
            return "LLM 服务响应格式无效"
        case .apiError(let msg):
            return "LLM API 错误: \(msg)"
        case .apiKeyInvalid:
            return "API 密钥无效"
        case .timeout:
            return "LLM 请求超时"
        case .networkOffline:
            return "网络不可用"
        case .authFailed(let msg):
            return "认证失败: \(msg)"
        case .rateLimited(let msg):
            return "请求频率限制: \(msg)"
        case .serverError(let msg):
            return "服务器错误: \(msg)"
        case .sessionDisabled:
            return "LLM 会话已禁用（认证错误）"
        case .cancelled:
            return "请求已取消"
        }
    }

    var userMessage: String? {
        switch self {
        case .timeout:
            return "AI 暂时繁忙"
        case .authFailed:
            return "请检查 API 配置"
        case .rateLimited:
            return "稍等片刻..."
        case .serverError:
            return "AI 服务异常"
        case .networkOffline, .disabled, .sessionDisabled:
            return nil
        default:
            return errorDescription
        }
    }

    var friendlyMessage: String {
        switch self {
        case .disabled:
            return "LLM 增强功能当前已关闭，可在设置中开启"
        case .connectionFailed(let msg):
            if msg.contains("refused") || msg.contains("Connection") {
                return "无法连接到 LLM 服务，请确认服务已启动（如 Ollama、LM Studio）"
            }
            return "LLM 服务连接失败: \(msg)"
        case .invalidResponse:
            return "LLM 返回了异常响应，可能模型不支持当前请求格式"
        case .apiError(let msg):
            if msg.contains("401") || msg.contains("Unauthorized") || msg.contains("invalid_api_key") {
                return "API 密钥无效或已过期，请检查 LLM 服务配置"
            } else if msg.contains("429") || msg.contains("rate_limit") {
                return "请求过于频繁，请稍后再试"
            } else if msg.contains("500") || msg.contains("503") {
                return "LLM 服务内部错误，请检查服务状态"
            }
            return "LLM API 报告错误: \(msg)"
        case .apiKeyInvalid:
            return "API 密钥无效，请在 AI 助手设置中更新密钥"
        case .timeout:
            return "LLM 响应超时，可尝试切换更小的模型或增加超时时间"
        case .networkOffline:
            return "网络不可用，请检查网络连接"
        case .authFailed(let msg):
            return "认证失败: \(msg)，请检查 API 配置"
        case .rateLimited:
            return "请求过于频繁，请稍后再试"
        case .serverError(let msg):
            return "AI 服务异常: \(msg)"
        case .sessionDisabled:
            return "LLM 会话已禁用，请在设置中重置"
        case .cancelled:
            return "请求已取消"
        }
    }

    var shouldFallbackToOriginal: Bool {
        switch self {
        case .timeout, .rateLimited, .serverError, .networkOffline:
            return true
        default:
            return false
        }
    }
}
