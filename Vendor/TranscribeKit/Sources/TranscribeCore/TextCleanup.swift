import Foundation

/// ASR 文本规整与标记清洗器
public enum TextCleanup {
    /// 清洗模型输出的原始文本（过滤 SenseVoice 的 prompt 标签如 `<|zh|>`, `<|NEUTRAL|>`, 语气词标签等）
    public static func clean(_ rawText: String) -> String {
        var text = rawText

        // 1. 去除 SenseVoice 的各类特殊标签，如 <|zh|>, <|NEUTRAL|>, <|HAPPY|>, <|withitn|>, <|woitn|>, <|EMOJI_...|>
        let specialTokenRegex = try? NSRegularExpression(pattern: "<\\|[a-zA-Z0-9_\\-\\s]+?\\|>", options: [])
        if let regex = specialTokenRegex {
            let range = NSRange(location: 0, length: (text as NSString).length)
            text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
        }

        // 2. 去除控制字符 (除换行与制表符外)
        text = text.filter { char in
            !char.isASCII || (!char.isNewline && char != "\t" && (char.asciiValue ?? 0) >= 32) || char.isNewline
        }

        // 3. 中文/中文全角标点前后的无意空格收敛
        // 匹配汉字/中文全角标点与相邻的汉字/全角标点之间的空白
        let cjkPunctuation = "，。？！；：、“”‘’（）《》〈〉【】…"
        let cjkPattern = "([\\p{Han}\(cjkPunctuation)])\\s+([\\p{Han}\(cjkPunctuation)])"
        if let regex = try? NSRegularExpression(pattern: cjkPattern, options: []) {
            // 重复替换直到没有连续跨空格的匹配
            var prev = ""
            while prev != text {
                prev = text
                let range = NSRange(location: 0, length: (text as NSString).length)
                text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "$1$2")
            }
        }

        // 4. 收敛连续英文/普通空格
        let multiSpaceRegex = try? NSRegularExpression(pattern: "[ \\t]+", options: [])
        if let regex = multiSpaceRegex {
            let range = NSRange(location: 0, length: (text as NSString).length)
            text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: " ")
        }

        // 5. 首尾空白裁剪
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 针对字幕单行的快速标点清理（例如行首意外标点等）
    public static func subtitleLine(_ text: String) -> String {
        var cleaned = clean(text)
        // 剔除行首标点
        while let first = cleaned.first, "，。、？！；：,!?;:".contains(first) {
            cleaned.removeFirst()
            cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        }
        return cleaned
    }
}
