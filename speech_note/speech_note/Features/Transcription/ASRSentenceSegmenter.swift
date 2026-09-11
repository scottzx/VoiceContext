import Foundation

/// Converts acoustically aligned ASR tokens into sentence-level ranges. Only
/// explicit full-stop, question-mark and exclamation-mark punctuation closes a
/// sentence; commas, semicolons, pauses and semantic connectors do not.
nonisolated enum ASRSentenceSegmenter {
    struct Token: Equatable, Sendable {
        let text: String
        let startMilliseconds: Int64
        let endMilliseconds: Int64
    }

    struct Sentence: Equatable, Sendable {
        let text: String
        let startMilliseconds: Int64
        let endMilliseconds: Int64
    }

    private struct Glyph {
        let character: Character
        let tokenIndex: Int
    }

    static func split(
        tokens: [Token],
        fallbackText: String,
        fallbackDurationMilliseconds: Int64
    ) -> [Sentence] {
        let aligned = tokens.filter {
            !$0.text.isEmpty && $0.endMilliseconds > $0.startMilliseconds
        }
        let glyphs = aligned.enumerated().flatMap { tokenIndex, token in
            token.text.map { Glyph(character: $0, tokenIndex: tokenIndex) }
        }
        guard !glyphs.isEmpty else {
            let text = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            return [Sentence(
                text: text,
                startMilliseconds: 0,
                endMilliseconds: max(0, fallbackDurationMilliseconds)
            )]
        }

        var sentences: [Sentence] = []
        var sentenceStart = 0
        var cursor = 0
        while cursor < glyphs.count {
            guard isSentenceTerminator(glyphs[cursor].character),
                  !isDecimalPoint(at: cursor, in: glyphs)
            else {
                cursor += 1
                continue
            }
            var boundary = cursor + 1
            while boundary < glyphs.count,
                  isSentenceTerminator(glyphs[boundary].character),
                  !isDecimalPoint(at: boundary, in: glyphs) {
                boundary += 1
            }
            appendSentence(
                glyphs[sentenceStart..<boundary],
                alignedTokens: aligned,
                to: &sentences
            )
            sentenceStart = boundary
            cursor = boundary
        }
        appendSentence(
            glyphs[sentenceStart..<glyphs.count],
            alignedTokens: aligned,
            to: &sentences
        )
        return sentences
    }

    private static func appendSentence(
        _ glyphs: ArraySlice<Glyph>,
        alignedTokens: [Token],
        to sentences: inout [Sentence]
    ) {
        guard let firstContent = glyphs.firstIndex(where: { !$0.character.isWhitespace }),
              let lastContent = glyphs.lastIndex(where: { !$0.character.isWhitespace })
        else { return }
        let text = String(glyphs[firstContent...lastContent].map(\.character))
        let firstToken = alignedTokens[glyphs[firstContent].tokenIndex]
        let lastToken = alignedTokens[glyphs[lastContent].tokenIndex]
        guard lastToken.endMilliseconds > firstToken.startMilliseconds else { return }
        sentences.append(Sentence(
            text: text,
            startMilliseconds: firstToken.startMilliseconds,
            endMilliseconds: lastToken.endMilliseconds
        ))
    }

    private static func isSentenceTerminator(_ character: Character) -> Bool {
        character == "." || character == "。"
            || character == "!" || character == "！"
            || character == "?" || character == "？"
    }

    private static func isDecimalPoint(at index: Int, in glyphs: [Glyph]) -> Bool {
        guard glyphs[index].character == ".", index > 0, index + 1 < glyphs.count else {
            return false
        }
        return glyphs[index - 1].character.isNumber && glyphs[index + 1].character.isNumber
    }
}
