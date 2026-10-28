//
//  AIChatView+QuickActions.swift
//  Minis - chat page (AIChatView)
//
//  AIChatView, home-screen Quick Actions: matches a launch action to this page
//  (draft or session id), opens the camera, and marks a workflow chat ready.
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

#if VOICE_AGENT_FUSION
import VoiceRecording
#endif
private let minisLogger = AppLogger(category: "MinisURL")

extension AIChatView {
    // MARK: - Home Screen Quick Actions
    private func handleChatAppearance() {
        let sinceInit = (CFAbsoluteTimeGetCurrent() - AIChatViewModel.onAppearTimestamp) * 1000
        minisLogger.info("[SessionLoad] onAppear T+\(String(format: "%.0f", sinceInit))ms isNew=\(cached.isNew) msgs=\(vm.messages.count)")
        // [T-inputbar-stale-across-reentry] Re-arm the leading-edge seed on
        // EVERY appear. AIChatView is keyed `.id(sessionId)` in ContentView,
        // so re-entering the SAME session reuses the same SwiftUI identity
        // and its @State survives — `inputBarHeight` keeps whatever (possibly
        // wrong) value it last held, and because `didSeedInputBarHeight` is
        // still true the synchronous seed never re-fires. If the composer's
        // geometry doesn't change on re-entry, onGeometryChange emits no new
        // callback either, so nothing ever reconciles it: a too-tall height
        // survives indefinitely across re-renders. Clearing the flag makes
        // the next (guaranteed) geometry callback re-seed authoritatively.
        didSeedInputBarHeight = false
        inputBarHeightDebounce?.cancel()
        inputBarHeightDebounce = nil
        AppLogger(category: "InputBarLayout").info("inputBarHeight re-arm seed on appear (was \(inputBarHeight))")
        if vm.isDSH {
            handleDSHChatAppearance()
            return
        }
        vm.sessionId = sessionId
        vm.draftId = draftId
        vm.remoteDeviceId = remoteDeviceId
        vm.initialGroupId = initialGroupId
        // Snapshot total session count once so the New-Chat onboarding
        // grid only appears for first-time users (no prior sessions).
        // [T-ios-session-coldload-listsessions-block] Use the bare
        // COUNT(*) query, NOT listSessions().count — the latter ran 4
        // un-indexable parts_json LIKE subqueries per session (~0.5s cold
        // on a 100k-message DB) and, on the serialized ChatStore actor,
        // head-of-line-blocked the loadSession() dispatched below, which
        // was the reported ~3s cold-open stall. The comment used to claim
        // "single SQLite COUNT" — now the code actually does one.
        if totalSessionCount == nil {
            Task.detached(priority: .utility) {
                let count = await ChatStore.shared.sessionCount()
                await MainActor.run { totalSessionCount = count }
            }
        }
        if let sessionId { AIChatViewModel.activeSessionId = sessionId }
        vm.ensureKernelBooted()
        if let sessionId {
            if cached.isNew || (vm.messages.isEmpty && !vm.isLoadingSession) {
                // Load session if: (a) VM is freshly created, or (b) cache hit but messages
                // are empty — this can happen on iOS 16 where NavigationStack may recreate
                // @StateObject unexpectedly, causing isNew=false but an empty VM.
                minisLogger.info("🔄SESSION AIChatView.onAppear loading session \(sessionId) isNew=\(cached.isNew) msgs=\(vm.messages.count)")
                // [T-ios-session-coldload-listsessions-block] .userInitiated
                // so the actual session-open work wins the serialized
                // ChatStore actor queue over background sidebar-refresh
                // listSessions() scans that would otherwise starve it.
                Task(priority: .userInitiated) {
                    // Phase A: auto-repair any sortOrder / legacy marker anomalies
                    // before loading. Cheap no-op if the session is healthy.
                    _ = await ChatStore.shared.repairSessionIfNeeded(sessionId: sessionId)
                    await vm.loadSession()
                }
            } else if vm.messages.isEmpty && vm.isLoadingSession {
                // iOS 16 edge case: a previous view instance started loadSession()
                // but this view appeared before it completed. Wait for it to finish,
                // then reload if messages are still empty (objectWillChange may have
                // fired between old and new CachedViewModel subscriptions).
                minisLogger.info("🔄SESSION AIChatView.onAppear WAITING for in-flight load session=\(sessionId)")
                Task {
                    // Wait for the in-flight load to complete (poll at short intervals)
                    for _ in 0..<20 {
                        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                        if !vm.isLoadingSession { break }
                    }
                    // If messages are still empty after the load completed, retry
                    if vm.messages.isEmpty && !vm.isLoadingSession {
                        minisLogger.warning("🔄SESSION AIChatView.onAppear RETRY load — messages still empty after in-flight load for \(sessionId)")
                        await vm.loadSession()
                    }
                }
            } else {
                let reuseStart = CFAbsoluteTimeGetCurrent()
                minisLogger.info("🔄SESSION AIChatView.onAppear REUSING cached vm for \(sessionId) isProcessing=\(vm.isProcessing) msgs=\(vm.messages.count)")
                // Remount minis for this session (in case another session took over)
                vm.mountMinis(for: sessionId)
                // While the user was off this view, an iCloud / LAN
                // sync may have landed new messages (or applied a
                // tombstone). reloadMessagesFromDB internally compares
                // SQLite count + max(sort_order) + (id, sort_order)
                // hash against the VM's last-known baseline and only
                // re-renders on diff. Skip when isProcessing — the
                // active stream owns messages right now and a reload
                // would clobber the in-flight assistant turn.
                if !vm.isProcessing && !vm.isCompacting {
                    Task { @MainActor in await vm.reloadMessagesFromDB(reason: "AIChatView.onAppear-reuse") }
                }
                vm.consumeDeferredSnapshotIfNeeded()
                let mountElapsed = (CFAbsoluteTimeGetCurrent() - reuseStart) * 1000
                // Cached VM already has messages — trigger scroll-to-bottom
                // since isLoadingSession won't transition and its onChange won't fire.
                if !vm.messages.isEmpty {
                    vm.forceScrollToBottom.send()
                }
                let totalElapsed = (CFAbsoluteTimeGetCurrent() - reuseStart) * 1000
                minisLogger.info("[SessionLoad] \(sessionId) — REUSE: \(String(format: "%.1f", totalElapsed))ms [mount: \(String(format: "%.1f", mountElapsed)) | msgs: \(vm.messages.count)]")
            }
        } else {
            minisLogger.info("🔄SESSION AIChatView.onAppear nil sessionId — draft mode")
            // Draft session — auto-focus input for immediate typing
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard !hasOverlayPresented, isChatViewVisible else { return }
                inputFocused = true
            }
        }
        minisLogger.info("[Share] AIChatView.onAppear: sessionId=\(sessionId ?? "nil") bufferVersion=\(shareCoordinator.bufferVersion) hasBuffer=\(shareCoordinator.pendingShareBuffer != nil)")
        injectPendingShareIfNeeded()
        injectPendingTransferIfNeeded()
        isChatViewVisible = true
        refreshTitlePillSession()
        // Notify workflow that THIS view is mounted + visible. If
        // the workflow is waiting for our session id, it will
        // transition to chatReady — our state observer below picks
        // that up and flips `showCamera`. Transient draft views
        // (sessionId=nil) won't match the workflow's target and
        // are correctly skipped.
        tryMarkWorkflowChatReady(reason: "onAppear")
    }

    private func handleDSHChatAppearance() {
        isChatViewVisible = true
        if vm.dshTitle.isEmpty { vm.dshTitle = initialHeaderTitle ?? "" }
        if let service = vm.dshService {
            AIChatViewModel.activeSessionId = vm.sessionId.map {
                ViewModelCache.dshKey(serviceID: service.id, sessionID: $0)
            } ?? ViewModelCache.dshDraftKey(serviceID: service.id, draftID: vm.draftId ?? "draft")
        }
        vm.consumeDeferredSnapshotIfNeeded()
        Task { await vm.loadDSHSession() }
    }


    /// Stable id this view represents in the navigation stack. For
    /// draft sessions (`__new__…`) this is the draftId; for opened
    /// sessions it's the real sessionId. `vm.sessionId` cannot be used
    /// because it stays nil for drafts until the first message is sent,
    /// which is too late for the workflow handoff.
    private var quickActionMatchId: String? { sessionId ?? draftId }

    var quickActionObserver: QuickActionObserverModifier {
        QuickActionObserverModifier(
            sessionId: quickActionMatchId,
            isVisible: isChatViewVisible && !vm.isDSH,
            onWaitingMatch: { tryMarkWorkflowChatReady(reason: "modifier-waiting") },
            onChatReady: { action in applyQuickAction(action) }
        )
    }

    /// Tell the workflow this view is alive + showing the right
    /// session, so it can promote `waitingForChatMount → chatReady`.
    /// Idempotent: workflow ignores the call unless its target id
    /// matches and the state is `waitingForChatMount`.
    func tryMarkWorkflowChatReady(reason: String) {
        guard let sid = quickActionMatchId, isChatViewVisible else { return }
        guard !vm.isDSH else { return }
        if case .waitingForChatMount(_, let target) = QuickActionWorkflow.shared.state, target == sid {
            minisLogger.info("[QuickAction] tryMarkWorkflowChatReady reason=\(reason) sid=\(sid)")
            QuickActionWorkflow.shared.markChatReady(sessionId: sid)
        }
    }

    /// Apply a one-shot launch action delivered by the workflow's
    /// `chatReady` state. Flips the relevant @State so SwiftUI mounts
    /// the camera sheet / starts speech recognition.
    private func applyQuickAction(_ action: ChatLaunchAction) {
        minisLogger.info("[QuickAction] applyQuickAction action=\(String(describing: action)) showCamera=\(showCamera) hasOverlay=\(hasOverlayPresented) chatVisible=\(isChatViewVisible)")
        guard !vm.isDSH else { return }
        // Guard against late deliveries to a view that already
        // disappeared — workflow re-publishes chatReady on retry and
        // the modifier's onReceive can fire after our onDisappear set
        // isChatViewVisible=false. In that case let the workflow's
        // retry timer re-publish so the next live view picks it up.
        guard isChatViewVisible else {
            minisLogger.info("[QuickAction] applyQuickAction skipped — view not visible")
            return
        }
        switch action {
        case .startVoice:
            // Mirror the mic button's action: ask for speech +
            guard ensureLocalVoiceModels() else {
                QuickActionWorkflow.shared.markCoverPresented()
                return
            }
            // microphone permission, then start recording. Drop
            // input-focus so the keyboard doesn't fight the speech
            // session for focus.
            Task { @MainActor in
                guard speechManager.state == .idle else { return }
                let granted = await speechManager.requestPermissions()
                guard granted else { return }
                inputFocused = false
                lastRecognizedLength = 0
                try? speechManager.startRecording()
                // [T-voice-input-mode-preference-ios] Mark the composition as
                // voice-assisted so the send doesn't flip the preference to
                // "text". (No preference write here — the quick action is its
                // own explicit intent, not a mic tap.)
                vm.voiceUsedInComposition = true
            }
            // No cover for voice — close the workflow loop immediately
            // so the retry timer doesn't fire and re-trigger the mic.
            QuickActionWorkflow.shared.markCoverPresented()
        case .openCamera:
            // Drop the keyboard so the system camera UI animates in
            // without fighting the input bar for the screen. The
            // workflow guarantees we're only invoked when the view is
            // visible + the cover binding is attached, so no runloop
            // hop is needed.
            inputFocused = false
            showCamera = true
            minisLogger.info("[QuickAction] openCamera — showCamera=true")
        }
    }
}
