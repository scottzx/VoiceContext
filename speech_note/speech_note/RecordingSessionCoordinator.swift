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

        var errorDescription: String? {
            switch self {
            case .sessionAlreadyActive: "已有录音正在进行。"
            case .noActiveSession: "当前没有可操作的录音。"
            }
        }
    }

    private(set) var presentationState: PresentationState = .idle {
        didSet { onStateChanged?(presentationState) }
    }
    private(set) var activeRecordingID: UUID?
    private(set) var isApplicationInBackground = false
    var onStateChanged: ((PresentationState) -> Void)?

    private let repository: RecordingRepository
    private let capture: RecordingCapturing
    private let lowStorageGuard: LowStorageGuard
    private let now: () -> Date
    private let enablesRemoteStopCommand: Bool
    private let captureEventContinuation: AsyncStream<AACSegmentRecorder.CaptureEvent>.Continuation
    private var stateMachine: RecordingStateMachine?
    private var activeGapID: UUID?
    private var persistedSegmentIDs: Set<UUID> = []
    private var remoteStopTarget: Any?

    init(
        repository: RecordingRepository,
        capture: RecordingCapturing = AACSegmentRecorder(),
        lowStorageGuard: LowStorageGuard = LowStorageGuard(),
        enablesRemoteStopCommand: Bool = true,
        now: @escaping () -> Date = Date.init
    ) {
        self.repository = repository
        self.capture = capture
        self.lowStorageGuard = lowStorageGuard
        self.enablesRemoteStopCommand = enablesRemoteStopCommand
        self.now = now
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
            isMeeting: isMeeting
        )
        activeRecordingID = recording.id
        stateMachine = RecordingStateMachine(state: .recording)
        persistedSegmentIDs = []
        presentationState = .recording
        try await repository.createRecording(recording, at: startedAt)

        let directory = rootURL
            .appendingPathComponent("Recordings", isDirectory: true)
            .appendingPathComponent(recording.id.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        installCaptureCallbacks()
        do {
            try await capture.start(in: directory, segmentDuration: 5 * 60)
            installRemoteStopCommand()
            return recording.id
        } catch {
            _ = try? await repository.changeState(recordingID: recording.id, to: .failed, at: now())
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
        try await repository.changeState(recordingID: recordingID, to: next, at: now())
        stateMachine = machine
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
        presentationState = .recording
    }

    func stop() async throws {
        guard let recordingID = activeRecordingID, var machine = stateMachine else {
            throw CoordinatorError.noActiveSession
        }
        let stopping = try machine.apply(.stopRequested)
        stateMachine = machine
        presentationState = .stopping
        try await repository.changeState(recordingID: recordingID, to: stopping, at: now())
        try await closeActiveGapIfNeeded(at: now(), sample: capture.currentSample)

        let segment = try capture.stop()
        try await persist(segment: segment, recordingID: recordingID)
        let processing = try machine.apply(.captureStopped)
        stateMachine = machine
        try await repository.changeState(
            recordingID: recordingID,
            to: processing,
            endedAt: segment.endedAt,
            at: segment.endedAt
        )
        presentationState = .processing
        removeRemoteStopCommand()
    }

    func markProcessingCompleted() async throws {
        guard let recordingID = activeRecordingID, var machine = stateMachine else {
            throw CoordinatorError.noActiveSession
        }
        let complete = try machine.apply(.processingCompleted)
        try await repository.changeState(recordingID: recordingID, to: complete, at: now())
        stateMachine = nil
        activeRecordingID = nil
        presentationState = .idle
    }

    func markProcessingFailed(message: String) async throws {
        guard let recordingID = activeRecordingID, var machine = stateMachine else {
            throw CoordinatorError.noActiveSession
        }
        let failed = try machine.apply(.processingFailed)
        try await repository.changeState(recordingID: recordingID, to: failed, at: now())
        stateMachine = nil
        activeRecordingID = nil
        presentationState = .failed(message)
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

        var machine = stateMachine ?? RecordingStateMachine(state: recording.state)
        switch outcome {
        case .completed:
            let complete = try machine.apply(.processingCompleted)
            try await repository.changeState(recordingID: recordingID, to: complete, at: now())
            if activeRecordingID == recordingID {
                stateMachine = nil
                activeRecordingID = nil
                presentationState = .idle
            }
        case let .failed(message):
            let failed = try machine.apply(.processingFailed)
            try await repository.changeState(recordingID: recordingID, to: failed, at: now())
            if activeRecordingID == recordingID {
                // Capture is already stopped. Keeping this in-memory session
                // active after a retryable processing failure prevents the
                // user from starting a new recording, even though the failed
                // Recording and its durable job/error remain available for a
                // later explicit retry.
                stateMachine = nil
                activeRecordingID = nil
                presentationState = .failed(message)
            }
        }
    }

    func retryProcessing(recordingID: UUID) async throws {
        let recording = try await repository.recording(id: recordingID)
        guard let recording else { throw CoordinatorError.noActiveSession }
        var machine = stateMachine ?? RecordingStateMachine(state: recording.state)
        let processing = try machine.apply(.retryProcessing)
        try await repository.changeState(recordingID: recordingID, to: processing, at: now())
        if activeRecordingID == recordingID {
            stateMachine = machine
            presentationState = .processing
        }
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
                try? await persist(segment: segment, recordingID: recordingID)
            }
        }
        let continuation = captureEventContinuation
        capture.onCaptureEvent = { event in
            continuation.yield(event)
        }
    }

    private func persist(segment: AACSegmentRecorder.Segment, recordingID: UUID) async throws {
        guard persistedSegmentIDs.insert(segment.id).inserted else { return }
        let rootURL = repository.rootURL
        let relativePath = relativePath(of: segment.url, under: rootURL)
        let chunk = AudioChunk(
            id: segment.id,
            recordingID: recordingID,
            relativePath: relativePath,
            startSample: segment.startSample,
            endSample: segment.endSample,
            startedAt: segment.startedAt,
            endedAt: segment.endedAt
        )
        try await repository.addChunk(chunk, at: segment.endedAt)
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
        activeGapID = gap.id
        try await repository.openGap(gap, at: date)
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
        let root = rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
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
