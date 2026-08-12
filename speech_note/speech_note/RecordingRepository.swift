import Foundation

actor RecordingRepository {
    nonisolated struct RecoveryResult: Equatable, Sendable {
        let replayedEventCount: Int
        let interruptedRecordingIDs: [UUID]
    }

    nonisolated struct RetentionResult: Equatable, Sendable {
        let removedChunkIDs: [UUID]
        let reclaimedBytes: Int64
    }

    let rootURL: URL

    private let index: RecordingIndex
    private let journal: RecordingJournal
    private let fileManager: FileManager

    init(rootURL: URL, fileManager: FileManager = .default) throws {
        self.rootURL = rootURL
        self.fileManager = fileManager
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        index = try RecordingIndex(url: rootURL.appendingPathComponent("recording-index.sqlite"))
        journal = try RecordingJournal(url: rootURL.appendingPathComponent("recording-journal.jsonl"))
    }

    @discardableResult
    func replayJournal() throws -> Int {
        var applied = 0
        for event in try journal.events() where try index.apply(event) {
            applied += 1
        }
        return applied
    }

    @discardableResult
    func createRecording(_ recording: Recording, at date: Date) throws -> RecordingJournalEvent {
        try persist(.init(occurredAt: date, payload: .recordingCreated(recording)))
    }

    @discardableResult
    func changeState(
        recordingID: UUID,
        to state: RecordingState,
        endedAt: Date? = nil,
        at date: Date
    ) throws -> RecordingJournalEvent {
        try persist(.init(
            occurredAt: date,
            payload: .recordingStateChanged(recordingID: recordingID, state: state, endedAt: endedAt)
        ))
    }

    @discardableResult
    func addChunk(_ chunk: AudioChunk, at date: Date) throws -> RecordingJournalEvent {
        try persist(.init(occurredAt: date, payload: .chunkClosed(chunk)))
    }

    func setChunkContinuation(
        id: UUID,
        requiresContinuation: Bool,
        at date: Date
    ) throws -> RecordingJournalEvent {
        try persist(.init(
            occurredAt: date,
            payload: .chunkContinuationChanged(
                chunkID: id,
                requiresContinuation: requiresContinuation
            )
        ))
    }

    /// A completed Recording has no chunk left to continue an open tail, so any
    /// remaining cross-chunk marker is stale. Only clears markers after the
    /// Recording is durably complete: while jobs are still pending, a marker on
    /// an earlier chunk legitimately tells its successor to include the tail.
    /// Returns the cleared chunk IDs (empty for an in-progress Recording).
    @discardableResult
    func clearContinuationMarkersForCompletedRecording(
        recordingID: UUID,
        at date: Date
    ) throws -> [UUID] {
        guard let recording = try index.recording(id: recordingID),
              recording.endedAt != nil,
              recording.state == .complete else { return [] }
        let marked = try index.chunks(recordingID: recordingID)
            .filter { $0.requiresContinuation }
        for chunk in marked {
            try persist(.init(
                occurredAt: date,
                payload: .chunkContinuationChanged(
                    chunkID: chunk.id,
                    requiresContinuation: false
                )
            ))
        }
        return marked.map(\.id)
    }

    @discardableResult
    func upsertJob(_ job: RecordingJob, at date: Date) throws -> RecordingJournalEvent {
        try persist(.init(occurredAt: date, payload: .jobUpserted(job)))
    }

    @discardableResult
    func openGap(_ gap: RecordingGap, at date: Date) throws -> RecordingJournalEvent {
        try persist(.init(occurredAt: date, payload: .gapOpened(gap)))
    }

    @discardableResult
    func closeGap(id: UUID, endSample: Int64, endedAt: Date) throws -> RecordingJournalEvent {
        try persist(.init(
            occurredAt: endedAt,
            payload: .gapClosed(gapID: id, endSample: endSample, endedAt: endedAt)
        ))
    }

    func setRecordingRetention(
        recordingID: UUID,
        retention: AudioRetention,
        at date: Date
    ) throws {
        try persist(.init(
            occurredAt: date,
            payload: .retentionChanged(recordingID: recordingID, retention: retention)
        ))
    }

    func setChunkPinned(id: UUID, isPinned: Bool, at date: Date) throws {
        try persist(.init(
            occurredAt: date,
            payload: .chunkPinChanged(chunkID: id, isPinned: isPinned)
        ))
    }

    func recording(id: UUID) throws -> Recording? {
        try index.recording(id: id)
    }

    func recordings(states: Set<RecordingState>? = nil) throws -> [Recording] {
        try index.recordings(states: states)
    }

    func chunks(recordingID: UUID) throws -> [AudioChunk] {
        try index.chunks(recordingID: recordingID)
    }

    func jobs(recordingID: UUID) throws -> [RecordingJob] {
        try index.jobs(recordingID: recordingID)
    }

    func jobs(
        kind: RecordingJobKind,
        states: Set<RecordingJobState>
    ) throws -> [RecordingJob] {
        try index.jobs(kind: kind, states: states)
    }

    func gaps(recordingID: UUID) throws -> [RecordingGap] {
        try index.gaps(recordingID: recordingID)
    }

    func recoverUnfinished(at date: Date) throws -> RecoveryResult {
        let replayed = try replayJournal()
        let unfinished = try index.recordings(states: [.recording, .paused, .stopping])
        var recovered: [UUID] = []

        for recording in unfinished {
            var stateMachine = RecordingStateMachine(state: recording.state)
            let state = try stateMachine.apply(.recoveredAfterTermination)
            let sample = try index.chunks(recordingID: recording.id).last?.endSample ?? 0
            let gap = RecordingGap(
                id: UUID(),
                recordingID: recording.id,
                reason: .recoveredAfterTermination,
                startSample: sample,
                endSample: nil,
                startedAt: date,
                endedAt: nil
            )
            try changeState(recordingID: recording.id, to: state, at: date)
            try openGap(gap, at: date)
            for var job in try index.jobs(recordingID: recording.id) where job.state == .running {
                job.state = .pending
                job.lastError = "recoveredAfterTermination"
                job.updatedAt = date
                try upsertJob(job, at: date)
            }
            recovered.append(recording.id)
        }

        // Capture may have stopped just before termination. In that window a
        // Recording is already `processing`, but its transcription job may
        // not yet be durable (or its durable job result may not yet have been
        // applied to the Recording). Reconcile both before the foreground
        // scheduler resumes so relaunch cannot leave a stopped recording in
        // "正在处理" forever.
        for recording in try index.recordings(states: [.processing]) {
            let transcriptionJobs = try index.jobs(recordingID: recording.id)
                .filter { $0.kind == .transcription }
            guard let job = transcriptionJobs.last else {
                // The minute-level queue restores a stopped Recording as one
                // durable job per closed chunk, never as a legacy
                // whole-recording job that would transcribe it a second time.
                let closedChunks = try index.chunks(recordingID: recording.id)
                    .filter { $0.state == .closed }
                    .sorted { $0.startSample < $1.startSample }
                for chunk in closedChunks {
                    try upsertJob(RecordingJob(
                        id: UUID(),
                        recordingID: recording.id,
                        chunkID: chunk.id,
                        kind: .transcription,
                        state: .pending,
                        attemptCount: 0,
                        lastError: nil,
                        createdAt: date,
                        updatedAt: date
                    ), at: date)
                }
                continue
            }

            switch job.state {
            case .pending:
                break
            case .running:
                var pending = job
                pending.state = .pending
                pending.lastError = "recoveredAfterTermination"
                pending.updatedAt = date
                try upsertJob(pending, at: date)
            case .completed:
                try changeState(recordingID: recording.id, to: .complete, at: date)
                try clearContinuationMarkersForCompletedRecording(
                    recordingID: recording.id,
                    at: date
                )
            case .failed:
                try changeState(recordingID: recording.id, to: .failed, at: date)
            }
        }

        return RecoveryResult(
            replayedEventCount: replayed,
            interruptedRecordingIDs: recovered
        )
    }

    func purgeExpiredAudio(at date: Date) throws -> RetentionResult {
        let candidates = try index.purgeCandidates(at: date)
        var removed: [UUID] = []
        var reclaimedBytes: Int64 = 0

        for candidate in candidates {
            let url = rootURL.appendingPathComponent(candidate.relativePath)
            if fileManager.fileExists(atPath: url.path) {
                let attributes = try fileManager.attributesOfItem(atPath: url.path)
                reclaimedBytes += (attributes[.size] as? NSNumber)?.int64Value ?? 0
                try fileManager.removeItem(at: url)
            }
            try persist(.init(
                occurredAt: date,
                payload: .chunkAudioRemoved(chunkID: candidate.chunkID, removedAt: date)
            ))
            removed.append(candidate.chunkID)
        }
        return RetentionResult(removedChunkIDs: removed, reclaimedBytes: reclaimedBytes)
    }

    var schemaVersion: Int {
        index.schemaVersion
    }

    var appliedEventCount: Int {
        index.appliedEventCount
    }

    @discardableResult
    private func persist(_ event: RecordingJournalEvent) throws -> RecordingJournalEvent {
        // Journal is the durability boundary. If the process dies between the
        // two writes, replay applies the already-flushed event to SQLite.
        try journal.append(event)
        _ = try index.apply(event)
        return event
    }
}

