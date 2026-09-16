import Foundation

/// Derives user-visible completion from durable jobs rather than depending on
/// an in-memory outcome callback surviving until the final write.
actor CompletionReconciler {
    nonisolated enum Result: Equatable, Sendable {
        case unchanged
        case needsSpeakerFinalization(jobID: UUID)
        case needsAttention
        case completed
    }

    private let repository: RecordingRepository
    private let transcriptStore: TranscriptDocumentStore

    init(repository: RecordingRepository, transcriptStore: TranscriptDocumentStore) {
        self.repository = repository
        self.transcriptStore = transcriptStore
    }

    @discardableResult
    func reconcile(recordingID: UUID, at date: Date = Date()) async throws -> Result {
        guard let recording = try await repository.recording(id: recordingID),
              recording.endedAt != nil else { return .unchanged }
        let jobs = try await repository.jobs(recordingID: recordingID)
        let healed = try await completeUnreadableFailedJobs(
            recordingID: recordingID,
            jobs: jobs,
            at: date
        )
        let transcription = healed.filter { $0.kind == .transcription }
        guard !transcription.isEmpty else { return .unchanged }

        if transcription.contains(where: { $0.state == .failed }) {
            return .needsAttention
        }
        if transcription.contains(where: { $0.state == .cancelled }) {
            return .unchanged
        }
        guard transcription.allSatisfy({ $0.state == .completed }) else {
            if recording.state == .complete {
                try await repository.changeState(
                    recordingID: recordingID,
                    to: .processing,
                    endedAt: recording.endedAt,
                    at: date
                )
            }
            return .unchanged
        }

        if !recording.speakerProcessingEnabled {
            try await completeRecording(recording, at: date)
            return .completed
        }

        let finalization = healed.filter { $0.kind == .speakerFinalization }
        if finalization.isEmpty {
            if recording.state == .complete {
                try await repository.changeState(
                    recordingID: recordingID,
                    to: .processing,
                    endedAt: recording.endedAt,
                    at: date
                )
            }
            let job = RecordingJob(
                recordingID: recordingID,
                kind: .speakerFinalization,
                state: .pending,
                attemptCount: 0,
                lastError: nil,
                createdAt: date,
                updatedAt: date
            )
            try await repository.upsertJob(job, at: date)
            return .needsSpeakerFinalization(jobID: job.id)
        }
        if finalization.contains(where: { $0.state == .cancelled }) {
            return .unchanged
        }
        if let outdated = finalization.first(where: {
            $0.pipelineVersion < SpeakerFinalizationJob.currentPipelineVersion
        }) {
            if recording.state == .complete {
                try await repository.changeState(
                    recordingID: recordingID,
                    to: .processing,
                    endedAt: recording.endedAt,
                    at: date
                )
            }
            return .needsSpeakerFinalization(jobID: outdated.id)
        }
        if finalization.contains(where: { $0.state == .failed }) {
            return .needsAttention
        }
        guard finalization.allSatisfy({ $0.state == .completed }) else {
            if recording.state == .complete {
                try await repository.changeState(
                    recordingID: recordingID,
                    to: .processing,
                    endedAt: recording.endedAt,
                    at: date
                )
            }
            return .needsSpeakerFinalization(jobID: finalization[0].id)
        }

        try await completeRecording(recording, at: date)
        return .completed
    }

    /// Interrupted capture can leave AAC files without a moov atom. Those jobs
    /// must not keep the Recording in `processing` forever.
    private func completeUnreadableFailedJobs(
        recordingID: UUID,
        jobs: [RecordingJob],
        at date: Date
    ) async throws -> [RecordingJob] {
        let failed = jobs.filter { $0.kind == .transcription && $0.state == .failed }
        guard !failed.isEmpty else { return jobs }
        let chunks = Dictionary(
            uniqueKeysWithValues: (try await repository.chunks(recordingID: recordingID)).map { ($0.id, $0) }
        )
        var healed = jobs
        for job in failed {
            guard let chunkID = job.chunkID, let chunk = chunks[chunkID] else { continue }
            let url = repository.rootURL.appendingPathComponent(chunk.relativePath)
            guard !PCM16KMonoLoader.isReadable(url) else { continue }
            var updated = job
            updated.state = .completed
            updated.lastError = "unreadableAudioSkipped"
            updated.executionToken = nil
            updated.startedAt = nil
            updated.updatedAt = date
            try await repository.upsertJob(updated, at: date)
            if let index = healed.firstIndex(where: { $0.id == job.id }) {
                healed[index] = updated
            }
        }
        return healed
    }

    private func completeRecording(_ recording: Recording, at date: Date) async throws {
        if recording.state != .complete {
            try await repository.changeState(
                recordingID: recording.id,
                to: .complete,
                endedAt: recording.endedAt,
                at: date
            )
        }
        if let document = try await transcriptStore.document(recordingID: recording.id) {
            if document.state != RecordingState.complete.rawValue {
                try await transcriptStore.write(document.updatingState(.complete))
            }
        } else {
            let chunks = try await repository.chunks(recordingID: recording.id)
            let empty = TranscriptDocumentV1(
                recording: recording,
                chunks: chunks,
                segmentDrafts: [],
                language: "",
                state: .complete,
                speakers: []
            )
            try await transcriptStore.write(empty)
        }
        _ = try await repository.clearContinuationMarkersForCompletedRecording(
            recordingID: recording.id,
            at: date
        )
    }

    /// Cold-start audit also repairs records whose final callback was lost.
    func reconcileAll(at date: Date = Date()) async throws -> [UUID: Result] {
        var results: [UUID: Result] = [:]
        for recording in try await repository.recordings() where recording.endedAt != nil {
            let result = try await reconcile(recordingID: recording.id, at: date)
            if result != .unchanged {
                results[recording.id] = result
            }
        }
        return results
    }
}
