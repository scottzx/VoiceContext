import Foundation
import MediaPlayer

@MainActor
protocol RecordingCapturing: AnyObject {
    var onSegmentClosed: (@Sendable (AACSegmentRecorder.Segment) -> Void)? { get set }
    var onCaptureEvent: (@Sendable (AACSegmentRecorder.CaptureEvent) -> Void)? { get set }
    var currentSample: Int64 { get }

    func start(in directory: URL, segmentDuration: TimeInterval) async throws
    func pause() throws
    func resume() throws
    func stop() throws -> AACSegmentRecorder.Segment
}

extension AACSegmentRecorder: RecordingCapturing {}

@MainActor
final class RecordingSessionCoordinator {
    typealias ChunkPersistence = (AudioChunk, Date) async throws -> Void

    enum PresentationState: Equatable {
        case idle
        case recording
        case paused
        case interrupted
        case stopping
        case processing
        case failed(String)
    }

    enum CoordinatorError: LocalizedError {
        case sessionAlreadyActive
        case noActiveSession
        case stopFinalizationUnavailable

        var errorDescription: String? {
            switch self {
            case .sessionAlreadyActive: "已有录音正在进行。"
            case .noActiveSession: "当前没有可操作的录音。"
            case .stopFinalizationUnavailable: "录音停止结果不可用，无法完成收尾。"
            }
        }
    }

    private(set) var presentationState: PresentationState = .idle {
        didSet { onStateChanged?(presentationState) }
    }
    private(set) var captureState: RecordingCaptureState = .idle
    private(set) var activeRecordingID: UUID?
    private(set) var isApplicationInBackground = false
    var onStateChanged: ((PresentationState) -> Void)?
    /// Called after a closed chunk is durable. Processing can begin while
    /// capture continues, so this callback is intentionally independent of
    /// the aggregate Recording state.
    var onChunkClosed: ((UUID, UUID) async -> Void)?

    private let repository: RecordingRepository
    private let capture: RecordingCapturing
    private let lowStorageGuard: LowStorageGuard
    private let now: () -> Date
    private let persistChunk: ChunkPersistence
    private let enablesRemoteStopCommand: Bool
    private let captureEventContinuation: AsyncStream<AACSegmentRecorder.CaptureEvent>.Continuation
    private var stateMachine: RecordingStateMachine?
    private var activeGapID: UUID?
    private var persistedSegmentIDs: Set<UUID> = []
    private var pendingSegments: [UUID: AACSegmentRecorder.Segment] = [:]
    private var segmentPersistenceTask: Task<Result<Void, Error>, Never>?
    private var segmentPersistenceOperationID: UUID?
    private(set) var segmentPersistenceFailureMessage: String?
    private var stoppedCaptureEndedAt: Date?
    private var remoteStopTarget: Any?

    init(
        repository: RecordingRepository,
        capture: RecordingCapturing = AACSegmentRecorder(),
        lowStorageGuard: LowStorageGuard = LowStorageGuard(),
        enablesRemoteStopCommand: Bool = true,
        now: @escaping () -> Date = Date.init,
        persistChunk: ChunkPersistence? = nil
    ) {
        self.repository = repository
        self.capture = capture
        self.lowStorageGuard = lowStorageGuard
        self.enablesRemoteStopCommand = enablesRemoteStopCommand
        self.now = now
        self.persistChunk = persistChunk ?? { [repository] chunk, date in
            try await repository.addChunk(chunk, at: date)
        }
        let (stream, continuation) = AsyncStream<AACSegmentRecorder.CaptureEvent>.makeStream()
        captureEventContinuation = continuation
        Task { @MainActor [weak self] in
            // Capture events are handled serially so an interruption end can
            // never race ahead of its interruption begin across actor hops.
            for await event in stream {
                guard let self else { break }
                try? await handleCaptureEvent(event)
            }
        }
    }