nonisolated struct LowStorageGuard: Sendable {
    nonisolated enum StorageError: LocalizedError, Equatable {
        case unavailable
        case insufficient(availableBytes: Int64, minimumBytes: Int64)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                "无法确认剩余存储空间，录音未开始。"
            case let .insufficient(available, minimum):
                "剩余存储空间不足（\(available) bytes）；至少需要 \(minimum) bytes。"
            }
        }
    }

    static let defaultMinimumAvailableBytes: Int64 = 512 * 1_024 * 1_024

    let minimumAvailableBytes: Int64
    private let capacity: @Sendable (URL) throws -> Int64?

    init(
        minimumAvailableBytes: Int64 = defaultMinimumAvailableBytes,
        capacity: @escaping @Sendable (URL) throws -> Int64? = LowStorageGuard.volumeCapacity
    ) {
        self.minimumAvailableBytes = minimumAvailableBytes
        self.capacity = capacity
    }

    func validateCanStartRecording(at url: URL) throws {
        guard let available = try capacity(url) else { throw StorageError.unavailable }
        guard available >= minimumAvailableBytes else {
            throw StorageError.insufficient(
                availableBytes: available,
                minimumBytes: minimumAvailableBytes
            )
        }
    }

    private static func volumeCapacity(at url: URL) throws -> Int64? {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values.volumeAvailableCapacityForImportantUsage
    }
}
