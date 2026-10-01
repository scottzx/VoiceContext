import Foundation

/// 统一标准字幕条目
public struct SubtitleItem: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public var startTimeMs: Int64
    public var endTimeMs: Int64
    public var originalText: String
    public var translatedText: String?

    public init(
        id: String = UUID().uuidString,
        startTimeMs: Int64,
        endTimeMs: Int64,
        originalText: String,
        translatedText: String? = nil
    ) {
        self.id = id
        self.startTimeMs = startTimeMs
        self.endTimeMs = endTimeMs
        self.originalText = originalText
        self.translatedText = translatedText
    }

    public var durationMs: Int64 {
        max(0, endTimeMs - startTimeMs)
    }

    /// 毫秒转换为标准 SRT 时间戳格式 (00:00:00,000)
    public static func formatSRTTime(_ ms: Int64) -> String {
        let totalSeconds = ms / 1000
        let milliseconds = ms % 1000
        let seconds = totalSeconds % 60
        let minutes = (totalSeconds / 60) % 60
        let hours = totalSeconds / 3600
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, milliseconds)
    }

    /// 毫秒转换为标准 VTT 时间戳格式 (00:00:00.000)
    public static func formatVTTTime(_ ms: Int64) -> String {
        let totalSeconds = ms / 1000
        let milliseconds = ms % 1000
        let seconds = totalSeconds % 60
        let minutes = (totalSeconds / 60) % 60
        let hours = totalSeconds / 3600
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, milliseconds)
    }

    /// 导出为 SRT 片段
    public func toSRTChunk(index: Int, includeTranslation: Bool = true) -> String {
        let timeRange = "\(Self.formatSRTTime(startTimeMs)) --> \(Self.formatSRTTime(endTimeMs))"
        var content = originalText
        if includeTranslation, let trans = translatedText, !trans.isEmpty {
            content += "\n\(trans)"
        }
        return "\(index)\n\(timeRange)\n\(content)\n"
    }

    /// 将长文本依照标点符号（句号、问号、感叹号、换行，以及过长长句中的逗号、分号）切分为符合视频字幕排版的细粒度句子，按字符数比例分配时间戳。
    public static func splitIntoSentenceItems(
        text: String,
        startTimeMs: Int64,
        endTimeMs: Int64,
        maxCharsPerCue: Int = 18
    ) -> [SubtitleItem] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // 1. 先按终止标点 (。！？!?…\n) 拆分
        var primarySentences: [String] = []
        let primaryRegex = try? NSRegularExpression(pattern: "[^。！？!?…\\n]+[。！？!?…\\n]*", options: [])
        let nsText = trimmed as NSString
        let matches = primaryRegex?.matches(in: trimmed, options: [], range: NSRange(location: 0, length: nsText.length)) ?? []

        for match in matches {
            let chunk = nsText.substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty {
                primarySentences.append(chunk)
            }
        }
        if primarySentences.isEmpty {
            primarySentences.append(trimmed)
        }

        // 2. 对超过 maxCharsPerCue 且含有逗号/分号的长句，进一步切分
        var finalTexts: [String] = []
        let subRegex = try? NSRegularExpression(pattern: "[^，,；;]+[，,；;]*", options: [])

        for sent in primarySentences {
            if sent.count > maxCharsPerCue, sent.rangeOfCharacter(from: CharacterSet(charactersIn: "，,；;")) != nil {
                let nsSent = sent as NSString
                let subMatches = subRegex?.matches(in: sent, options: [], range: NSRange(location: 0, length: nsSent.length)) ?? []
                var subChunks: [String] = []
                for subMatch in subMatches {
                    let subChunk = nsSent.substring(with: subMatch.range).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !subChunk.isEmpty {
                        subChunks.append(subChunk)
                    }
                }
                if subChunks.count > 1 {
                    finalTexts.append(contentsOf: subChunks)
                    continue
                }
            }
            finalTexts.append(sent)
        }

        if finalTexts.count <= 1 {
            return [SubtitleItem(startTimeMs: startTimeMs, endTimeMs: endTimeMs, originalText: trimmed)]
        }

        // 3. 按照各子句的非空字符数比例分配时间戳
        let totalSpan = max(Int64(finalTexts.count) * 100, endTimeMs - startTimeMs)
        let charCounts = finalTexts.map { max(1, $0.replacingOccurrences(of: " ", with: "").count) }
        let totalChars = max(1, charCounts.reduce(0, +))

        var items: [SubtitleItem] = []
        var cursorMs = startTimeMs

        for (index, subText) in finalTexts.enumerated() {
            let isLast = index == finalTexts.count - 1
            let subDuration = isLast
                ? (endTimeMs - cursorMs)
                : max(200, Int64(Double(totalSpan) * Double(charCounts[index]) / Double(totalChars)))
            let itemStart = cursorMs
            let itemEnd = isLast ? endTimeMs : min(endTimeMs, cursorMs + subDuration)
            cursorMs = max(itemStart + 1, itemEnd)

            items.append(SubtitleItem(
                startTimeMs: itemStart,
                endTimeMs: max(itemStart + 100, itemEnd),
                originalText: subText
            ))
        }

        return items
    }
}

/// 字幕导出与序列化器
public enum SubtitleExporter {
    public static func toSRT(_ items: [SubtitleItem], includeTranslation: Bool = true) -> String {
        var chunks: [String] = []
        for (index, item) in items.enumerated() {
            chunks.append(item.toSRTChunk(index: index + 1, includeTranslation: includeTranslation))
        }
        return chunks.joined(separator: "\n")
    }

    public static func toVTT(_ items: [SubtitleItem], includeTranslation: Bool = true) -> String {
        var output = "WEBVTT\n\n"
        for (index, item) in items.enumerated() {
            let timeRange = "\(SubtitleItem.formatVTTTime(item.startTimeMs)) --> \(SubtitleItem.formatVTTTime(item.endTimeMs))"
            var content = item.originalText
            if includeTranslation, let trans = item.translatedText, !trans.isEmpty {
                content += "\n\(trans)"
            }
            output += "\(index + 1)\n\(timeRange)\n\(content)\n\n"
        }
        return output
    }
}
