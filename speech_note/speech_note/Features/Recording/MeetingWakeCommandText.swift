import Foundation

/// Text cleanup happens only after a real acoustic wake has authorized audio.
nonisolated enum MeetingWakeCommandText {
    static func command(from text: String) -> String {
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
                return String(text[end...].drop(while: isIgnored))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
