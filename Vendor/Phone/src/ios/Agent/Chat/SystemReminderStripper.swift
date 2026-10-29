import Foundation

// Compiled copy of the SystemReminderStripper block in RawMessage+Conversion.swift.
// That file stays out of this target because its RawMessage conversions redeclare
// the ChatStore monolith. The standalone test still reads the original block.

/// [T-user-bubble-reminder-strip] `<system-reminder>…</system-reminder>` is a
/// reserved, model-only tag: the app and the model put notes for the model in
/// it (the answer to a deferred user_ask arrives as a user message ending in
/// one). Every place that SHOWS text removes it - user bubbles, previews,
/// search snippets - through this one implementation; what is sent to the
/// model keeps it.
enum SystemReminderStripper {
    private static let name = Array("system-reminder".utf8)

    /// Removes every reminder region; text without one is returned as is.
    static func strip(_ text: String) -> String {
        guard text.utf8.contains(UInt8(ascii: "<")) else { return text }
        let bytes = Array(text.utf8)
        guard firstTag(bytes) != nil else { return text }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var depth = 0
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "<"), let t = tag(in: bytes, at: i) {
                if t.closing {
                    if depth > 0 { depth -= 1 }
                } else {
                    depth += 1
                }
                i = t.end
                continue
            }
            if depth == 0 { out.append(bytes[i]) }
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// The text a user bubble shows: the message minus the attached-files
    /// metadata block and every reminder, trimmed.
    static func userBubbleText(_ content: String) -> String {
        var text = content
        if let start = text.range(of: "<user-attached-files>") {
            let end = text.range(of: "</user-attached-files>")
            let endBound = end?.upperBound ?? text.endIndex
            text = String(text[text.startIndex..<start.lowerBound] + text[endBound...])
        }
        return strip(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstTag(_ bytes: [UInt8]) -> Int? {
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "<"), tag(in: bytes, at: i) != nil { return i }
            i += 1
        }
        return nil
    }

    private static func tag(in bytes: [UInt8], at i: Int) -> (closing: Bool, end: Int)? {
        guard i >= 0, i < bytes.count, bytes[i] == UInt8(ascii: "<") else { return nil }
        var j = i + 1
        var closing = false
        if j < bytes.count, bytes[j] == UInt8(ascii: "/") { closing = true; j += 1 }
        guard j + name.count <= bytes.count else { return nil }
        for k in 0..<name.count {
            var b = bytes[j + k]
            if b >= 65, b <= 90 { b += 32 }
            if b != name[k] { return nil }
        }
        j += name.count
        while j < bytes.count, bytes[j] == UInt8(ascii: " ") { j += 1 }
        guard j < bytes.count, bytes[j] == UInt8(ascii: ">") else { return nil }
        return (closing, j + 1)
    }
}
