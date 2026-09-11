@preconcurrency import AVFoundation
import Foundation

actor RecordingRepository {
    nonisolated struct RecoveryResult: Equatable, Sendable {
        let replayedEventCount: Int
        let interruptedRecordingIDs: [UUID]
    }

    nonisolated struct RetentionResult: Equatable, Sendable {
        let removedChunkIDs: [UUID]
        let removedImportedAssetIDs: [UUID]
        let reclaimedBytes: Int64

        init(
            removedChunkIDs: [UUID],
            removedImportedAssetIDs: [UUID] = [],
            reclaimedBytes: Int64
        ) {
            self.removedChunkIDs = removedChunkIDs
            self.removedImportedAssetIDs = removedImportedAssetIDs
            self.reclaimedBytes = reclaimedBytes
        }
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

    func setRecordingTitle(
        recordingID: UUID,
        title: String?,
        at date: Date
    ) throws {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        try persist(.init(
            occurredAt: date,
            payload: .recordingTitleChanged(
                recordingID: recordingID,
                title: (trimmed?.isEmpty == false) ? trimmed : nil
            )
        ))
    }

    func setRecordingLocation(
        recordingID: UUID,
        locationName: String?,
        at date: Date
    ) throws {
        let trimmed = locationName?.trimmingCharacters(in: .whitespacesAndNewlines)
        try persist(.init(
            occurredAt: date,
            payload: .recordingLocationChanged(
                recordingID: recordingID,
                locationName: (trimmed?.isEmpty == false) ? trimmed : nil
            )
        ))
    }

    func setRecordingMemo(
        recordingID: UUID,
        memo: String?,
        at date: Date
    ) throws {
        let hasContent = memo?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        try persist(.init(
            occurredAt: date,
            payload: .recordingMemoChanged(
                recordingID: recordingID,
                memo: hasContent ? memo : nil
            )
        ))
    }

    func setRecordingMeeting(
        recordingID: UUID,
        isMeeting: Bool,
        at date: Date
    ) throws {
        try persist(.init(
            occurredAt: date,
            payload: .recordingMeetingChanged(
                recordingID: recordingID,
                isMeeting: isMeeting
            )
        ))
    }

    @discardableResult
    func addImportedAudioAsset(_ asset: ImportedAudioAsset, at date: Date) throws -> RecordingJournalEvent {
        try persist(.init(occurredAt: date, payload: .importedAudioAssetCreated(asset)))
    }

    @discardableResult
    func upsertProcessingRange(_ range: ProcessingRange, at date: Date) throws -> RecordingJournalEvent {
        try persist(.init(occurredAt: date, payload: .processingRangeUpserted(range)))
    }

    func setProcessingRangeContinuation(
        id: UUID,
        requiresContinuation: Bool,
        at date: Date
    ) throws -> RecordingJournalEvent {
        try persist(.init(
            occurredAt: date,
            payload: .processingRangeContinuationChanged(
                rangeID: id,
                requiresContinuation: requiresContinuation
            )
        ))
    }

    /// Persists an imported Recording, its private asset, and logical ranges.
    func commitImportedAudio(
        recording: Recording,
        asset: ImportedAudioAsset,
        ranges: [ProcessingRange],
        at date: Date
    ) throws {
        try createRecording(recording, at: date)
        try addImportedAudioAsset(asset, at: date)
        for range in ranges {
            try upsertProcessingRange(range, at: date)
        }
    }

    func importedAudioAsset(recordingID: UUID) throws -> ImportedAudioAsset? {
        try index.importedAudioAsset(recordingID: recordingID)
    }

    @discardableResult
    func updateImportedAudioAsset(_ asset: ImportedAudioAsset, at date: Date) throws -> RecordingJournalEvent {
        try persist(.init(occurredAt: date, payload: .importedAudioAssetUpdated(asset)))
    }

    func processingRanges(recordingID: UUID) throws -> [ProcessingRange] {
        try index.processingRanges(recordingID: recordingID)
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

    func allAudioDurations() throws -> [UUID: TimeInterval] {
        try index.allAudioDurations()
    }

    func audioDuration(recordingID: UUID) throws -> TimeInterval? {
        try index.audioDuration(recordingID: recordingID)
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

    /// Atomically claims a pending job and returns its immutable execution
    /// identity. The SQLite transaction enforces the global running guard even
    /// if two repository/scheduler instances point at the same container.
    func claimTranscriptionJob(
        id: UUID,
        pipelineVersion: Int = JobExecutionLease.currentPipelineVersion,
        at date: Date
    ) throws -> JobExecutionLease? {
        let token = UUID()
        guard let job = try index.claimTranscriptionJob(
            id: id,
            executionToken: token,
            pipelineVersion: pipelineVersion,
            at: date
        ) else { return nil }

        // The index transaction is already durable. Mirror the claimed state
        // to the append-only journal so a rebuilt index preserves the attempt.
        let event = RecordingJournalEvent(occurredAt: date, payload: .jobUpserted(job))
        try journal.append(event)
        _ = try index.apply(event)

        let target: JobExecutionSourceTarget
        if let chunkID = job.chunkID {
            target = .audioChunk(chunkID)
        } else if let rangeID = job.processingRangeID {
            target = .processingRange(rangeID)
        } else {
            target = .legacyWholeRecording
        }
        return JobExecutionLease(
            jobID: job.id,
            recordingID: job.recordingID,
            sourceTarget: target,
            executionToken: token,
            pipelineVersion: pipelineVersion,
            startedAt: date
        )
    }

    func validateExecutionLease(_ lease: JobExecutionLease) throws -> Bool {
        try index.validateTranscriptionLease(
            jobID: lease.jobID,
            executionToken: lease.executionToken,
            pipelineVersion: lease.pipelineVersion
        )
    }

    /// Claims one bounded CAM++ source job. Repository actor isolation keeps
    /// the check-and-write serial, while the execution token prevents a late
    /// result from a cancelled attempt from replacing a retry.
    func claimSpeakerEmbedding(
        jobID: UUID,
        recordingID: UUID,
        pipelineVersion: Int,
        at date: Date
    ) throws -> RecordingJob? {
        guard try index.jobs(kind: .speakerEmbedding, states: [.running]).isEmpty,
              var job = try index.jobs(recordingID: recordingID).first(where: {
                  $0.id == jobID && $0.kind == .speakerEmbedding && $0.state == .pending
              }) else { return nil }
        job.state = .running
        job.attemptCount += 1
        job.lastError = nil
        job.pipelineVersion = pipelineVersion
        job.executionToken = UUID()
        job.startedAt = date
        job.terminationReason = nil
        job.updatedAt = date
        try upsertJob(job, at: date)
        return job
    }

    func validateSpeakerEmbedding(
        jobID: UUID,
        recordingID: UUID,
        executionToken: UUID,
        pipelineVersion: Int
    ) throws -> Bool {
        try index.jobs(recordingID: recordingID).contains {
            $0.id == jobID
                && $0.kind == .speakerEmbedding
                && $0.state == .running
                && $0.executionToken == executionToken
                && $0.pipelineVersion == pipelineVersion
        }
    }

    @discardableResult
    func finishSpeakerEmbedding(
        jobID: UUID,
        recordingID: UUID,
        executionToken: UUID,
        state: RecordingJobState,
        lastError: String? = nil,
        terminationReason: String? = nil,
        at date: Date
    ) throws -> RecordingJob? {
        guard var job = try index.jobs(recordingID: recordingID).first(where: {
            $0.id == jobID
                && $0.kind == .speakerEmbedding
                && $0.state == .running
                && $0.executionToken == executionToken
        }) else { return nil }
        job.state = state
        job.lastError = lastError
        job.executionToken = nil
        job.startedAt = nil
        job.terminationReason = terminationReason
        job.updatedAt = date
        try upsertJob(job, at: date)
        return job
    }

    /// Token-guarded state transition. Nil means the attempt lost ownership,
    /// so its late outcome must be discarded without notifying observers.
    func finishExecutionLease(
        _ lease: JobExecutionLease,
        state: RecordingJobState,
        lastError: String? = nil,
        terminationReason: String? = nil,
        at date: Date
    ) throws -> RecordingJob? {
        guard let job = try index.finishTranscriptionLease(
            jobID: lease.jobID,
            executionToken: lease.executionToken,
            state: state,
            lastError: lastError,
            terminationReason: terminationReason,
            at: date
        ) else { return nil }
        let event = RecordingJournalEvent(occurredAt: date, payload: .jobUpserted(job))
        try journal.append(event)
        _ = try index.apply(event)
        return job
    }

    @discardableResult
    func invalidateRunningTranscriptionLeases(reason: String, at date: Date) throws -> [UUID] {
        let running = try index.jobs(kind: .transcription, states: [.running])
        var invalidated: [UUID] = []
        for job in running {
            if let token = job.executionToken {
                let lease = JobExecutionLease(
                    jobID: job.id,
                    recordingID: job.recordingID,
                    sourceTarget: job.chunkID.map(JobExecutionSourceTarget.audioChunk)
                        ?? job.processingRangeID.map(JobExecutionSourceTarget.processingRange)
                        ?? .legacyWholeRecording,
                    executionToken: token,
                    pipelineVersion: job.pipelineVersion,
                    startedAt: job.startedAt ?? job.updatedAt
                )
                if try finishExecutionLease(
                    lease,
                    state: .pending,
                    lastError: reason,
                    terminationReason: reason,
                    at: date
                ) != nil {
                    invalidated.append(job.id)
                }
            } else {
                var pending = job
                pending.state = .pending
                pending.lastError = reason
                pending.terminationReason = reason
                pending.executionToken = nil
                pending.updatedAt = date
                try upsertJob(pending, at: date)
                invalidated.append(job.id)
            }
        }
        return invalidated
    }

    /// Any transcription retry invalidates every speaker job derived from the
    /// previous text/audio pass. Returning embedding rows to pending clears
    /// user-visible speaker progress immediately instead of waiting for the
    /// finalizer to discover missing observation batches later.
    @discardableResult
    func resetSpeakerFinalizationForRetranscription(
        recordingID: UUID,
        at date: Date
    ) throws -> RecordingJob? {
        var finalization: RecordingJob?
        for var job in try index.jobs(recordingID: recordingID) where
            job.kind == .speakerEmbedding || job.kind == .speakerFinalization
        {
            job.state = .pending
            job.lastError = nil
            job.pipelineVersion = job.kind == .speakerEmbedding
                ? SpeakerEmbeddingJob.currentPipelineVersion
                : SpeakerFinalizationJob.currentPipelineVersion
            job.executionToken = nil
            job.startedAt = nil
            job.terminationReason = "invalidatedByRetranscription"
            job.updatedAt = date
            try upsertJob(job, at: date)
            if job.kind == .speakerFinalization {
                finalization = job
            }
        }
        return finalization
    }

    /// Full retranscription is a new stage attempt, so all ASR progress must
    /// become pending before any source is allowed to execute again.
    func resetTranscriptionForRetranscription(
        recordingID: UUID,
        at date: Date
    ) throws {
        for var job in try index.jobs(recordingID: recordingID) where
            job.kind == .transcription
        {
            job.state = .pending
            job.lastError = nil
            job.executionToken = nil
            job.startedAt = nil
            job.terminationReason = "userRetranscription"
            job.updatedAt = date
            try upsertJob(job, at: date)
        }
    }

    /// Repairs every crash-left speaker lease before broader recording
    /// recovery. This pre-pass is deliberately independent: one malformed
    /// historical Recording must not leave later meetings permanently
    /// displayed as if their original finalizer were still alive.
    @discardableResult
    func recoverRunningSpeakerFinalizations(at date: Date) throws -> [UUID] {
        let running = try index.jobs(kind: .speakerFinalization, states: [.running])
        var recoveredRecordingIDs: [UUID] = []
        for var job in running {
            job.state = .pending
            job.lastError = "recoveredAfterTermination"
            job.executionToken = nil
            job.startedAt = nil
            job.terminationReason = "recoveredAfterTermination"
            job.updatedAt = date
            try upsertJob(job, at: date)
            recoveredRecordingIDs.append(job.recordingID)
        }
        return recoveredRecordingIDs
    }

    func claimSpeakerFinalization(
        jobID: UUID,
        recordingID: UUID,
        pipelineVersion: Int,
        at date: Date
    ) throws -> RecordingJob? {
        guard var job = try index.jobs(recordingID: recordingID).first(where: {
            $0.id == jobID && $0.kind == .speakerFinalization && $0.state == .pending
        }) else { return nil }
        job.state = .running
        job.attemptCount += 1
        job.lastError = nil
        job.pipelineVersion = pipelineVersion
        job.executionToken = UUID()
        job.startedAt = date
        job.terminationReason = nil
        job.updatedAt = date
        try upsertJob(job, at: date)
        return job
    }

    func validateSpeakerFinalization(
        jobID: UUID,
        recordingID: UUID,
        executionToken: UUID,
        pipelineVersion: Int
    ) throws -> Bool {
        try index.jobs(recordingID: recordingID).contains {
            $0.id == jobID
                && $0.kind == .speakerFinalization
                && $0.state == .running
                && $0.executionToken == executionToken
                && $0.pipelineVersion == pipelineVersion
        }
    }

    @discardableResult
    func finishSpeakerFinalization(
        jobID: UUID,
        recordingID: UUID,
        executionToken: UUID,
        state: RecordingJobState,
        lastError: String? = nil,
        terminationReason: String? = nil,
        at date: Date
    ) throws -> RecordingJob? {
        guard var job = try index.jobs(recordingID: recordingID).first(where: {
            $0.id == jobID
                && $0.kind == .speakerFinalization
                && $0.state == .running
                && $0.executionToken == executionToken
        }) else { return nil }
        job.state = state
        job.lastError = lastError
        job.executionToken = nil
        job.startedAt = nil
        job.terminationReason = terminationReason
        job.updatedAt = date
        try upsertJob(job, at: date)
        return job
    }

    func gaps(recordingID: UUID) throws -> [RecordingGap] {
        try index.gaps(recordingID: recordingID)
    }

    func recoverUnfinished(at date: Date) throws -> RecoveryResult {
        let replayed = try replayJournal()
        let unfinished = try index.recordings(states: [.recording, .paused, .stopping])
        var recovered: [UUID] = []

        for recording in unfinished {
            _ = try? reconcileChunksFromDisk(recordingID: recording.id)
            var stateMachine = RecordingStateMachine(state: recording.state)
            let state = try stateMachine.apply(.recoveredAfterTermination)
            let chunks = (try? index.chunks(recordingID: recording.id))?.sorted { $0.startSample < $1.startSample } ?? []
            let sample = chunks.last?.endSample ?? 0
            let endedAt = chunks.last?.endedAt ?? date
            let gap = RecordingGap(
                id: UUID(),
                recordingID: recording.id,
                reason: .recoveredAfterTermination,
                startSample: sample,
                endSample: nil,
                startedAt: date,
                endedAt: nil
            )
            try changeState(recordingID: recording.id, to: state, endedAt: endedAt, at: date)
            try openGap(gap, at: date)
            for var job in try index.jobs(recordingID: recording.id) where job.state == .running {
                job.state = .pending
                job.lastError = "recoveredAfterTermination"
                job.executionToken = nil
                job.startedAt = nil
                job.terminationReason = "recoveredAfterTermination"
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
            let recordingJobs = try index.jobs(recordingID: recording.id)
            for job in recordingJobs
            where job.kind == .speakerFinalization && job.state == .running {
                var pending = job
                pending.state = .pending
                pending.lastError = "recoveredAfterTermination"
                pending.executionToken = nil
                pending.startedAt = nil
                pending.terminationReason = "recoveredAfterTermination"
                pending.updatedAt = date
                try upsertJob(pending, at: date)
            }

            let transcriptionJobs = recordingJobs
                .filter { $0.kind == .transcription }
            guard !transcriptionJobs.isEmpty else {
                // Files imports restore one durable job per ProcessingRange.
                // Microphone captures restore one job per closed AudioChunk.
                // Never create a legacy whole-recording job here.
                if recording.origin == .importedAudio {
                    let ranges = try index.processingRanges(recordingID: recording.id)
                        .sorted { $0.sequence < $1.sequence }
                    for range in ranges where range.state != .completed {
                        try upsertJob(RecordingJob(
                            id: UUID(),
                            recordingID: recording.id,
                            processingRangeID: range.id,
                            kind: .transcription,
                            state: .pending,
                            attemptCount: 0,
                            lastError: nil,
                            createdAt: date,
                            updatedAt: date
                        ), at: date)
                    }
                } else {
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
                }
                continue
            }

            for job in transcriptionJobs where job.state == .running {
                var pending = job
                pending.state = .pending
                pending.lastError = "recoveredAfterTermination"
                pending.executionToken = nil
                pending.startedAt = nil
                pending.terminationReason = "recoveredAfterTermination"
                pending.updatedAt = date
                try upsertJob(pending, at: date)
            }

            let recoveredJobs = try index.jobs(recordingID: recording.id)
                .filter { $0.kind == .transcription }
            let recoveredFinalization = try index.jobs(recordingID: recording.id)
                .filter { $0.kind == .speakerFinalization }
            if recoveredJobs.allSatisfy({ $0.state == .completed }),
               !recoveredFinalization.isEmpty,
               recoveredFinalization.allSatisfy({ $0.state == .completed }) {
                try changeState(recordingID: recording.id, to: .complete, at: date)
                try clearContinuationMarkersForCompletedRecording(
                    recordingID: recording.id,
                    at: date
                )
            } else if recoveredJobs.contains(where: { $0.state == .failed }) {
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
        var removedImported: [UUID] = []
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

        // Files imports keep one private asset (source or standardized). Retention
        // matches microphone audio: expired + unpinned Recording removes media only.
        let importedCandidates = try index.importedPurgeCandidates(at: date)
        for candidate in importedCandidates {
            let url = rootURL.appendingPathComponent(candidate.relativePath)
            if fileManager.fileExists(atPath: url.path) {
                let attributes = try fileManager.attributesOfItem(atPath: url.path)
                reclaimedBytes += (attributes[.size] as? NSNumber)?.int64Value ?? 0
                try fileManager.removeItem(at: url)
            }
            // Best-effort: clear empty per-recording import directory.
            let folder = url.deletingLastPathComponent()
            if let remaining = try? fileManager.contentsOfDirectory(atPath: folder.path),
               remaining.isEmpty {
                try? fileManager.removeItem(at: folder)
            }
            try persist(.init(
                occurredAt: date,
                payload: .importedAudioAssetRemoved(assetID: candidate.assetID, removedAt: date)
            ))
            removedImported.append(candidate.assetID)
        }

        return RetentionResult(
            removedChunkIDs: removed,
            removedImportedAssetIDs: removedImported,
            reclaimedBytes: reclaimedBytes
        )
    }

    var schemaVersion: Int {
        index.schemaVersion
    }

    func deleteRecording(id: UUID) throws {
        let chunks = (try? index.chunks(recordingID: id)) ?? []
        if let asset = try? index.importedAudioAsset(recordingID: id) {
            let url = rootURL.appendingPathComponent(asset.relativePath)
            try? fileManager.removeItem(at: url)
        }
        for chunk in chunks {
            let url = rootURL.appendingPathComponent(chunk.relativePath)
            try? fileManager.removeItem(at: url)
        }
        let folderURL = rootURL.appendingPathComponent("Recordings/\(id.uuidString)")
        try? fileManager.removeItem(at: folderURL)
        try index.deleteRecording(id: id)
    }

    var appliedEventCount: Int {
        index.appliedEventCount
    }

    @discardableResult
    func reconcileChunksFromDisk(recordingID: UUID) throws -> [AudioChunk] {
        let candidateFolderNames = [
            recordingID.uuidString.lowercased(),
            recordingID.uuidString.uppercased(),
            recordingID.uuidString
        ]
        var audioDir: URL?
        for folderName in candidateFolderNames {
            let candidate = rootURL.appendingPathComponent("Recordings/\(folderName)/audio")
            if fileManager.fileExists(atPath: candidate.path) {
                audioDir = candidate
                break
            }
        }
        guard let audioDir else { return [] }

        guard let enumerator = fileManager.enumerator(
            at: audioDir,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        struct DiscoveredFile {
            let url: URL
            let relativePath: String
            let chunkID: UUID
            let creationDate: Date
            let frameCount: Int64
            let minuteBaseSample: Int64
        }

        var discovered: [DiscoveredFile] = []
        var rawRoot = rootURL.path
        if rawRoot.hasSuffix("/") { rawRoot.removeLast() }

        while let fileURL = enumerator.nextObject() as? URL {
            guard fileURL.pathExtension.lowercased() == "m4a" else { continue }
            let filename = fileURL.deletingPathExtension().lastPathComponent
            let uuidString = filename.hasPrefix("audio-") ? String(filename.dropFirst(6)) : filename
            guard let chunkID = UUID(uuidString: uuidString) else { continue }

            let fullPath = fileURL.path
            let relPath: String
            if let range = fullPath.range(of: "Recordings/") {
                relPath = String(fullPath[range.lowerBound...])
            } else if fullPath.hasPrefix(rawRoot + "/") {
                relPath = String(fullPath.dropFirst(rawRoot.count + 1))
            } else {
                relPath = "Recordings/\(recordingID.uuidString.lowercased())/audio/\(fileURL.lastPathComponent)"
            }

            var minuteBaseSample: Int64 = 0
            if let range = fullPath.range(of: "/audio/") {
                let afterAudio = fullPath[range.upperBound...]
                let parts = afterAudio.split(separator: "/")
                if parts.count >= 2, let hh = Int64(parts[0]), let mm = Int64(parts[1]) {
                    minuteBaseSample = (hh * 60 + mm) * 60 * 16_000
                }
            }

            let date = (try? fileURL.resourceValues(forKeys: [.creationDateKey]).creationDate)
                ?? (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? Date()

            var frames: Int64 = 0
            if let af = try? AVAudioFile(forReading: fileURL, commonFormat: .pcmFormatFloat32, interleaved: false) {
                frames = Int64(af.length)
            }
            if frames <= 0 {
                let size = (try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
                frames = max(1600, size * 4)
            }

            discovered.append(DiscoveredFile(
                url: fileURL,
                relativePath: relPath,
                chunkID: chunkID,
                creationDate: date,
                frameCount: frames,
                minuteBaseSample: minuteBaseSample
            ))
        }

        guard !discovered.isEmpty else { return [] }
        discovered.sort { lhs, rhs in
            if lhs.minuteBaseSample != rhs.minuteBaseSample {
                return lhs.minuteBaseSample < rhs.minuteBaseSample
            }
            return lhs.relativePath < rhs.relativePath
        }

        let recording = try index.recording(id: recordingID)
        let recordingStartedAt = recording?.startedAt ?? discovered.first?.creationDate ?? Date()

        var currentSampleCursor: Int64 = 0
        var newAddedChunks: [AudioChunk] = []

        for item in discovered {
            let startSample = max(currentSampleCursor, item.minuteBaseSample)
            let endSample = startSample + item.frameCount
            currentSampleCursor = endSample

            let startSec = Double(startSample) / 16_000.0
            let endSec = Double(endSample) / 16_000.0
            let startedAt = recordingStartedAt.addingTimeInterval(startSec)
            let endedAt = recordingStartedAt.addingTimeInterval(endSec)

            let chunkToSave = AudioChunk(
                id: item.chunkID,
                recordingID: recordingID,
                relativePath: item.relativePath,
                startSample: startSample,
                endSample: endSample,
                startedAt: startedAt,
                endedAt: endedAt,
                state: .closed
            )
            try addChunk(chunkToSave, at: endedAt)
            newAddedChunks.append(chunkToSave)
        }

        let allChunks = (try index.chunks(recordingID: recordingID)).sorted { $0.startSample < $1.startSample }
        if let lastChunk = allChunks.last, let recording = try index.recording(id: recordingID), recording.state != .complete {
            try changeState(recordingID: recordingID, to: .processing, endedAt: lastChunk.endedAt, at: Date())
        }

        return newAddedChunks
    }

    @discardableResult
    func reconcileAllRecordingsFromDisk() throws -> [UUID: [AudioChunk]] {
        var results: [UUID: [AudioChunk]] = [:]
        let recordings = try index.recordings()
        for rec in recordings {
            let added = try reconcileChunksFromDisk(recordingID: rec.id)
            if !added.isEmpty {
                results[rec.id] = added
            }
        }
        return results
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
