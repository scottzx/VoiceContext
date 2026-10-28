//
//  MarkdownTheme.swift
//  Minis - markdown renderer module (Views/Chat/Markdown)
//
//  Visual vocabulary of rendered markdown.
//
//  - NSAttributedString.Key extensions: attributes the renderer writes and
//    MinisLayoutManager / the text view read back (inline code background and
//    text, blockquote depth).
//  - minisInlineCodeBackgroundColor: the single source of the inline-code pill
//    colour, shared by the theme, MinisLayoutManager (the paint site) and table
//    cells, so they cannot drift apart.
//  - SelectableMarkdownTheme: UIKit mirror of the `.minisChat` MarkdownUI theme
//    (fonts, colours, spacing). Attachments keep a copy of the theme they were
//    rendered with.
//  - renderMarkdownBlocks: one-shot render for callers outside the view, e.g.
//    AIChatViewModel caching the attributed string of a finished message.
//
//  Module map and conventions: Bridge/SelectableMarkdownView.swift.
//

import AVFoundation
import Combine
import CoreText
import Photos
import SwiftUI
import UIKit

// MARK: - Custom Attributed String Keys

extension NSAttributedString.Key {
    static let inlineCodeBackground = NSAttributedString.Key("minisInlineCodeBackground")
    static let inlineCodeText = NSAttributedString.Key("minisInlineCodeText")
    static let blockquoteDepth = NSAttributedString.Key("minisBlockquoteDepth")
}

// MARK: - SelectableMarkdownTheme

/// Shared by attributed text and its layout manager's background painter.
let minisInlineCodeBackgroundColor = YimaDesign.UIKitColor.grouped

/// Shared document roles, rendered with the user's scaled message font.
struct SelectableMarkdownTheme {
    let baseFontSize: CGFloat
    let codeBlockCornerRadius: CGFloat = YimaDesign.Radius.codeBlock
    let inlineCodeCornerRadius: CGFloat = 5

    init(baseFontSize: CGFloat? = nil) {
        self.baseFontSize = baseFontSize ?? YimaDesign.Typography.bodySize
    }

    var baseFont: UIFont { .systemFont(ofSize: baseFontSize) }
    var lineSpacing: CGFloat {
        YimaDesign.Document.lineSpacing * baseFontSize / YimaDesign.Typography.bodySize
    }
    var labelColor: UIColor { YimaDesign.UIKitColor.ink }
    var secondaryLabelColor: UIColor { YimaDesign.UIKitColor.muted }
    var accentColor: UIColor { YimaDesign.UIKitColor.ink }
    var linkColor: UIColor { YimaDesign.UIKitColor.info }
    var codeBlockBackground: UIColor { YimaDesign.UIKitColor.grouped }
    var codeBlockTextColor: UIColor { YimaDesign.UIKitColor.ink }
    var inlineCodeBackground: UIColor { minisInlineCodeBackgroundColor }
    var inlineCodeColor: UIColor { YimaDesign.UIKitColor.ink }
    var blockquoteBarColor: UIColor { YimaDesign.UIKitColor.line }
    var tableBorderColor: UIColor { YimaDesign.UIKitColor.line }

    func headingFont(level: Int) -> UIFont {
        let size: CGFloat
        let weight: UIFont.Weight
        switch level {
        case 1: size = baseFontSize * YimaDesign.Typography.detailTitleSize / YimaDesign.Typography.bodySize; weight = .bold
        case 2: size = baseFontSize * YimaDesign.Typography.subsectionSize / YimaDesign.Typography.bodySize; weight = .semibold
        default: size = baseFontSize; weight = .semibold
        }
        return .systemFont(ofSize: size, weight: weight)
    }

    var inlineCodeFont: UIFont { inlineCodeFont(matching: nil) }

    /// [T-md-inline-code-context-font] Inline code sized RELATIVE to the text
    /// it sits in — 0.845× the CONTEXT font, the exact ratio body text has
    /// always used (0.845 × baseFontSize), so paragraph rendering is
    /// unchanged while a code span inside an H1/H2 scales with the heading
    /// instead of rendering at body size and reading sunken/undersized.
    func inlineCodeFont(matching contextFont: UIFont?) -> UIFont {
        let size = (contextFont?.pointSize ?? baseFontSize)
            * YimaDesign.Typography.metadataSize / YimaDesign.Typography.bodySize
        if let menlo = UIFont(name: "Menlo", size: size) {
            let descriptor = menlo.fontDescriptor.addingAttributes([
                .cascadeList: [UIFontDescriptor(fontAttributes: [.name: "PingFang SC"])]
            ])
            return UIFont(descriptor: descriptor, size: size)
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    var codeBlockFont: UIFont {
        let size = baseFontSize * YimaDesign.Typography.metadataSize / YimaDesign.Typography.bodySize
        // Use Menlo as the base monospaced font, with PingFang SC as CJK fallback.
        // PingFang SC's CJK glyphs are exactly 2x the width of Menlo's ASCII glyphs
        // at the same point size, enabling proper table alignment in code blocks.
        if let menlo = UIFont(name: "Menlo", size: size) {
            let descriptor = menlo.fontDescriptor.addingAttributes([
                .cascadeList: [UIFontDescriptor(fontAttributes: [.name: "PingFang SC"])]
            ])
            return UIFont(descriptor: descriptor, size: size)
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

private let markdownBaseFontSizeAttribute = NSAttributedString.Key("YimaMarkdownBaseFontSize")

private func markdownFontMatches(_ string: NSAttributedString, size: CGFloat) -> Bool {
    guard string.length > 0,
          let stamped = string.attribute(markdownBaseFontSizeAttribute, at: 0, effectiveRange: nil) as? NSNumber else {
        return false
    }
    return stamped.doubleValue == Double(size)
}

/// Renders markdown blocks into an NSAttributedString using a fresh MarkdownNSRenderer.
/// Intended for one-shot rendering of completed messages (e.g. caching in AIChatViewModel).
@MainActor
func renderMarkdownBlocks(_ blocks: [BlockNode]) -> NSAttributedString {
    let fontSize = FontSettings.shared.scaledMessage(YimaDesign.Typography.bodySize)
    let renderer = MarkdownNSRenderer(baseFontSize: fontSize)
    let rendered = NSMutableAttributedString(attributedString: renderer.render(blocks: blocks))
    if rendered.length > 0 {
        rendered.addAttribute(markdownBaseFontSizeAttribute, value: NSNumber(value: Double(fontSize)),
                              range: NSRange(location: 0, length: rendered.length))
    }
    return rendered
}
