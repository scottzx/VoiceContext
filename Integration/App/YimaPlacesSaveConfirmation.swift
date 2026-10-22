import Foundation
import Combine
import UIKit

/// A save can only complete after a button event from the mounted confirmation sheet.
@MainActor
final class YimaPlacesSaveConfirmation: ObservableObject {
    static let shared = YimaPlacesSaveConfirmation()

    struct Request: Identifiable {
        let id: UUID
        let place: YimaPlace
        let tags: [String]
    }

    enum Outcome {
        case saved(YimaPlace), cancelled, stale, unavailable, busy, timedOut
    }

    @Published private(set) var request: Request?
    @Published private(set) var isPresenting = false
    @Published private(set) var error: String?

    private var presentationAvailable = false
    private var activeID: UUID?
    private var hasAppeared = false
    private var requestedTags: [String] = []
    private var isCurrent: (@MainActor () -> Bool)?
    private var cancellation: YimaPlacesSaveCancellation?
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var pendingOutcome: Outcome?
    private var monitor: Task<Void, Never>?
    private var dismissalTimeout: Task<Void, Never>?

    func setPresentationAvailable(_ available: Bool) {
        presentationAvailable = available
        if !available, let id = activeID, pendingOutcome == nil {
            finish(id: id, outcome: .unavailable)
        }
    }

    func requestSave(place: YimaPlace, tags: [String],
                     isCurrent: @escaping @MainActor () -> Bool) async -> Outcome {
        let id = UUID()
        let cancellation = YimaPlacesSaveCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, !cancellation.isCancelled else {
                    continuation.resume(returning: .cancelled); return
                }
                guard activeID == nil, !isPresenting else {
                    continuation.resume(returning: .busy); return
                }
                guard canPresent else {
                    continuation.resume(returning: .unavailable); return
                }
                guard isCurrent() else {
                    continuation.resume(returning: .stale); return
                }
                activeID = id
                hasAppeared = false
                requestedTags = tags
                self.isCurrent = isCurrent
                self.cancellation = cancellation
                self.continuation = continuation
                pendingOutcome = nil
                error = nil
                isPresenting = true
                request = Request(id: id, place: place, tags: mergedTags(for: place))
                monitor = Task { @MainActor [weak self] in
                    let clock = ContinuousClock()
                    let started = clock.now
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                        guard let self, self.activeID == id, self.pendingOutcome == nil else { return }
                        guard self.canPresent else { self.finish(id: id, outcome: .unavailable); return }
                        guard !cancellation.isCancelled else { self.finish(id: id, outcome: .cancelled); return }
                        guard isCurrent() else { self.finish(id: id, outcome: .stale); return }
                        let elapsed = started.duration(to: clock.now)
                        if !self.hasAppeared, elapsed >= .seconds(8) {
                            self.finish(id: id, outcome: .unavailable); return
                        }
                        if elapsed >= .seconds(90) {
                            self.finish(id: id, outcome: .timedOut); return
                        }
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
            Task { @MainActor [weak self] in self?.finish(id: id, outcome: .cancelled) }
        }
    }

    func didAppear(id: UUID) {
        guard activeID == id, request?.id == id, pendingOutcome == nil else { return }
        hasAppeared = true
    }

    func confirm(id: UUID) {
        guard let request, request.id == id, activeID == id,
              hasAppeared, pendingOutcome == nil else { return }
        guard cancellation?.isCancelled == false else { finish(id: id, outcome: .cancelled); return }
        guard canPresent else { finish(id: id, outcome: .unavailable); return }
        guard isCurrent?() == true else { finish(id: id, outcome: .stale); return }
        let tags = mergedTags(for: request.place)
        guard tags == request.tags else {
            self.request = Request(id: id, place: request.place, tags: tags)
            error = "此地点的标签已更新，请核对后再次确认。"
            return
        }
        do {
            let place = try YimaPlacesStore.shared.save(request.place, tags: request.tags)
            finish(id: id, outcome: .saved(place))
        } catch {
            self.error = error.localizedDescription
        }
    }

    func cancel(id: UUID) {
        finish(id: id, outcome: .cancelled)
    }

    func presentationDidDismiss() {
        guard let id = activeID else { return }
        if pendingOutcome == nil { finish(id: id, outcome: .cancelled) }
        complete(id: id)
    }

    private var canPresent: Bool {
        presentationAvailable && AppNavigationCenter.shared.available
            && UIApplication.shared.applicationState == .active
    }

    private func mergedTags(for place: YimaPlace) -> [String] {
        let existing = YimaPlacesStore.shared.savedMatch(for: place)?.tags ?? []
        var seen = Set<String>()
        return (existing + place.tags + requestedTags).compactMap { raw in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            return !value.isEmpty && seen.insert(key).inserted ? value : nil
        }
    }

    private func finish(id: UUID, outcome: Outcome) {
        guard activeID == id, pendingOutcome == nil else { return }
        pendingOutcome = outcome
        monitor?.cancel(); monitor = nil
        error = nil
        request = nil
        // A mounted sheet keeps ownership until its real dismissal. A delayed
        // callback must not be able to dismiss a later request.
        dismissalTimeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self, self.activeID == id, let outcome = self.pendingOutcome else { return }
            if self.hasAppeared {
                let continuation = self.continuation
                self.continuation = nil
                continuation?.resume(returning: outcome)
            } else {
                self.complete(id: id)
            }
        }
    }

    private func complete(id: UUID) {
        guard activeID == id, let outcome = pendingOutcome else { return }
        let continuation = continuation
        monitor?.cancel(); monitor = nil
        dismissalTimeout?.cancel(); dismissalTimeout = nil
        self.continuation = nil
        pendingOutcome = nil
        activeID = nil
        isCurrent = nil
        cancellation = nil
        requestedTags = []
        hasAppeared = false
        isPresenting = false
        continuation?.resume(returning: outcome)
    }
}

nonisolated private final class YimaPlacesSaveCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
