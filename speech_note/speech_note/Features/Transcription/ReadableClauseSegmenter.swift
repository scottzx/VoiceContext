import Foundation

/// Adds a readable clause layer after acoustic ASR utterances. The operation
/// is deterministic and never creates a child spanning two source files.
nonisolated enum ReadableClauseSegmenter {
    static let defaultMaximumCharacters = 80
    static let maximumDisplayDurationSamples: Int64 = 15 * 16_000

    static func split(
        _ parent: TranscriptDocumentV1.SegmentDraft,
        maximumCharacters: Int = defaultMaximumCharacters
    ) -> [TranscriptDocumentV1.SegmentDraft] {
        precondition(maximumCharacters > 0, "maximumCharacters must be positive")
        let characters = Array(parent.text)
        guard !characters.isEmpty else { return [] }

        let sources = parent.sourceRanges
            .map { source in
                TranscriptDocumentV1.SourceRange(
                    sourceKind: source.sourceKind,
                    sourceID: source.sourceID,
                    startSample: max(parent.startSample, source.startSample),
                    endSample: min(parent.endSample, source.endSample)
                )
            }
            .filter { $0.sampleCount > 0 }
            .sorted { lhs, rhs in
                if lhs.startSample != rhs.startSample { return lhs.startSample < rhs.startSample }
                return lhs.sourceID.uuidString < rhs.sourceID.uuidString
            }
        guard !sources.isEmpty else { return [parent] }

        var clauses: [TranscriptDocumentV1.SegmentDraft] = []
        for allocation in sourceAllocations(characterCount: characters.count, sources: sources)
        where !allocation.characters.isEmpty {
            let sourceCharacterCount = allocation.characters.count
            let durationLimitedCharacters = max(
                1,
                Int(
                    Int64(sourceCharacterCount) * maximumDisplayDurationSamples
                        / allocation.source.sampleCount
                )
            )
            let clauseCharacterLimit = min(maximumCharacters, durationLimitedCharacters)
            var cursor = allocation.characters.lowerBound
            while cursor < allocation.characters.upperBound {
                let boundary = nextBoundary(
                    in: characters,
                    after: cursor,
                    upperBound: allocation.characters.upperBound,
                    maximumCharacters: clauseCharacterLimit
                )
                let localStart = cursor - allocation.characters.lowerBound
                let localEnd = boundary - allocation.characters.lowerBound
                let samples = allocation.source.sampleCount
                let startSample = allocation.source.startSample
                    + samples * Int64(localStart) / Int64(sourceCharacterCount)
                let endSample = localEnd == sourceCharacterCount
                    ? allocation.source.endSample
                    : allocation.source.startSample
                        + samples * Int64(localEnd) / Int64(sourceCharacterCount)
                let sourceRange = TranscriptDocumentV1.SourceRange(
                    sourceKind: allocation.source.sourceKind,
                    sourceID: allocation.source.sourceID,
                    startSample: startSample,
                    endSample: endSample
                )
                clauses.append(TranscriptDocumentV1.SegmentDraft(
                    text: String(characters[cursor..<boundary]),
                    startSample: startSample,
                    endSample: endSample,
                    sourceRanges: [sourceRange],
                    speechSpanIDs: parent.speechSpanIDs,
                    isManuallyEdited: parent.isManuallyEdited,
                    editedAt: parent.editedAt
                ))
                cursor = boundary
            }
        }
        return clauses
    }

    private struct SourceAllocation {
        let source: TranscriptDocumentV1.SourceRange
        let characters: Range<Int>
    }

    private static func sourceAllocations(
        characterCount: Int,
        sources: [TranscriptDocumentV1.SourceRange]
    ) -> [SourceAllocation] {
        let totalSamples = sources.reduce(Int64(0)) { $0 + $1.sampleCount }
        var result: [SourceAllocation] = []
        var characterCursor = 0
        var cumulativeSamples: Int64 = 0

        for (index, source) in sources.enumerated() {
            cumulativeSamples += source.sampleCount
            let boundary: Int
            if index == sources.count - 1 {
                boundary = characterCount
            } else {
                let proportional = Int(
                    (Double(characterCount) * Double(cumulativeSamples) / Double(totalSamples)).rounded()
                )
                if characterCount >= sources.count {
                    let remaining = sources.count - index - 1
                    boundary = min(
                        characterCount - remaining,
                        max(characterCursor + 1, proportional)
                    )
                } else {
                    boundary = min(characterCount, max(characterCursor, proportional))
                }
            }
            result.append(SourceAllocation(
                source: source,
                characters: characterCursor..<boundary
            ))
            characterCursor = boundary
        }
        return result
    }

    private static func nextBoundary(
        in characters: [Character],
        after cursor: Int,
        upperBound: Int,
        maximumCharacters: Int
    ) -> Int {
        let limit = min(cursor + maximumCharacters, upperBound)
        let minimumNaturalLength = min(8, max(2, maximumCharacters / 3))
        var naturalPunctuation: Int?
        var naturalConnector: Int?

        for index in cursor..<limit {
            if isSentenceEnding(at: index, upperBound: upperBound, in: characters) {
                var boundary = index + 1
                while boundary < limit, closingPunctuation.contains(characters[boundary]) {
                    boundary += 1
                }
                while boundary < limit, characters[boundary].isWhitespace {
                    boundary += 1
                }
                return boundary
            }
            if naturalPunctuation == nil,
               index - cursor + 1 >= minimumNaturalLength,
               weakPunctuation.contains(characters[index]) {
                naturalPunctuation = index + 1
            }
            if naturalConnector == nil,
               index - cursor >= minimumNaturalLength,
               startsWithConnector(at: index, upperBound: upperBound, in: characters) {
                naturalConnector = index
            }
        }
        if let naturalPunctuation { return naturalPunctuation }
        if let naturalConnector { return naturalConnector }
        if limit == upperBound { return limit }

        for index in stride(from: limit - 1, through: cursor, by: -1)
        where weakPunctuation.contains(characters[index]) {
            return index + 1
        }
        for index in stride(from: limit - 1, through: cursor, by: -1)
        where characters[index].isWhitespace {
            return index + 1
        }
        for index in stride(from: limit - 1, to: cursor, by: -1)
        where startsWithConnector(at: index, upperBound: upperBound, in: characters) {
            return index
        }
        return limit
    }

    private static func isSentenceEnding(
        at index: Int,
        upperBound: Int,
        in characters: [Character]
    ) -> Bool {
        let character = characters[index]
        if character == "…" {
            return index + 1 >= upperBound || characters[index + 1] != "…"
        }
        if chineseSentenceEndings.contains(character) { return true }
        if character == "\n" || character == "\r" || character == "!" || character == "?" {
            return true
        }
        guard character == "." || character == ";" else { return false }
        guard index + 1 < upperBound else { return true }
        let next = characters[index + 1]
        if character == ".", index > 0, characters[index - 1].isNumber, next.isNumber {
            return false
        }
        return next.isWhitespace || closingPunctuation.contains(next)
    }

    private static func startsWithConnector(
        at index: Int,
        upperBound: Int,
        in characters: [Character]
    ) -> Bool {
        connectors.contains { connector in
            let end = index + connector.count
            return end <= upperBound && characters[index..<end].elementsEqual(connector)
        }
    }

    private static let chineseSentenceEndings: Set<Character> = ["。", "！", "？", "；"]
    private static let weakPunctuation: Set<Character> = ["，", ",", "、", "：", ":", "—"]
    private static let closingPunctuation: Set<Character> = ["”", "’", "」", "』", "】", "）", ")", "]"]
    private static let connectors = [
        "然后", "但是", "所以", "另外", "不过", "而且", "那么", "其实",
        "因为", "如果", "首先", "其次", "最后", "接下来", "比如", "总之",
    ].map(Array.init)
}
