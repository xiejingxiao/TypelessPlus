import Foundation

final class TextPreprocessor {
    static let shared = TextPreprocessor()

    var enabled: Bool = true
    var aggressiveMode: Bool = false

    private init() {}

    struct ProcessingStats {
        let originalLength: Int
        var finalLength: Int
        var removals: [String: Int] = [:]

        var compressionRatio: Double {
            guard originalLength > 0 else { return 0 }
            return Double(finalLength) / Double(originalLength)
        }

        var totalRemovals: Int {
            removals.values.reduce(0, +)
        }
    }

    private func record(_ category: String, in stats: inout ProcessingStats) {
        stats.removals[category, default: 0] += 1
    }

    func process(_ text: String) -> String {
        processWithStats(text).text
    }

    func processWithStats(_ text: String) -> (text: String, stats: ProcessingStats) {
        guard enabled else {
            var stats = ProcessingStats(originalLength: text.count, finalLength: text.count)
            return (text, stats)
        }

        let original = text
        var current = text
        var stats = ProcessingStats(originalLength: text.count, finalLength: text.count)

        current = applyP0CorePatterns(to: &current, stats: &stats)
        current = applyP1DialectPatterns(to: &current, stats: &stats)
        current = applyP2RepetitionPatterns(to: &current, stats: &stats)
        current = applyP3ContextCleanup(to: &current, stats: &stats)
        current = repairPunctuation(current)

        stats.finalLength = current.count

        if stats.totalRemovals > 0 {
            print("[TextPreprocessor] 原始:\(stats.originalLength)→处理:\(stats.finalLength) 字符 " +
                  "(压缩率 \(String(format: "%.1f%%", stats.compressionRatio * 100))), " +
                  "删除:\(stats.removals)")
        }

        return (current, stats)
    }

