//
//  ContentView+Layout.swift
//  Minis - home screen (session list, navigation, settings entry)
//
//  ContentView, layout: `splitLayout` (NavigationSplitView for iPad / wide
//  windows), `stackLayout` (NavigationStack for iPhone / narrow windows) and
//  the split view's `detailView`. `body` picks one by width.
//
//  Map of the ContentView files: ContentView/ContentView.swift.
//

import SwiftUI

private let shareLog = AppLogger(category: "Share")
private let draftLog = AppLogger(category: "DraftSession")

extension ContentView {
    // MARK: - Split Layout (iPad / wide window)

    var splitLayout: some View {
        // [T-ios-gh29-font-scale-split-column] App-base font scale for the iPad
        // split view. `appFontScale()` is environment-based (`.dynamicTypeSize`),
        // and SwiftUI environment does NOT bridge across NavigationSplitView's
        // per-column UIHostingController boundaries — applying it on the
        // container (the previous GH#29 fix) left the column contents unscaled,
        // which is why the font slider still didn't take effect on iPad/Mac.
        // Apply it INSIDE each column instead so the modifier lands on the
        // hosting boundary's inner side and reaches the content. The earlier
        // session-switch / tap lag is a separate issue (ChatSession Array `==`
        // in SwiftUI's transaction flush; an A/B test confirmed the font
        // injection is not its cause), so per-column injection is safe here.
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sessionList(useNavigationLinks: false)
                .appFontScale()
        } detail: {
            detailView
                .appFontScale()
        }
        // [T-ios-tabbar-return-lag] See the compact twin in `stackLayout`.
        .toolbar(selectedSessionId == nil ? .visible : .hidden, for: .tabBar)
    }

    // MARK: - Stack Layout (iPhone / narrow window)

    var stackLayout: some View {
        NavigationStack(path: $navigationPath) {
            sessionList(useNavigationLinks: true)
                #if VOICE_AGENT_FUSION
                .appNavigationPage("chat", canGoBack: false)
                #endif
                .navigationDestination(for: String.self) { id in
                    // `.id(id)` mirrors detailView (iPad): navigationDestination
                    // views are identified by stack depth, not path value, so
                    // replacing the top element in place (menu "New Chat" swaps
                    // [current] → [draft]) would otherwise reuse the old view's
                    // @StateObject vm and nothing visibly changes.
                    #if VOICE_AGENT_FUSION
                    if let route = DSHSessionRoute(rawValue: id) {
                        dshChatDestination(route, showsBackButton: true)
                            .id(id)
                    } else {
                        localChatDestination(id)
                    }
                    #else
                    localChatDestination(id)
                    #endif
                }
        }
        .toolbar(navigationPath.isEmpty ? .visible : .hidden, for: .tabBar)
    }

    @ViewBuilder
    private func localChatDestination(_ id: String) -> some View {
        if id.hasPrefix("remote:") {
            let parts = id.split(separator: ":", maxSplits: 2)
            if parts.count == 3 {
                AIChatView(sessionId: String(parts[2]), remoteDeviceId: String(parts[1]))
                    .id(id)
            }
        } else {
            let isDraft = Self.isNewSessionId(id)
            AIChatView(
                sessionId: isDraft ? nil : id,
                draftId: isDraft ? id : nil,
                initialGroupId: Self.extractGroupId(from: id),
                initialSession: isDraft ? nil : sessionForRow(id),
                initialPrompt: meetingPrompts[id]
            )
                #if VOICE_AGENT_FUSION
                .appNavigationPage("chat.session", params: ["session_id": id], onBack: { commitNavigationPath(NavigationPath()) })
                #endif
                .id(id)
                .onAppear {
                    if currentStackSessionId != id {
                        currentStackSessionId = id
                        // [T-ios-stacknav-transition-attributegraph-race]
                        // Keep the outgoing-id tracker in lockstep.
                        // This branch fires exactly when the two
                        // have DIVERGED — the "swallowed push left
                        // currentStackSessionId set to a target
                        // that never appeared" case documented on
                        // the .moveInputToSession handler — and it
                        // mounts a chat WITHOUT a navigationPath
                        // change, so the observer that normally
                        // maintains previousStackSessionId does not
                        // run. Left unsynced, the next real
                        // transition would suspend whichever id the
                        // last observer pass recorded instead of
                        // the vm actually on screen: the wrong vm
                        // stalls and the real outgoing one keeps
                        // publishing into its teardown.
                        previousStackSessionId = id
                    }
                    SessionBadgeStore.shared.remove(.unread, for: id)
                    shareLog.info("🔄SESSION stackNav APPEAR id=\(id)")
                    HangDetector.mark("chat appear")  // [T-main-stall-marks]
                }
                .onDisappear {
                    shareLog.info("🔄SESSION stackNav DISAPPEAR id=\(id)")
                    HangDetector.mark("chat disappear")  // [T-main-stall-marks]
                }
        }
    }

    // MARK: - Detail View

    @ViewBuilder
    private var detailView: some View {
        if let id = selectedSessionId {
            #if VOICE_AGENT_FUSION
            if let route = DSHSessionRoute(rawValue: id) {
                dshChatDestination(route, showsBackButton: false).id(id)
            } else {
                localDetailView(id)
            }
            #else
            localDetailView(id)
            #endif
        } else {
            VStack(spacing: 12) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("No Conversation Selected")
                    .font(.title3.bold())
                Text("Select a conversation or start a new one")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func localDetailView(_ id: String) -> some View {
        // Draft sessions always pass nil — the VM creates a real session internally
        // on first send. The .id() ensures each draft gets its own View lifecycle.
        let isDraft = Self.isNewSessionId(id)
        let effectiveId: String? = isDraft ? nil : id
        AIChatView(
            sessionId: effectiveId,
            draftId: isDraft ? id : nil,
            initialGroupId: Self.extractGroupId(from: id),
            initialSession: isDraft ? nil : sessionForRow(id),
            showsHeaderBackButton: false,
            initialPrompt: meetingPrompts[id]
        )
            .id(id)
            .onAppear {
                draftLog.info("🔑DRAFT detailView APPEAR id=\(id) effectiveId=\(effectiveId ?? "nil") isDraft=\(isDraft)")
            }
            .onDisappear {
                draftLog.info("🔑DRAFT detailView DISAPPEAR id=\(id)")
            }
    }

    #if VOICE_AGENT_FUSION
    @ViewBuilder
    func dshChatDestination(_ route: DSHSessionRoute, showsBackButton: Bool) -> some View {
        if let service = dshServices.services.first(where: { $0.id == route.serviceID }) {
            AIChatView(sessionId: route.isDraft ? nil : route.sessionID,
                       draftId: route.isDraft ? route.rawValue : nil,
                       dshService: service,
                       initialHeaderTitle: dshSessionTitles[route.rawValue] ?? service.name,
                       showsHeaderBackButton: showsBackButton)
                .onAppear { currentStackSessionId = route.rawValue }
        } else {
            Text("远程服务已移除，请返回聊天首页。")
                .foregroundStyle(.secondary).padding()
        }
    }
    #endif

}
