import Foundation

/// 本地 LLM API 客户端（OpenAI 兼容格式）
/// 支持 Ollama、LM Studio、vLLM 等本地推理引擎
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

    // MARK: - 润色风格

    enum RewriteStyle: String, CaseIterable {
        case clean = "clean"       // 清理润色（去填充词、修语法、加标点）
        case formal = "formal"     // 正式书面
        case casual = "casual"     // 轻松口语
        case expand = "expand"     // 扩写润色
        case compact = "compact"   // 精简压缩

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

    // MARK: - 润色接口

    func rewrite(text: String, style: RewriteStyle = .clean, completion: @escaping (Result<String, Error>) -> Void) {
        guard config.enabled else {
            completion(.failure(LLMBridgeError.disabled))
            return
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion(.success(""))
            return
        }

        let url = URL(string: "\(config.apiBase)/chat/completions")!

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

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                // 网络错误，可能是 LLM 服务未启动
                print("[LLMBridge] Request error: \(error.localizedDescription)")
                completion(.failure(LLMBridgeError.connectionFailed(error.localizedDescription)))
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(LLMBridgeError.invalidResponse))
                return
            }

            // 检查 API 错误
            if let apiError = json["error"] as? [String: Any],
               let message = apiError["message"] as? String {
                completion(.failure(LLMBridgeError.apiError(message)))
                return
            }

            // 提取响应文本
            if let choices = json["choices"] as? [[String: Any]],
               let firstChoice = choices.first,
               let message = firstChoice["message"] as? [String: Any],
               let content = message["content"] as? String {
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                completion(.success(trimmed))
            } else {
                completion(.failure(LLMBridgeError.invalidResponse))
            }
        }.resume()
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

// MARK: - 错误类型

enum LLMBridgeError: LocalizedError {
    case disabled
    case connectionFailed(String)
    case invalidResponse
    case apiError(String)
    case timeout

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
        case .timeout:
            return "LLM 请求超时"
        }
    }
}
