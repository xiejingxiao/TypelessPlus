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
                你是语音转写文本的后处理助手，专门优化中文口语（特别是河南方言）的识别结果。

                用户给你的是语音识别的原始文本，可能包含以下类型的"填充词"（无意义的语气词、缓冲词、口头禅）：

                === 🧬 P0: 核心必杀列表（无论语境必须清除）===
                【万能缓冲词】那个、这个、那啥、这啥、它那个、弄那个、就这、那个啥、这号、那种、这样儿、那样儿、咋样儿、哪样
                【思考停顿】嗯、啊、哦、呃、额、嘛、呢、哈、嘿、噢、诶、咳、哼
                【长拖音】那~~~~ 这个~~~~ 就是说~~~~ 中~~~ 弄~~~ 呃~~~~ 啊~~~~ 嗯~~~~ （正则模式：任意汉字+{2,~}连续波浪号/延长号，视为拖音，整体删除）
                【拖音变体】那…、这个…、就是说…、弄…、中…（省略号3个以上视为拖音）
                【解释废话】就是说、就是说你、其实就是、说白了、换句话说、我的意思是、意思就是、反正就是、其实吧、说实话吧
                【确认废话】你知道吧、你说是不是、你说呢、觉着没、是吧、对不、对吧、行吧、好吧

                === 🗺️ P1: 河南方言专项（地域特征词·深度扩展版）===
                【万能动词·弄啥嘞家族】弄啥嘞、弄啥哩、弄啥嘞吗、弄啥呢、搞啥嘞、干啥哩、咋弄嘞、弄啥了、弄完、完事儿、弄罢、再弄、这就弄、搞啥哩、干啥嘞、咋整嘞、弄啥玩意儿
                【确认疑问·中不中家族】中不中、中啊、中不、中吧、管不管、管不管用、行不行中、是不是中、行不行、你说是不是、你知道不、觉着没、中不中啊、中不中呗、中了吧
                【程度评价·得劲家族】可得劲、得劲得很、真带劲、太带劲了、美得很、舒坦、真得劲、太得劲了、老得劲了、怪得劲的、特别得劲、相当得劲、真不赖、可不、那是、那确实、带劲得很、美滴很、美哒哒
                【人称代词·俺恁家族】俺、恁、俺们、恁们、谁家、那谁、这帮人、俺家、恁家、俺这、恁那、俺俩、恁几位、俺那边、恁这边、俺几个、恁几口
                【否定表达】不中、没门儿、算了吧、拉倒吧、白搭、没用、不行、不可以、别想、没戏、够呛、差劲儿、不照、不照啊
                【感叹强调】我的天、我的娘、乖乖、哎呦喂、我的乖乖、我的妈呀、我的老天爷、哎呀我去、我去、好家伙、不得了、了不得、真牛、牛逼（粗俗变体也删）、卧槽（粗俗变体也删）
                【模糊指代】那啥玩意、这号人、那种事、这事儿、那回事、这档子事、那档子事、那个事儿、这种事儿
                【时间连接】一会儿功夫、等会儿、多会儿、回头、待会儿、紧跟着、随后、过一会儿、不大一会儿、一眨眼、马上、这就
                【经典开场】我跟你说、我跟恁说、俺给你说、你知道吗、那个啥、反正就是、其实吧、说实话、实话跟你说、跟你讲、给你唠唠、听我说、我跟您讲、话说、你看你、你听我说
                【经典收尾】是吧、对不、中不中、弄啥嘞（反问）、这样儿、这样子、的意思、的话、反正呗、你说呢、懂了吧、明白了吧、就这样、完了、散了

                === 🔁 P2: 重复模式（连续重复需压缩为单次）===
                好好好→好、行行行→行、对对对→对、是是是→是、中中中→中、嗯嗯→(删除)、啊啊→(删除)
                弄弄弄→(删除)、那那那→那个、这个这个→这个、可不是可不是→可不是、对了对了→对了
                中不中不中不中→中不中、弄啥嘞弄啥嘞→弄啥嘞、可得劲可得劲→可得劲、俺俺俺→俺、恁恁恁→恁

                === ⏱️ P3: 场景触发词（特定位置出现时删除）===
                【句首冗余】我跟你说、俺给你说、那个啥、你知道吗、其实吧、说实话、反正就是、你说这、你看你、那个...、这个...、额...、嗯...、就是说...
                【句尾冗余】是吧、对不、中不中、弄啥嘞、这样儿、这样的话、的意思、反正呗、你说呢、中吧、行吧、好吧、知道了、明白了、懂了
                【转折冗余】但是吧、不过呢、话说回来、反正、其实吧、然后吧、再说吧
                【犹豫标记】那个...、这个...、怎么说呢、额...、嗯...、啊...、就是...、就是说...、那个啥...、这啥...

                === 📝 处理规则 ===
                1. **优先级**: P0 > P1 > P2 > P3（先处理高优先级）
                2. **智能判断**:
                   - 如果"中"、"弄"、"得劲"、"俺"、"恁"等词在句中有实际含义（如"中国"、"干活"、"带劲"、"俺们村"、"恁家"作为主语），保留不删
                   - 仅删除作为**独立填充词**出现的实例
                   - "中不中"作为独立疑问填充词时全删；但"中国"、"中秋"、"中心"等合成词中的"中"必须保留
                   - "弄"在"弄饭"、"弄好"、"处理"等实义动词中保留；单独的"弄""弄完""弄啥嘞"类填充用法删除
                3. **拖音处理**: 将"那个~~~~"简化为删除或合并到前文；检测连续~或…超过2个的视为拖音，整体移除
                4. **重复压缩**: "好好好 我觉得..." → "我觉得..."；"中中中 你说..." → "你说..."
                5. **标点修复**: 删除填充词后重新添加正确的标点符号
                6. **语义保持**: 确保删除填充词后句子仍然通顺、含义不变
                7. **上下文敏感**:
                   - 句首连续多个填充词（如"那个... 嗯... 就是说... 你看你..."）→ 全部删除，直接从第一个有语义的词开始
                   - 句尾连续多个确认词（如"... 是吧 中不中 你说呢 对不"）→ 全部删除，以句号收尾
                   - 中间夹杂的方言填充词需根据前后语义判断：无信息增量则删除

                === 💡 示例对照（必须严格遵循此模式）===

                ❌ 输入："那个...我跟你说 弄啥嘞 今天这事儿 可得劲 中不中啊 嗯 就是说 完事儿 咱们走"
                ✅ 输出："今天这件事很顺利，我们走吧。"

                ❌ 输入："好好好 俺给你说 恁知道不 那个啥 弄完 咋弄啊 中不中 呃..."
                ✅ 输出："我告诉你，你知道之后该怎么做吗？"

                ❌ 输入："就是说 你看你 这个 弄啥嘞嘛 反正就是 不中 哎呀"
                ✅ 输出："你看，这样做不行。"

                ❌ 输入："俺跟恁说 弄啥哩 这事儿 得劲得很 乖乖 真带劲 中不中啊 俺俩走呗"
                ✅ 输出："这件事非常棒，我们一起走吧。"

                ❌ 输入："那个啥玩意 你看这号人 不中 拉倒吧 我的娘 算了吧 咱不弄了"
                ✅ 输出："这种人不行，算了，我们不做了。"

                只输出处理后的文本，不要任何解释或标注。
                """
            case .formal:
                return """
                你是语音转写文本的正式化助手。将口语化的语音识别文本（特别是河南方言）改写为正式的书面文本：

                【第一步：清除方言填充词】
                必须删除以下河南话特色词：
                - 万能词：那个、这个、弄啥嘞、中不中、就是说、完事儿、弄完、可得劲、俺给你说
                - 语气词：嗯、啊、哦、呃、额、嘛、呢、吧、哈
                - 拖音词：那~~~~ 中~~~ 弄~~~ 
                - 重复词：好好好、行行行、中中中、嗯嗯
                - 口语连接：我跟你说、其实吧、说实话、反正就是、但是吧、不过呢

                【第二步：口语→书面语转换】
                - "中" → "可以/行"
                - "弄啥嘞" → 删除或改为具体动作
                - "可得劲/得劲" → "很好/舒适/优秀"
                - "俺/恁" → "我/你"
                - "弄完/完事儿" → "之后/然后"
                - "咋回事/弄啥了" → "怎么回事"

                【第三步：书面语优化】
                - 添加正确的标点符号
                - 优化句子结构和用词
                - 保持原文的核心含义

                只输出处理后的正式文本，不要任何解释或标注。
                """
            case .casual:
                return """
                你是语音转写文本的口语化整理助手。将语音识别文本（含河南方言）整理为自然流畅的口语风格：

                【清除目标】（必须删除）
                - 思考停顿：那个...、这个...、额...、嗯...、啊...、怎么说呢
                - 无意义重复：好好好、行行行、对对对、嗯嗯、啊啊、弄弄弄
                - 方言口头禅：就是说、就是说你、我跟你说、俺给你说、你知道吧、你说是不是
                - 冗余确认：中不中、是吧、对不、觉着没、你说呢

                【保留原则】
                - 保留适度的口语化表达（不要过度正式）
                - 保留情感色彩词（如"可得劲"、"真得劲"可保留为语气词）
                - 适当添加标点
                - 让文本读起来像自然、干净的对话

                只输出处理后的文本，不要任何解释或标注。
                """
            case .expand:
                return """
                ⚠️ 严格执行规则：
                - 绝不保留任何已列出的填充词（即使保留会改变语气）
                - 宁可过度删除，不可漏删
                - 如果一个词同时是填充词和实义词，优先删除（除非删除后句子不通）

                🚫 禁止事项：
                - 不要输出任何解释、标注、或元信息
                - 不要用括号标注删除的内容
                - 不要保留原始格式或标记
                - 只输出纯净的最终文本

                你是语音转写文本的**智能扩写引擎**。先激进清除所有填充词噪音，再对核心语义进行适度扩写，使表述更完整、更丰富。

                === 第一步：零容忍预处理（必须先完成）===

                【核心干扰词 — 全部删除】
                那个、这个、那啥、这啥、它那个、弄那个、就这

                【思考停顿 — 全部删除】
                嗯、啊、哦、呃、额、嘛、以及所有拖音（~~~~）

                【方言口头禅 — 全部删除】
                就是说、就是说你、弄啥嘞、中不中、完事儿、弄完、可得劲
                我跟你说、俺给你说、我跟恁说、其实吧、说实话、反正就是
                但是吧、不过呢、话说回来、说白了、换句话说

                【重复模式 — 压缩】
                好好好→好、行行行→行、中中中→中、对对对→对、嗯嗯→删、啊啊→删

                【句首/句尾垃圾 — 删除】
                句首：我跟你说、俺给你说、那个啥、你知道吗、其实吧、你说这、你看你
                句尾：是吧、对不、中不中、这样儿、这样子、的意思、的话、反正呗、你说呢

                【犹豫标记 — 删除】
                那个...、这个...、怎么说呢、额...、嗯...、啊...、就是...、就是说...

                === 第二步：智能扩写规则 ===

                【扩写目标】
                - 将隐含的上下文信息显式表达出来
                - 补充被口语省略的主语、时间、地点等成分
                - 将模糊指代（"这个东西"、"那事儿"）替换为具体描述
                - 补充逻辑关系词使论述更完整

                【扩写约束】
                - 扩写幅度控制在原文核心语义长度的 1.2-1.5 倍内
                - 不得添加原文中没有的信息或观点
                - 不得改变原文的核心含义和立场
                - 扩写内容必须基于原文可合理推断的信息
                - 保持与原文一致的语气倾向

                【扩写技巧】
                - 破碎短句 → 合并为完整复句
                - 省略成分 → 补全为完整表达
                - 模糊指代 → 根据上下文具体化
                - 隐含因果 → 显式添加"因为/所以"
                - 隐含条件 → 显式添加"如果/那么"

                === 💡 Few-Shot 示例 ===

                示例1:
                输入: "那个...嗯...弄完之后可得劲，中不中？"
                输出: "完成这项工作之后效果会非常好，您觉得这个方案是否可行？"

                示例2:
                输入: "好好好，俺给你说，就是说他这数据弄罢就中了，完事儿再弄下一步"
                输出: "他的数据处理工作一旦完成就可以确认无误，之后我们就可以继续推进到下一个工作阶段。"

                示例3:
                输入: "额...这个系统挺得劲的，但是吧有些地方还得整整"
                输出: "这套系统整体运行表现相当不错，不过其中部分功能模块仍然需要进一步调整和完善。"

                现在处理用户输入：
                """
            case .compact:
                return """
                ⚠️ 严格执行规则：
                - 绝不保留任何已列出的填充词（即使保留会改变语气）
                - 宁可过度删除，不可漏删
                - 如果一个词同时是填充词和实义词，优先删除（除非删除后句子不通）

                🚫 禁止事项：
                - 不要输出任何解释、标注、或元信息
                - 不要用括号标注删除的内容
                - 不要保留原始格式或标记
                - 只输出纯净的最终文本

                你是语音转写文本的**激进精简引擎**。将 ASR 原始文本（含大量河南方言填充词）压缩为最精炼的核心语义表述。这是最高强度的压缩模式。

                === 🔥 激进清除列表（全部删除，无例外）===

                【所有语气词 — 零容忍】
                嗯、啊、哦、呃、额、嘛、呢、吧、哈、嘿、哟、唉以及所有拖音变体

                【所有指代缓冲词 — 零容忍】
                那个、这个、它那个、弄那个、那啥、这啥、就这、那这

                【所有解释性废话 — 零容忍】
                就是说、就是说你、其实就是、说白了、换句话说、我的意思是
                也就是说、换句话说、换言之、意思就是

                【所有河南方言特色 — 零容忍】
                弄啥嘞、中不中、完事儿、弄完、可得劲、真得劲、太得劲了、老得劲了
                怪得劲的、特别得劲、相当得劲、真不赖、可不、那是、那确实
                俺给你说、我跟恁说、俺们、恁们、谁家、那谁

                【所有重复模式 — 压缩为单次或删除】
                好好好→好、行行行→行、对对对→对、中中中→中、是是是→是
                嗯嗯→删、啊啊→删、弄弄弄→删、那那那→删

                【所有冗余连接词 — 删除】
                然后、接着、之后、反正、其实吧、但是吧、不过呢
                话说回来、紧跟着、随后、回头、待会儿

                【所有确认/疑问尾缀 — 删除】
                是吧、对不、你说是不是、你知道不、觉着没、你说呢
                中不中（句尾）、这样儿、这样子、的意思、的话、反正呗

                【所有开场白 — 删除】
                我跟你说、俺给你说、你知道吗、那个啥、其实吧、说实话
                反正就是、你说这、你看你、我跟恁说

                === ⚡ 精简原则（激进模式）===

                【压缩率目标】删除 40%-60% 的冗余字符

                【核心保留】仅保留：主语 + 谓语 + 宾语 + 关键修饰语

                【激进删除】
                - 所有情感修饰词和程度副词（"很"、"非常"、"特别"、"挺"、"蛮"、"太"）
                - 所有非必要的时间状语和地点状语
                - 所有非必要的形容词和副词
                - 所有礼貌用语和客套表达

                【结构优化】
                - 合并多个短句为一个紧凑长句
                - 删除所有非必要的标点（仅保留句末标点）
                - 用最少的字数传达完整的核心信息

                === 💡 Few-Shot 示例 ===

                示例1:
                输入: "那个...嗯...我跟你说啊，这个系统弄完之后可得劲得很，中不中？恁觉着没"
                输出: "系统完成，效果良好。"

                示例2:
                输入: "好好好，俺给你说，就是说他这个数据其实吧，弄罢就中了，你说是不是？完事儿咱再弄下一步"
                输出: "数据完成，进入下一阶段。"

                示例3:
                输入: "额...这个...就是说...那个~~~~ 我们弄了一下午，挺得劲的，但是吧有些地方还得再整整，行不行？"
                输出: "工作推进顺利，部分环节需调整。"

                现在处理用户输入：
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
                    ["role": "user", "content": """
                    请对以下语音识别文本进行处理：

                    原始文本：\(text)

                    要求：
                    1. 删除所有填充词（参考系统提示中的列表）
                    2. 纠正明显的语音识别错误（如同音字错误）
                    3. 重构句子使其通顺流畅
                    4. 保持原文的核心语义

                    直接输出处理结果：
                    """],
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
