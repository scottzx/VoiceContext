//
//  BridgedAssistantHeaderV3.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  Cell content for the assistant header row ("✦ <name>" from SOUL.md; tap
//  opens Soul Settings). Hosted by AssistantHeaderCellV3 via the Coordinator's
//  cell provider (+CellConfiguration).
//
//  File map and split rules: CollectionViewMessageListV3.swift (this folder).
//

import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

// MARK: - V3 Bridged Cell Views (no GeometryReader)

/// Header: "✦ Minis" label at the top of each assistant turn.
/// Name comes from SOUL.md (user-editable in Soul Settings); the
/// sparkles glyph is fixed — custom emoji is no longer supported,
/// matching the Soul Settings UI.
///
/// In a GROUP transcript the turn carries a `senderAgentId`, and the header
/// shows that member's own emoji, name and accent instead. This one view is
/// the entire visual difference between a group and a 1:1 conversation:
/// consecutive assistant turns already render as separate header + blocks
/// spans (loadSession breaks the merge chain when the speaker changes), so
/// naming the speaker here is all a reader needs to follow the room.
/// Name comes from SOUL.md (user-editable in Soul Settings).
///
/// [T-ios-assistant-header-open-soul] Tapping the row opens Soul Settings.
/// The row shows the identity the user configured there, so it is the
/// obvious place to reach for when changing it.
struct BridgedAssistantHeaderV3: View {
    @ObservedObject var message: ChatMessage
    var maxWidth: CGFloat = 0
    @State private var soulMeta: SoulMetadata = SoulStore.cachedMetadata
    /// Republishes when an agent is renamed or recolored mid-conversation.
    @ObservedObject private var agents = AgentStore.shared

    /// The speaking member, when this turn came from one.
    private var speaker: AgentProfile? {
        guard let id = message.senderAgentId else { return nil }
        return agents.agents.first { $0.id == id }
    }

    /// [T-ios-assistant-header-open-soul] Injected, NOT read from the
    /// environment.
    ///
    /// `\.openMinisURL` is set on AIChatView, but each cell here is hosted in
    /// its own `UIHostingConfiguration`, which starts a fresh SwiftUI hierarchy
    /// rather than inheriting that one. Reading the environment inside a cell
    /// therefore silently yields the key's default — an action that returns
    /// `.systemAction` and does nothing. (Verified on device: the tap fired, no
    /// navigation happened, and no deep-link log line appeared.) So the handler
    /// is threaded down the same way every other cell callback already is.
    var onOpenSoulSettings: (() -> Void)?
    var body: some View {
        HStack(spacing: 6) {
            if let name = message.remoteAssistantName {
                Image(systemName: "server.rack")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(ChatColors.secondaryText)
                Text(name)
                    .font(YimaDesign.Typography.section)
                    .foregroundStyle(ChatColors.primaryText)
            } else if let speaker {
                Text(speaker.emoji.isEmpty ? "🤖" : speaker.emoji)
                    .font(.system(size: 18))
                    .frame(width: 22, height: 22)
                    .background(ChatColors.secondaryBg)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(speaker.name)
                    .font(YimaDesign.Typography.section)
                    .foregroundStyle(ChatColors.primaryText)
                if !speaker.title.isEmpty {
                    Text(speaker.title)
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(ChatColors.secondaryBg)
                        .clipShape(Capsule())
                        .foregroundStyle(.secondary)
                }
            } else if message.senderAgentId != nil {
                // Spoke in this room, then left it. The line stays readable
                // rather than silently reattributing to the app identity.
                Image(systemName: "person.crop.circle.badge.xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(String(localized: "已退出的成员"))
                    .font(YimaDesign.Typography.section)
                    .foregroundStyle(.secondary)
            } else {
                if soulMeta.icon.isEmpty {
                    Image(systemName: "sparkles")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(ChatColors.secondaryText)
                } else {
                    SoulIconView(icon: soulMeta.icon, size: 22, cornerRadius: 5)
                }
                Text(soulMeta.name.isEmpty ? "Yima" : soulMeta.name)
                    .font(YimaDesign.Typography.section)
                    .foregroundStyle(ChatColors.primaryText)
            }
        }
        // [T-ios-assistant-header-open-soul] Hit area and tap, applied to the
        // icon+name HStack only — NOT to the full-width row below it.
        //
        // The `.frame(maxWidth: .infinity)` modifiers further down stretch this
        // header across the whole message column; making that tappable would
        // turn the empty space beside the name into a button and swallow taps
        // meant for the transcript.
        //
        // `contentShape` makes the whole icon+name box (including the 6pt gap)
        // hittable rather than only the glyph and text pixels.
        //
        .frame(minWidth: YimaDesign.Layout.hitTarget, minHeight: YimaDesign.Layout.hitTarget)
        .contentShape(Rectangle())
        .onTapGesture { onOpenSoulSettings?() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(message.remoteAssistantName == nil ? .isButton : [])
        .accessibilityLabel(message.remoteAssistantName ?? AppLocalized("Open Soul settings"))
        .accessibilityHint(message.remoteAssistantName == nil ? AppLocalized("Change the assistant's name, icon and personality") : "")
        .onReceive(NotificationCenter.default.publisher(for: .soulMdChanged)) { _ in
            soulMeta = SoulStore.cachedMetadata
        }
        .padding(.top, YimaDesign.Space.xs)
        .padding(.bottom, 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxWidth: maxWidth > 0 ? maxWidth : .infinity, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, YimaDesign.Layout.listInset)
        .opacity(message.isCompactedHistory ? 0.5 : 1.0)
        .accessibilityIdentifier("assistantHeader")
    }
}
