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
        let transcription = jobs.filter { $0.kind == .transcription }
        guard !transcription.isEmpty else { return .unchanged }

        if transcription.contains(where: { $0.state == .failed }) {
            return .needsAttention
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

        let finalization = jobs.filter { $0.kind == .speakerFinalization }
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

        if recording.state != .complete {
            try await repository.changeState(
                recordingID: recordingID,
                to: .complete,
                endedAt: recording.endedAt,
                at: date
            )
        }
        if let document = try await transcriptStore.document(recordingID: recordingID) {
            if document.state != RecordingState.complete.rawValue {
                try await transcriptStore.write(document.updatingState(.complete))
            }
        } else {
            let chunks = try await repository.chunks(recordingID: recordingID)
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
            recordingID: recordingID,
            at: date
        )
        return .completed
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