    private func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: options)
    }

    private func replace(_ pattern: String, in text: inout String,
                         with replacement: String = "",
                         options: NSRegularExpression.Options = []) -> Int {
        guard let re = regex(pattern, options: options) else { return 0 }
        let range = NSRange(text.startIndex..., in: text)
        let matches = re.matches(in: text, range: range)
        guard !matches.isEmpty else { return 0 }
        text = re.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
        return matches.count
    }

    private func applyP0CorePatterns(to text: inout String, stats: inout ProcessingStats) -> String {
        let thinkingPausePattern = "[嗯嗯呃额嘛呢哈啊哦嘿]+[~～\\-\\_]+"
        let count = replace(thinkingPausePattern, in: &text)
        if count > 0 { record("P0-拖音", in: &stats) }

        let charRepeatPattern = "(.)\\1{2,}"
        let repeatCount = replace(charRepeatPattern, in: &text, with: "$1")
        if repeatCount > 0 { record("P0-重复字符", in: &stats) }

        let standaloneFillerPattern = "(?:^|[\\s,，。！？!?.;；：:])" +
            "(那个|这个|那啥|这啥|它那个|弄那个|就这)" +
            "(?=[\\s,，。！？!?.;；：:]|$)"
        let fillerCount = replace(standaloneFillerPattern, in: &text, with: "$2",
                                  options: [.anchorsMatchLines])
        if fillerCount > 0 { record("P0-独立缓冲词", in: &stats) }

        let explanationPhrases = [
            "就是说", "就是说你", "其实就是", "说白了", "换句话说", "我的意思是"
        ]
        var explanationCount = 0
        for phrase in explanationPhrases {
            explanationCount += replace("\\Q\(phrase)\\E", in: &text)
        }
        if explanationCount > 0 { record("P0-解释废话", in: &stats) }

        let pureThinkingPause = "[嗯嗯呃额嘛呢哈啊哦嘿]{2,}"
        let pauseCount = replace(pureThinkingPause, in: &text)
        if pauseCount > 0 { record("P0-纯停顿词", in: &stats) }

        return text
    }

    private func applyP1DialectPatterns(to text: inout String, stats: inout ProcessingStats) -> String {
        let confirmationPatterns = [
            "中不中", "是不是中", "行不行中", "你说是不是", "你知道不", "觉着没"
        ]
        var count = 0
        for pattern in confirmationPatterns {
            count += replace("\\Q\(pattern)\\E", in: &text)
        }
        if count > 0 { record("P1-确认疑问", in: &stats) }

        let degreePatterns = [
            "可得劲", "真得劲", "太得劲了", "老得劲了", "怪得劲的"
        ]
        count = 0
        if aggressiveMode {
            for pattern in degreePatterns {
                count += replace("\\Q\(pattern)\\E", in: &text)
            }
        } else {
            for pattern in degreePatterns {
                count += replace("\\Q\(pattern)\\E", in: &text, with: "很好")
            }
        }
        if count > 0 { record("P1-程度评价", in: &stats) }

        let pronounReplacements: [(pattern: String, replacement: String)] = [
            ("(?<![\\w])俺(?![\\w])", "我"),
            ("(?<![\\w])恁(?![\\w])", "你"),
            ("(?<![\\w])俺们(?![\\w])", "我们"),
            ("(?<![\\w])恁们(?![\\w])", "你们"),
        ]
        count = 0
        for item in pronounReplacements {
            count += replace(item.pattern, in: &text, with: item.replacement)
        }
        if count > 0 { record("P1-人称代词替换", in: &stats) }

        let timeConnectors = [
            "一会儿功夫", "等会儿", "多会儿", "回头", "待会儿", "紧跟着", "随后"
        ]
        count = 0
        for phrase in timeConnectors {
            count += replace("\\Q\(phrase)\\E", in: &text)
        }
        if count > 0 { record("P1-时间连接词", in: &stats) }

        let openingPhrases = [
            "我跟你说", "我跟恁说", "俺给你说", "你知道吗", "那个啥",
            "反正就是", "其实吧", "说实话"
        ]
        count = 0
        for phrase in openingPhrases {
            count += replace("\\Q\(phrase)\\E", in: &text)
        }
        if count > 0 { record("P1-经典开场", in: &stats) }

        let closingPhrases = [
            "是吧", "对不", "这样儿", "这样子", "的意思", "的话", "反正呗"
        ]
        count = 0
        for phrase in closingPhrases {
            count += replace("\\Q\(phrase)\\E", in: &text)
        }
        if count > 0 { record("P1-经典收尾", in: &stats) }

        let negationMap: [(pattern: String, replacement: String)] = [
            ("\\Q不中\\E", "不行"),
            ("\\Q没门儿\\E", "不行"),
            ("\\Q算了吧\\E", ""),
            ("\\Q拉倒吧\\E", ""),
            ("\\Q白搭\\E", "不行"),
            ("\\Q没用\\E", ""),
        ]
        count = 0
        for item in negationMap {
            count += replace(item.pattern, in: &text, with: item.replacement)
        }
        if count > 0 { record("P1-否定表达", in: &stats) }

        let exclamations = [
            "我的天", "我的娘", "乖乖", "哎呦喂", "我的乖乖"
        ]
        count = 0
        for phrase in exclamations {
            count += replace("\\Q\(phrase)\\E", in: &text)
        }
        if count > 0 { record("P1-感叹强调", in: &stats) }

        let vagueReferences = [
            "那啥玩意", "这号人", "那种事", "这事儿"
        ]
        count = 0
        for phrase in vagueReferences {
            count += replace("\\Q\(phrase)\\E", in: &text)
        }
        if count > 0 { record("P1-模糊指代", in: &stats) }

        let dialectVerbs = [
            "弄啥嘞", "弄啥了", "完事儿", "弄罢", "再弄", "这就弄"
        ]
        count = 0
        for phrase in dialectVerbs {
            count += replace("\\Q\(phrase)\\E", in: &text)
        }
        if count > 0 { record("P1-万能动词", in: &stats) }

        return text
    }

    private func applyP2RepetitionPatterns(to text: inout String, stats: inout ProcessingStats) -> String {
        let repetitionRules: [(pattern: String, replacement: String)] = [
            ("好好好", "好"),
            ("行行行", "行"),
            ("对对对", "对"),
            ("是是是", "是"),
            ("中中中", "中"),
            ("(?:嗯嗯|啊啊|呃呃)", ""),
            ("(?:弄弄弄|那那那)", ""),
            ("(?:这个这个|那个那个)", "$1"),
            ("(?:可不是可不是|对了对了)", "$1"),
        ]

        var totalCount = 0
        for rule in repetitionRules {
            let count = replace(rule.pattern, in: &text, with: rule.replacement)
            totalCount += count
        }
        if totalCount > 0 { record("P2-重复压缩", in: &stats) }

        return text
    }

    private func applyP3ContextCleanup(to text: inout String, stats: inout ProcessingStats) -> String {
        let sentenceStartRedundant = [
            "我跟你说", "俺给你说", "那个啥", "你知道吗", "其实吧",
            "说实话", "反正就是", "你说这", "你看你", "怎么说呢"
        ]
        var count = 0
        for phrase in sentenceStartRedundant {
            let pattern = "(?:^|[\\n])\\s*\\Q\(phrase)\\E[\\s,，、]*"
            count += replace(pattern, in: &text, with: "", options: [.anchorsMatchLines])
        }
        if count > 0 { record("P3-句首冗余", in: &stats) }

        let sentenceEndRedundant = [
            "是吧", "对不", "中不中", "弄啥嘞", "这样儿", "这样的话",
            "的意思", "反正呗", "你说呢", "你知道吧"
        ]
        count = 0
        for phrase in sentenceEndRedundant {
            let pattern = "\\s*\\Q\(phrase)\\E(?=[\\s。！？!?;；,，]|$)"
            count += replace(pattern, in: &text)
        }
        if count > 0 { record("P3-句尾冗余", in: &stats) }

        let transitionRedundant = [
            "但是吧", "不过呢", "话说回来", "反正", "其实吧"
        ]
        count = 0
        for phrase in transitionRedundant {
            count += replace("\\Q\(phrase)\\E", in: &text)
        }
        if count > 0 { record("P3-转折冗余", in: &stats) }

        let hesitationMarkers = [
            "那个\\.\\.\\.", "这个\\.\\.\\.", "怎么说呢",
            "额\\.\\.\\.", "嗯\\.\\.\\.", "啊\\.\\.\\.",
            "就是\\.\\.\\.", "就是说\\.\\.\\."
        ]
        count = 0
        for pattern in hesitationMarkers {
            count += replace(pattern, in: &text)
        }
        if count > 0 { record("P3-犹豫标记", in: &stats) }

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        while text.contains("  ") {
            text = text.replacingOccurrences(of: "  ", with: " ")
        }

        while text.contains(", ,") || text.contains("， ，") ||
              text.contains("..") || text.contains("。。") {
            text = text.replacingOccurrences(of: ", ,", with: ",")
            text = text.replacingOccurrences(of: "， ，", with: "，")
            text = text.replacingOccurrences(of: "..", with: ".")
            text = text.replacingOccurrences(of: "。。", with: "。")
        }

        return text
    }

    private func repairPunctuation(_ text: String) -> String {
        var result = text

        result = result.replacingOccurrences(
            of: "(?<=[^。！？!?])\\s+(?=[^\\s])",
            with: "",
            options: .regularExpression
        )

        let trailingSpacePattern = "\\s+([,，。！？!?.;；：:])"
        if let re = regex(trailingSpacePattern) {
            let range = NSRange(result.startIndex..., in: result)
            result = re.stringByReplacingMatches(in: result, range: range, withTemplate: "$1")
        }

        let missingPeriodPattern = "(?<=[^。！？!?\\s])([^\\s]+)$"
        if let re = regex(missingPeriodPattern, options: [.anchorsMatchLines]),
           let match = re.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)),
           let matchRange = Range(match.range(at: 1), in: result) {
            let lastContent = String(result[matchRange])
            if !lastContent.allSatisfy({ $0.isPunctuation || $0.isWhitespace }) &&
               lastContent.count >= 2 {
                result.append("。")
            }
        }

        let orphanedCommaPattern = "[,，][\\s]*$"
        if let re = regex(orphanedCommaPattern, options: [.anchorsMatchLines]) {
            let range = NSRange(result.startIndex..., in: result)
            result = re.stringByReplacingMatches(in: result, range: range, withTemplate: "。")
        }

        return result
    }
}
