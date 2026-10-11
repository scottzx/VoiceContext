import Foundation

/// Parses completed ASR chunks on the recording's absolute 16 kHz timeline.
nonisolated struct MeetingWakeCommandDetector: Sendable {
    nonisolated struct Segment: Sendable {
        let text: String
        let startSample: Int64
        let endSample: Int64
    }

    private static let wakeWord = Array("小蓝同学")
    private static let waitSamples: Int64 = 8 * 16_000
    private static let ignoredCharacters = CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)

    private var consumedThrough: Int64 = 0
    private var consumedChunks: Set<UUID> = []
    private var suppressedRanges: [Range<Int64>] = []
    private var partialWake: [Character] = []
    private var waitingSince: Int64?
    private var awaitingCommand = false

    mutating func reset(afterSample: Int64) {
        consumedThrough = max(0, afterSample)
        consumedChunks.removeAll()
        suppressedRanges.removeAll()
        clearWaiting()
    }

    mutating func suppress(from: Int64, to: Int64) {
        guard to > from else { return }
        suppressedRanges.append(max(0, from)..<to)
        clearWaiting()
    }

    mutating func consume(chunkID: UUID, segments: [Segment]) -> String? {
        guard consumedChunks.insert(chunkID).inserted else { return nil }
        var commandParts: [String] = []
        let ordered = segments.sorted {
            $0.startSample == $1.startSample ? $0.endSample < $1.endSample : $0.startSample < $1.startSample
        }

        for segment in ordered {
            guard segment.startSample >= consumedThrough, segment.endSample > segment.startSample else { continue }
            consumedThrough = segment.endSample
            if suppressedRanges.contains(where: {
                segment.startSample < $0.upperBound && segment.endSample > $0.lowerBound
            }) {
                clearWaiting()
                commandParts.removeAll()
                continue
            }
            if let waitingSince, segment.startSample - waitingSince > Self.waitSamples {
                clearWaiting()
            }

            if !commandParts.isEmpty {
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { commandParts.append(text) }
                continue
            }

            let indices = segment.text.indices.filter { !Self.isIgnored(segment.text[$0]) }
            let characters = partialWake + indices.map { segment.text[$0] }
            let match = characters.indices.first { offset in
                offset + Self.wakeWord.count <= characters.count
                    && Array(characters[offset..<(offset + Self.wakeWord.count)]) == Self.wakeWord
            }
            if let match {
                let endOffset = match + Self.wakeWord.count - partialWake.count - 1
                let endIndex = segment.text.index(after: indices[endOffset])
                let command = Self.trimLeading(String(segment.text[endIndex...]))
                clearWaiting()
                if command.isEmpty {
                    awaitingCommand = true
                    waitingSince = segment.endSample
                } else {
                    commandParts.append(command)
                }
            } else if awaitingCommand {
                let command = Self.trimLeading(segment.text)
                if !command.isEmpty {
                    commandParts.append(command)
                    clearWaiting()
                }
            } else {
                let prefixCount = (1..<Self.wakeWord.count).reversed().first { count in
                    characters.suffix(count).elementsEqual(Self.wakeWord.prefix(count))
                } ?? 0
                partialWake = Array(Self.wakeWord.prefix(prefixCount))
                if partialWake.isEmpty {
                    waitingSince = nil
                } else if waitingSince == nil {
                    waitingSince = segment.endSample
                }
            }
        }

        return commandParts.isEmpty ? nil : commandParts.joined(separator: " ")
    }

    private mutating func clearWaiting() {
        partialWake.removeAll()
        waitingSince = nil
        awaitingCommand = false
    }

    private static func isIgnored(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { ignoredCharacters.contains($0) }
    }

    private static func trimLeading(_ text: String) -> String {
        String(text.drop(while: isIgnored)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
