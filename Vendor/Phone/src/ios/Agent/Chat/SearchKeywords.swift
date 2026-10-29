import Foundation

// [T-search-multi-keyword] A search box entry is a list of keywords separated
// by whitespace, and a session is a result when ANY of them is found (OR): in
// its title, or in a message field the user can see. One keyword behaves
// exactly as the whole-string search did before.
// Pure (strings in, strings out) so the split, the escaping, the SQL and the
// highlight ranges are tested without the store.
// Kept byte-identical with MinisTests/Standalone/SearchHitLineTests.swift.
// BEGIN searchKeywords
enum SearchKeywords {
    /// Keywords past this many are ignored: each one adds a LIKE per message.
    static let maxTerms = 10

    /// The keywords of `query`: split on any whitespace (runs of it, tabs,
    /// newlines, the full-width space), empties dropped, a keyword repeated
    /// in another letter case kept once. Empty for a blank query.
    static func terms(_ query: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for piece in query.split(whereSeparator: \.isWhitespace) {
            let term = String(piece)
            guard seen.insert(term.lowercased()).inserted else { continue }
            out.append(term)
            if out.count == maxTerms { break }
        }
        return out
    }

    /// `%term%` for LIKE ... ESCAPE '\': `%` and `_` in the keyword are
    /// matched as themselves, not as wildcards ("100%" used to match
    /// "1000 items", "a_b" matched "axb").
    static func likePattern(_ term: String) -> String {
        var escaped = ""
        for ch in term {
            if ch == "\\" || ch == "%" || ch == "_" { escaped.append("\\") }
            escaped.append(ch)
        }
        return "%\(escaped)%"
    }

    /// `(column LIKE ?1 ESCAPE '\' OR column LIKE ?2 ESCAPE '\' ...)`: the
    /// column holds any of the `termCount` patterns bound to ?1...?n.
    static func anyLike(_ column: String, termCount: Int) -> String {
        "(" + (1...max(1, termCount)).map { "\(column) LIKE ?\($0) ESCAPE '\\'" }.joined(separator: " OR ") + ")"
    }

    // [T-search-visible-only] SQL condition: message `m` holds one of the
    // patterns in a field the user can see - a text part, a tool call's input
    // or a tool's output. `parts_json LIKE` alone also matched opaque fields
    // (tool-call ids, Gemini thought signatures - random base64 in which a
    // short case-insensitive keyword like "gpt" turns up by chance), listing
    // sessions that never mention the keyword. The plain LIKE stays first as
    // the cheap prefilter; json_each only runs on its survivors.
    static func visibleHitClause(termCount n: Int) -> String {
        """
        \(anyLike("m.parts_json", termCount: n)) AND EXISTS (
            SELECT 1 FROM json_each(m.parts_json) p
            WHERE (json_extract(p.value, '$.type') = 'text' AND \(anyLike("json_extract(p.value, '$.value')", termCount: n)))
               OR (json_extract(p.value, '$.type') = 'toolUse' AND \(anyLike("json_extract(p.value, '$.value.input')", termCount: n)))
               OR (json_extract(p.value, '$.type') = 'toolResult' AND \(anyLike("json_extract(p.value, '$.value.output')", termCount: n))))
        """
    }

    // [T-search-visible-only] Sessions whose title matches, or holding a
    // message that shows a keyword in a visible field, with the newest such
    // message (SQLite's bare column beside MAX() is that row's).
    static func visibleSQL(termCount n: Int) -> String {
        """
        WITH newest AS (
            SELECT m.session_id, m.parts_json, MAX(m.sort_order)
            FROM messages m
            WHERE \(visibleHitClause(termCount: n))
            GROUP BY m.session_id)
        SELECT s.id, s.title, s.model_id, s.created_at, s.updated_at, s.category, n.parts_json
        FROM sessions s
        LEFT JOIN newest n ON n.session_id = s.id
        WHERE \(anyLike("s.title", termCount: n)) OR n.session_id IS NOT NULL
        ORDER BY s.updated_at DESC
        """
    }

    // Pre-JSON1 fallback: raw-JSON LIKE, as before. Rows it lists without a
    // visible line are still dropped by the caller.
    static func legacySQL(termCount n: Int) -> String {
        """
        SELECT DISTINCT s.id, s.title, s.model_id, s.created_at, s.updated_at, s.category,
               (SELECT m2.parts_json FROM messages m2
                WHERE m2.session_id = s.id AND \(anyLike("m2.parts_json", termCount: n))
                ORDER BY m2.sort_order DESC LIMIT 1)
        FROM sessions s
        LEFT JOIN messages m ON m.session_id = s.id
        WHERE \(anyLike("s.title", termCount: n)) OR \(anyLike("m.parts_json", termCount: n))
        GROUP BY s.id
        ORDER BY s.updated_at DESC
        """
    }

    /// The newest matching messages of one session (its id is bound after
    /// the patterns, to ?n+1).
    static func olderSQL(termCount n: Int, visibleOnly: Bool) -> String {
        """
        SELECT m.parts_json FROM messages m
        WHERE m.session_id = ?\(n + 1) AND \(visibleOnly ? visibleHitClause(termCount: n) : anyLike("m.parts_json", termCount: n))
        ORDER BY m.sort_order DESC LIMIT 20
        """
    }

    /// The first keyword, in the order typed, that occurs in `text`, with
    /// where it first occurs. Case-insensitive.
    static func firstHit(in text: String, terms: [String]) -> (range: Range<String.Index>, term: String)? {
        for term in terms where !term.isEmpty {
            if let range = text.range(of: term, options: .caseInsensitive) { return (range, term) }
        }
        return nil
    }

    /// Every occurrence of every keyword in `text`, in text order, with
    /// overlapping and touching occurrences joined ("gpt" and "gpt-5" in
    /// "GPT-5" are one range). What a row highlights.
    static func hitRanges(in text: String, terms: [String]) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        for term in terms where !term.isEmpty {
            var from = text.startIndex
            while from < text.endIndex,
                  let range = text.range(of: term, options: .caseInsensitive, range: from..<text.endIndex) {
                found.append(range)
                from = range.upperBound > range.lowerBound ? range.upperBound : text.index(after: range.lowerBound)
            }
        }
        found.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for range in found {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
// END searchKeywords
