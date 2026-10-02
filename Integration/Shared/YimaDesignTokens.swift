import Foundation

/// Category ordering matches UIKit/SwiftUI: seven ordinary sizes, then accessibility.
nonisolated enum YimaFontScalePolicy {
    static func appCategory(system: Int, preference: Int?) -> Int {
        guard let preference else { return system }
        return system >= 7 ? max(system, preference) : preference
    }

    static func contentMultiplier(_ multiplier: Double, system: Int) -> Double {
        system >= 7 ? max(1, multiplier) : multiplier
    }
}

#if canImport(UIKit)
import SwiftUI
import UIKit

/// One source compiled into both the app and the recording module.
@MainActor
enum YimaDesign {
    enum Typography {
        static let navigation = Font.headline
        static let detailTitle = Font.title2.weight(.bold)
        static let section = Font.headline
        static let itemTitle = Font.body.weight(.medium)
        static let recordingTitle = Font.body.weight(.semibold)
        static let body = Font.body
        static let metadata = Font.subheadline
        static let compactMetadata = Font.caption
        static let status = Font.caption
        static let code = Font.subheadline.monospaced()
        static let bodySize: CGFloat = 17
        static let detailTitleSize: CGFloat = 22
        static let subsectionSize: CGFloat = 20
        static let metadataSize: CGFloat = 15
        static let compactMetadataSize: CGFloat = 12
    }

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let section: CGFloat = 24
    }

    enum Layout {
        static let pageInset = Space.xl
        static let listInset = Space.lg
        static let sectionGap = Space.section
        static let groupGap = Space.lg
        static let headingGap = Space.sm
        static let rowContentGap = Space.xs
        static let rowPaddingY = Space.sm
        static let rowMinHeight: CGFloat = 64
        static let hitTarget: CGFloat = 44
        static let primaryHeight: CGFloat = 52
    }

    enum Radius {
        static let control: CGFloat = 12
        static let panel: CGFloat = 16
        static let codeBlock: CGFloat = 8
    }

    enum Document {
        static let paragraphGap = Space.md
        static let sectionGap = Space.section
        static let lineSpacing: CGFloat = 3
    }

    enum UIKitColor {
        static let canvas = UIColor.systemBackground
        static let surface = adaptive(0xFFFFFF, 0x1C1C1E)
        static let grouped = adaptive(0xF2F2F7, 0x1C1C1E)
        static let ink = adaptive(0x1C1C1E, 0xF2F2F7)
        static let muted = adaptive(0x636366, 0x98989D)
        static let tertiary = adaptive(0x8E8E93, 0x636366)
        static let line = UIColor.separator
        static let recording = UIColor.systemRed
        static let recordingText = adaptive(0xD70015, 0xFF6961)
        static let warning = adaptive(0xFF9F0A, 0xFF9F0A)
        static let warningText = adaptive(0x8A4B00, 0xFFB340)
        static let success = UIColor.systemGreen
        static let info = UIColor.systemBlue
        static let infoText = adaptive(0x0066CC, 0x409CFF)

        private static func adaptive(_ light: UInt32, _ dark: UInt32) -> UIColor {
            UIColor { traits in
                let value = traits.userInterfaceStyle == .dark ? dark : light
                return UIColor(red: CGFloat((value >> 16) & 0xFF) / 255,
                               green: CGFloat((value >> 8) & 0xFF) / 255,
                               blue: CGFloat(value & 0xFF) / 255, alpha: 1)
            }
        }
    }

    enum Color {
        static let canvas = SwiftUI.Color(uiColor: UIKitColor.canvas)
        static let surface = SwiftUI.Color(uiColor: UIKitColor.surface)
        static let grouped = SwiftUI.Color(uiColor: UIKitColor.grouped)
        static let ink = SwiftUI.Color(uiColor: UIKitColor.ink)
        static let muted = SwiftUI.Color(uiColor: UIKitColor.muted)
        static let tertiary = SwiftUI.Color(uiColor: UIKitColor.tertiary)
        static let line = SwiftUI.Color(uiColor: UIKitColor.line)
        static let recording = SwiftUI.Color(uiColor: UIKitColor.recording)
        static let recordingText = SwiftUI.Color(uiColor: UIKitColor.recordingText)
        static let warning = SwiftUI.Color(uiColor: UIKitColor.warning)
        static let warningText = SwiftUI.Color(uiColor: UIKitColor.warningText)
        static let success = SwiftUI.Color(uiColor: UIKitColor.success)
        static let info = SwiftUI.Color(uiColor: UIKitColor.info)
        static let infoText = SwiftUI.Color(uiColor: UIKitColor.infoText)
        static let reminderDot = recording
        static let eventDot = success
    }
}
#endif
