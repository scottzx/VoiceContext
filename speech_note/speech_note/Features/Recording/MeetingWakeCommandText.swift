import Foundation

/// Text cleanup happens only after a real acoustic wake has authorized audio.
nonisolated enum MeetingWakeCommandText {
    enum IndependentCommand: Equatable, Sendable {
        case wakeOnly
        case command(String)
        case empty
    }

    /// A short real command must not become a wake-only reply because of its
    /// character count. Only the recognized keyword plus optional punctuation
    /// has that meaning; blank or unintelligible ASR is a separate outcome.
    static func classifyIndependent(_ text: String) -> IndependentCommand {
        let parsed = parse(text)
        if !parsed.command.isEmpty { return .command(parsed.command) }
        return parsed.hadWakeWord ? .wakeOnly : .empty
    }

    static func command(from text: String) -> String {
        parse(text).command
    }

    private static func parse(_ text: String) -> (command: String, hadWakeWord: Bool) {
        let ignored = CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)
        func isIgnored(_ character: Character) -> Bool {
            character.unicodeScalars.allSatisfy { ignored.contains($0) }
        }
        let text = String(text.drop(while: isIgnored))
        let indices = text.indices.filter { !isIgnored(text[$0]) }
        let characters = indices.map { text[$0] }
        for keyword in ["小蓝同学", "小兰同学"] {
            let prefix = Array(keyword)
            if characters.starts(with: prefix) {
                let end = text.index(after: indices[prefix.count - 1])
                return (String(text[end...].drop(while: isIgnored))
                    .trimmingCharacters(in: .whitespacesAndNewlines), true)
            }
        }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), false)
    }
}
