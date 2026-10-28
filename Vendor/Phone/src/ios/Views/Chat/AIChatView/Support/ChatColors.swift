//
//  ChatColors.swift
//  Minis - chat page (AIChatView)
//
//  ChatColors: the chat UI's color palette (system colors, light / dark).
//
//  Map of the AIChatView files: AIChatView/AIChatView.swift.
//

import AVFoundation
import AVKit
import Combine
import GameController
import PhotosUI
import QuickLook
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

// MARK: - Color Palette (clean light theme)

enum ChatColors {
    static let background = YimaDesign.Color.canvas
    static let secondaryBg = YimaDesign.Color.grouped
    static let inputIconBg = YimaDesign.Color.grouped
    static let inputIconBorder = YimaDesign.Color.line
    static let inputBg = YimaDesign.Color.surface
    static let inputBorder = YimaDesign.Color.line
    static let primaryText = YimaDesign.Color.ink
    static let secondaryText = YimaDesign.Color.muted
    static let tertiaryText = YimaDesign.Color.tertiary
    static let userBubble = YimaDesign.Color.grouped
    static let toolBg = YimaDesign.Color.surface
    static let toolBorder = YimaDesign.Color.line
    static let accent = YimaDesign.Color.ink
    static let sendButton = YimaDesign.Color.ink
    static let sendButtonDisabled = YimaDesign.Color.tertiary
}