    @discardableResult
    func start(isMeeting: Bool = false, title: String? = nil) async throws -> UUID {
        guard activeRecordingID == nil else { throw CoordinatorError.sessionAlreadyActive }
        let rootURL = repository.rootURL
        try lowStorageGuard.validateCanStartRecording(at: rootURL)

        let startedAt = now()
        let recording = Recording(
            startedAt: startedAt,
            title: title,
            isMeeting: isMeeting,
            languageMode: TranscriptionLanguageMode.current
        )
        activeRecordingID = recording.id
        stateMachine = RecordingStateMachine(state: .recording)
        persistedSegmentIDs = []
        pendingSegments = [:]
        segmentPersistenceTask = nil
        segmentPersistenceOperationID = nil
        segmentPersistenceFailureMessage = nil
        stoppedCaptureEndedAt = nil
        captureState = .preparing
        presentationState = .recording
        try await repository.createRecording(recording, at: startedAt)

        let directory = rootURL
            .appendingPathComponent("Recordings", isDirectory: true)
            .appendingPathComponent(recording.id.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        installCaptureCallbacks()
        do {
            try await capture.start(
                in: directory,
                segmentDuration: AACSegmentRecorder.defaultSegmentDuration
            )
            installRemoteStopCommand()
            captureState = .recording
            return recording.id
        } catch {
            _ = try? await repository.changeState(recordingID: recording.id, to: .failed, at: now())
            captureState = .idle
            presentationState = .failed(error.localizedDescription)
            activeRecordingID = nil
            stateMachine = nil
            throw error
        }
    }

    func pause() async throws {
        guard let recordingID = activeRecordingID, var machine = stateMachine else {
            throw CoordinatorError.noActiveSession
        }
        let next = try machine.apply(.pause)
        try capture.pause()
        let pausedAt = now()
        try await openGap(
            recordingID: recordingID,
            reason: .userPause,
            sample: capture.currentSample,
            at: pausedAt
        )
        try await repository.changeState(recordingID: recordingID, to: next, at: pausedAt)
        stateMachine = machine
        captureState = .paused
        presentationState = .paused
    }

    func resume() async throws {
        guard let recordingID = activeRecordingID, var machine = stateMachine else {
            throw CoordinatorError.noActiveSession
        }
        let next = try machine.apply(.resume)
        try capture.resume()
        try await closeActiveGapIfNeeded(at: now(), sample: capture.currentSample)
        try await repository.changeState(recordingID: recordingID, to: next, at: now())
        stateMachine = machine
        captureState = .recording
        presentationState = .recording
    }

    @discardableResult
    func stop() async throws -> UUID {
        guard let recordingID = activeRecordingID, var machine = stateMachine else {
            throw CoordinatorError.noActiveSession
        }

        if machine.state == .stopping {
            guard let endedAt = stoppedCaptureEndedAt else {
                throw CoordinatorError.stopFinalizationUnavailable
            }
            return try await finalizeStoppedCapture(
                recordingID: recordingID,
                machine: machine,
                endedAt: endedAt
            )
        }

        try await closeActiveGapIfNeeded(at: now(), sample: capture.currentSample)
        let stopping = try machine.apply(.stopRequested)
        try await repository.changeState(recordingID: recordingID, to: stopping, at: now())
        stateMachine = machine
        captureState = .stopping
        presentationState = .stopping

        let segment = try capture.stop()
        removeRemoteStopCommand()
        stoppedCaptureEndedAt = segment.endedAt
        enqueueForPersistence(segment)
        return try await finalizeStoppedCapture(
            recordingID: recordingID,
            machine: machine,
            endedAt: segment.endedAt
        )
    }

    private func finalizeStoppedCapture(
        recordingID: UUID,
        machine: RecordingStateMachine,
        endedAt: Date
    ) async throws -> UUID {
        var machine = machine
        try await flushPendingSegments(recordingID: recordingID)
        let processing = try machine.apply(.captureStopped)
        try await repository.changeState(
            recordingID: recordingID,
            to: processing,
            endedAt: endedAt,
            at: endedAt
        )
        // The durable final chunk and legacy `.processing` projection are now
        // committed. Release only capture-owned identity; processing remains
        // addressable by its explicit Recording ID and durable jobs.
        stateMachine = nil
        activeRecordingID = nil
        activeGapID = nil
        stoppedCaptureEndedAt = nil
        pendingSegments = [:]
        segmentPersistenceTask = nil
        segmentPersistenceOperationID = nil
        captureState = .idle
        // Capture identity is fully released. Remaining transcription is
        // addressable via Recording ID + durable jobs; UI must not present
        // this as an active microphone session.
        presentationState = .idle
        return recordingID
    }

    func markProcessingCompleted(recordingID: UUID) async throws {
        try await finishProcessing(recordingID: recordingID, outcome: .completed)
    }

    func markProcessingFailed(recordingID: UUID, message: String) async throws {
        try await finishProcessing(recordingID: recordingID, outcome: .failed(message: message))
    }

    /// Applies a scheduler result to either the live session or a recovered
    /// processing Recording. The recording ID is explicit so recovery does not
    /// depend on an in-memory microphone session surviving termination.
    func finishProcessing(
        recordingID: UUID,
        outcome: ForegroundTranscriptionScheduler.Outcome.State
    ) async throws {
        let recording = try await repository.recording(id: recordingID)
        guard let recording else { throw CoordinatorError.noActiveSession }

        // Never borrow the live capture state machine: it may belong to a
        // newer Recording while this older Recording finishes in parallel.
        guard activeRecordingID != recordingID else {
            // A durable job outcome can coexist with active capture. The v1
            // aggregate state remains capture-owned until stop; jobs retain
            // the independent processing truth.
            return
        }
        var machine = RecordingStateMachine(state: recording.state)
        switch outcome {
        case .completed:
            guard recording.state != .complete else { return }
            let complete = try machine.apply(.processingCompleted)
            try await repository.changeState(recordingID: recordingID, to: complete, at: now())
            if activeRecordingID == nil {
                presentationState = .idle
            }
        case let .failed(message):
            guard recording.state != .failed else { return }
            let failed = try machine.apply(.processingFailed)
            try await repository.changeState(recordingID: recordingID, to: failed, at: now())
            if activeRecordingID == nil {
                presentationState = .failed(message)
            }
        }
    }

    func retryProcessing(recordingID: UUID) async throws {
        let recording = try await repository.recording(id: recordingID)
        guard let recording else { throw CoordinatorError.noActiveSession }
        guard activeRecordingID != recordingID else {
            // The scheduler job is the processing source of truth while the
            // aggregate Recording state remains capture-owned.
            return
        }
        guard recording.state != .processing else { return }
        var machine = RecordingStateMachine(state: recording.state)
        let processing = try machine.apply(.retryProcessing)
        try await repository.changeState(recordingID: recordingID, to: processing, at: now())
        // Retry must not reclaim global capture chrome. Processing progress
        // belongs to the Recording detail / list row.
        if activeRecordingID == nil {
            presentationState = .idle
        }
    }

    func lifecycleState(recordingID: UUID) async throws -> RecordingLifecycleState {
        guard let recording = try await repository.recording(id: recordingID) else {
            throw CoordinatorError.noActiveSession
        }
        let jobs = try await repository.jobs(recordingID: recordingID)
        let liveCaptureState = activeRecordingID == recordingID ? captureState : nil
        return recording.lifecycleState(jobs: jobs, liveCaptureState: liveCaptureState)
    }

    func applicationEnteredBackground() {
        isApplicationInBackground = true
        // Capture intentionally continues. Metal inference has its own gate.
    }

    func applicationBecameActive() {
        isApplicationInBackground = false
    }

    private func installCaptureCallbacks() {
        capture.onSegmentClosed = { [weak self] segment in
            Task { @MainActor [weak self] in
                guard let self, let recordingID = activeRecordingID else { return }
                enqueueForPersistence(segment)
                do {
                    try await flushPendingSegments(recordingID: recordingID)
                } catch {
                    segmentPersistenceFailureMessage = error.localizedDescription
                }
            }
        }
        let continuation = captureEventContinuation
        capture.onCaptureEvent = { event in
            continuation.yield(event)
        }
    }

    private func enqueueForPersistence(_ segment: AACSegmentRecorder.Segment) {
        guard !persistedSegmentIDs.contains(segment.id) else { return }
        pendingSegments[segment.id] = segment
    }

    private func flushPendingSegments(recordingID: UUID) async throws {
        while !pendingSegments.isEmpty {
            if let task = segmentPersistenceTask, let operationID = segmentPersistenceOperationID {
                _ = await task.value
                if segmentPersistenceOperationID == operationID {
                    segmentPersistenceTask = nil
                    segmentPersistenceOperationID = nil
                }
                continue
            }

            let operationID = UUID()
            let task = Task { @MainActor [weak self] () -> Result<Void, Error> in
                guard let self else { return .success(()) }
                do {
                    try await drainPendingSegments(recordingID: recordingID)
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }
            segmentPersistenceOperationID = operationID
            segmentPersistenceTask = task
            let result = await task.value
            if segmentPersistenceOperationID == operationID {
                segmentPersistenceTask = nil
                segmentPersistenceOperationID = nil
            }
            switch result {
            case .success:
                segmentPersistenceFailureMessage = nil
            case let .failure(error):
                segmentPersistenceFailureMessage = error.localizedDescription
                throw error
            }
        }
        segmentPersistenceFailureMessage = nil
    }

    private func drainPendingSegments(recordingID: UUID) async throws {
        while let segment = pendingSegments.values.sorted(by: segmentPrecedes).first {
            if persistedSegmentIDs.contains(segment.id) {
                pendingSegments.removeValue(forKey: segment.id)
                continue
            }
            let chunk = makeChunk(from: segment, recordingID: recordingID)
            try await persistChunk(chunk, segment.endedAt)
            await onChunkClosed?(recordingID, chunk.id)
            persistedSegmentIDs.insert(segment.id)
            pendingSegments.removeValue(forKey: segment.id)
        }
    }

    private func makeChunk(
        from segment: AACSegmentRecorder.Segment,
        recordingID: UUID
    ) -> AudioChunk {
        let rootURL = repository.rootURL
        let relativePath = relativePath(of: segment.url, under: rootURL)
        return AudioChunk(
            id: segment.id,
            recordingID: recordingID,
            relativePath: relativePath,
            startSample: segment.startSample,
            endSample: segment.endSample,
            startedAt: segment.startedAt,
            endedAt: segment.endedAt
        )
    }

    private func segmentPrecedes(
        _ lhs: AACSegmentRecorder.Segment,
        _ rhs: AACSegmentRecorder.Segment
    ) -> Bool {
        if lhs.startSample != rhs.startSample {
            return lhs.startSample < rhs.startSample
        }
        if lhs.endSample != rhs.endSample {
            return lhs.endSample < rhs.endSample
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func handleCaptureEvent(_ event: AACSegmentRecorder.CaptureEvent) async throws {
        guard let recordingID = activeRecordingID else { return }
        switch event.kind {
        case .interruptionBegan:
            guard var machine = stateMachine else { return }
            let next = try machine.apply(.interruptionBegan)
            stateMachine = machine
            try await repository.changeState(recordingID: recordingID, to: next, at: event.occurredAt)
            try await openGap(
                recordingID: recordingID,
                reason: .systemInterruption,
                sample: event.sampleIndex,
                at: event.occurredAt
            )
            captureState = .interrupted
            presentationState = .interrupted
        case let .interruptionEnded(shouldResume):
            try await closeActiveGapIfNeeded(at: event.occurredAt, sample: event.sampleIndex)
            guard var machine = stateMachine else { return }
            let previous = machine.state
            let next = try machine.apply(.interruptionEnded(shouldResume: shouldResume))
            stateMachine = machine
            if next != previous {
                try await repository.changeState(recordingID: recordingID, to: next, at: event.occurredAt)
            }
            captureState = shouldResume ? .recording : .interrupted
            presentationState = shouldResume ? .recording : .interrupted
        case .routeChanged:
            try await recordPointGap(
                recordingID: recordingID,
                reason: .routeChange,
                sample: event.sampleIndex,
                at: event.occurredAt
            )
        case .writerBackpressure, .writeFailed:
            try await recordPointGap(
                recordingID: recordingID,
                reason: .writeFailure,
                sample: event.sampleIndex,
                at: event.occurredAt
            )
        }
    }

    private func openGap(
        recordingID: UUID,
        reason: RecordingGapReason,
        sample: Int64,
        at date: Date
    ) async throws {
        if activeGapID != nil { return }
        let gap = RecordingGap(
            id: UUID(),
            recordingID: recordingID,
            reason: reason,
            startSample: sample,
            endSample: nil,
            startedAt: date,
            endedAt: nil
        )
        try await repository.openGap(gap, at: date)
        activeGapID = gap.id
    }

    private func closeActiveGapIfNeeded(at date: Date, sample: Int64) async throws {
        guard let gapID = activeGapID else { return }
        try await repository.closeGap(id: gapID, endSample: sample, endedAt: date)
        activeGapID = nil
    }

    private func recordPointGap(
        recordingID: UUID,
        reason: RecordingGapReason,
        sample: Int64,
        at date: Date
    ) async throws {
        let gap = RecordingGap(
            id: UUID(),
            recordingID: recordingID,
            reason: reason,
            startSample: sample,
            endSample: sample,
            startedAt: date,
            endedAt: date
        )
        try await repository.openGap(gap, at: date)
    }

    private func relativePath(of url: URL, under rootURL: URL) -> String {
        // Raw paths only. Both URLs derive from the same repository root, so
        // their paths share an exact prefix. Symlink-aware normalization
        // (standardizedFileURL, standardizingPath) rewrites the existing root
        // /private/var → /var while leaving the child URL untouched on a real
        // device, silently degrading every stored path to lastPathComponent.
        var root = rootURL.path
        if root.hasSuffix("/") { root.removeLast() }
        let path = url.path
        guard path.hasPrefix(root + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(root.count + 1))
    }

    private func installRemoteStopCommand() {
        guard enablesRemoteStopCommand else { return }
        let command = MPRemoteCommandCenter.shared().stopCommand
        command.isEnabled = true
        remoteStopTarget = command.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                try? await self?.stop()
            }
            return .success
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "VoiceContext 正在录音",
            MPNowPlayingInfoPropertyIsLiveStream: true,
        ]
    }

    private func removeRemoteStopCommand() {
        guard enablesRemoteStopCommand else { return }
        let command = MPRemoteCommandCenter.shared().stopCommand
        if let remoteStopTarget {
            command.removeTarget(remoteStopTarget)
        }
        command.isEnabled = false
        remoteStopTarget = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
