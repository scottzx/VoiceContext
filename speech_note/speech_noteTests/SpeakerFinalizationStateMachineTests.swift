import Foundation
import Testing
@testable import speech_note

struct SpeakerFinalizationStateMachineTests {
    @Test func personalRecordingCompletesAfterASRWithoutSpeakerJobs() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let transcriptStore = try TranscriptDocumentStore(rootURL: root)
        let reconciler = CompletionReconciler(repository: repository, transcriptStore: transcriptStore)
        let startedAt = Date(timeIntervalSince1970: 1_787_479_000)
        let recording = Recording(
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(20),
            isMeeting: false,
            state: .processing
        )
        try await repository.createRecording(recording, at: startedAt)
        try await repository.upsertJob(RecordingJob(
            recordingID: recording.id,
            kind: .transcription,
            state: .completed,
            attemptCount: 1,
            lastError: nil,
            createdAt: startedAt,
            updatedAt: startedAt
        ), at: startedAt)

        #expect(try await reconciler.reconcile(recordingID: recording.id) == .completed)
        let jobs = try await repository.jobs(recordingID: recording.id)
        #expect(!jobs.contains { $0.kind == .speakerEmbedding || $0.kind == .speakerFinalization })
        #expect(try await repository.recording(id: recording.id)?.state == .complete)
    }

    @Test func durableEmbeddingJobsRepairCommittedAndMissingBatchesPerSource() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let startedAt = Date(timeIntervalSince1970: 1_787_480_000)
        let recording = Recording(
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(120),
            state: .processing
        )
        try await repository.createRecording(recording, at: startedAt)

        var chunks: [AudioChunk] = []
        for index in 0..<2 {
            let startSample = Int64(index) * 960_000
            let endSample = Int64(index + 1) * 960_000
            let chunk = AudioChunk(
                recordingID: recording.id,
                relativePath: "Recordings/embedding-\(index).m4a",
                startSample: startSample,
                endSample: endSample,
                startedAt: startedAt.addingTimeInterval(Double(index * 60)),
                endedAt: startedAt.addingTimeInterval(Double((index + 1) * 60))
            )
            chunks.append(chunk)
        }
        for chunk in chunks {
            try await repository.addChunk(chunk, at: chunk.endedAt)
            try await repository.upsertJob(RecordingJob(
                recordingID: recording.id,
                chunkID: chunk.id,
                kind: .transcription,
                state: .completed,
                attemptCount: 1,
                lastError: nil,
                createdAt: chunk.endedAt,
                updatedAt: chunk.endedAt
            ), at: chunk.endedAt)
        }

        let coordinator = SpeakerFinalizationCoordinator()
        var jobs = try await coordinator.ensureDurableEmbeddingJobs(
            recordingID: recording.id,
            repository: repository
        )
        #expect(jobs.count == 2)
        #expect(jobs.allSatisfy { $0.kind == .speakerEmbedding && $0.state == .pending })

        try SpeakerObservationStore.replaceBatch(
            [],
            rootURL: root,
            recordingID: recording.id,
            batchID: chunks[0].id
        )
        jobs = try await coordinator.ensureDurableEmbeddingJobs(
            recordingID: recording.id,
            repository: repository
        )
        #expect(jobs.first(where: { $0.chunkID == chunks[0].id })?.state == .completed)

        var missing = try #require(jobs.first(where: { $0.chunkID == chunks[1].id }))
        missing.state = RecordingJobState.completed
        missing.updatedAt = startedAt.addingTimeInterval(180)
        try await repository.upsertJob(missing, at: missing.updatedAt)
        jobs = try await coordinator.ensureDurableEmbeddingJobs(
            recordingID: recording.id,
            repository: repository
        )
        let repaired = try #require(jobs.first(where: { $0.chunkID == chunks[1].id }))
        #expect(repaired.state == RecordingJobState.pending)
        #expect(repaired.lastError == "missingSpeakerObservationBatch")
    }

    @Test func coldStartReconcilerQueuesCompletedV4FinalizerForV5Upgrade() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let transcriptStore = try TranscriptDocumentStore(rootURL: root)
        let reconciler = CompletionReconciler(
            repository: repository,
            transcriptStore: transcriptStore
        )
        let startedAt = Date(timeIntervalSince1970: 1_787_489_000)
        let recording = Recording(
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(30),
            isMeeting: true,
            state: .complete
        )
        try await repository.createRecording(recording, at: startedAt)
        try await repository.upsertJob(RecordingJob(
            recordingID: recording.id,
            kind: .transcription,
            state: .completed,
            attemptCount: 1,
            lastError: nil,
            pipelineVersion: 2,
            createdAt: startedAt,
            updatedAt: startedAt
        ), at: startedAt)
        let finalizationID = UUID()
        try await repository.upsertJob(RecordingJob(
            id: finalizationID,
            recordingID: recording.id,
            kind: .speakerFinalization,
            state: .completed,
            attemptCount: 1,
            lastError: nil,
            pipelineVersion: 4,
            createdAt: startedAt,
            updatedAt: startedAt
        ), at: startedAt)
        let transcript = TranscriptDocumentV1(
            recording: recording,
            chunks: [],
            segmentDrafts: [],
            language: "zh",
            state: .complete,
            speakers: []
        )
        try await transcriptStore.write(transcript)

        let result = try await reconciler.reconcile(
            recordingID: recording.id,
            at: startedAt.addingTimeInterval(60)
        )

        #expect(result == .needsSpeakerFinalization(jobID: finalizationID))
        #expect(try await repository.recording(id: recording.id)?.state == .processing)
        #expect(try await transcriptStore.document(recordingID: recording.id)?.state == "complete")

        let upgraded = try await SpeakerFinalizationCoordinator().ensureDurableJob(
            recordingID: recording.id,
            repository: repository
        )
        #expect(upgraded.id == finalizationID)
        #expect(upgraded.state == .pending)
        #expect(upgraded.pipelineVersion == SpeakerFinalizationJob.currentPipelineVersion)
    }

    @Test func v3FinalizerUpgradeInvalidatesLeaseAndPreservesTranscript() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let transcriptStore = try TranscriptDocumentStore(rootURL: root)
        let startedAt = Date(timeIntervalSince1970: 1_787_490_000)
        let recording = Recording(
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(30),
            isMeeting: true,
            state: .processing
        )
        let chunk = AudioChunk(
            recordingID: recording.id,
            relativePath: "Recordings/v3-upgrade/audio.m4a",
            startSample: 0,
            endSample: 480_000,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(30)
        )
        try await repository.createRecording(recording, at: startedAt)
        let staleToken = UUID()
        let finalizationID = UUID()
        try await repository.upsertJob(RecordingJob(
            id: finalizationID,
            recordingID: recording.id,
            kind: .speakerFinalization,
            state: .running,
            attemptCount: 1,
            lastError: nil,
            pipelineVersion: 3,
            executionToken: staleToken,
            startedAt: startedAt,
            createdAt: startedAt,
            updatedAt: startedAt
        ), at: startedAt)
        let transcript = TranscriptDocumentV1(
            recording: recording,
            chunks: [chunk],
            segmentDrafts: [.init(text: "已完成的逐字稿", chunk: chunk)],
            language: "zh",
            state: .processing,
            speakers: []
        )
        try await transcriptStore.write(transcript)
        SpeakerObservationStore.save(
            [OfflineSpeakerObservation(
                startSample: 0,
                endSample: 32_000,
                embedding: .embedding([1, 0]),
                exclusionReasons: [],
                onlineTemporaryLabel: "legacy"
            )],
            rootURL: root,
            recordingID: recording.id
        )
        let oldMetricsURL = TranscriptionStageMetricsStore.speakerFinalizationURL(
            rootURL: root,
            job: SpeakerFinalizationJob(recordingID: recording.id, pipelineVersion: 3)
        )
        try FileManager.default.createDirectory(
            at: oldMetricsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("legacy".utf8).write(to: oldMetricsURL)

        let upgraded = try await SpeakerFinalizationCoordinator().ensureDurableJob(
            recordingID: recording.id,
            repository: repository
        )

        #expect(upgraded.id == finalizationID)
        #expect(upgraded.state == .pending)
        #expect(upgraded.pipelineVersion == SpeakerFinalizationJob.currentPipelineVersion)
        #expect(upgraded.executionToken == nil)
        #expect(upgraded.terminationReason == "upgradedSpeakerPipeline")
        #expect(try await repository.validateSpeakerFinalization(
            jobID: finalizationID,
            recordingID: recording.id,
            executionToken: staleToken,
            pipelineVersion: 3
        ) == false)
        #expect(SpeakerObservationStore.load(
            rootURL: root,
            recordingID: recording.id
        ).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: oldMetricsURL.path))
        #expect(try await transcriptStore.document(recordingID: recording.id)?
            .segments.map(\.text) == ["已完成的逐字稿"])
    }

    @Test func globalSpeakerRecoveryInvalidatesEveryCrashLeftFinalizerLease() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let startedAt = Date(timeIntervalSince1970: 1_787_500_000)
        var expectedRecordingIDs: Set<UUID> = []
        for offset in 0..<3 {
            let recording = Recording(
                startedAt: startedAt.addingTimeInterval(Double(offset)),
                endedAt: startedAt.addingTimeInterval(60 + Double(offset)),
                state: .processing
            )
            expectedRecordingIDs.insert(recording.id)
            try await repository.createRecording(recording, at: recording.startedAt)
            try await repository.upsertJob(RecordingJob(
                recordingID: recording.id,
                kind: .speakerFinalization,
                state: .running,
                attemptCount: 1,
                lastError: nil,
                executionToken: UUID(),
                startedAt: recording.startedAt,
                createdAt: recording.startedAt,
                updatedAt: recording.startedAt
            ), at: recording.startedAt)
        }

        let recovered = try await repository.recoverRunningSpeakerFinalizations(
            at: startedAt.addingTimeInterval(120)
        )

        #expect(Set(recovered) == expectedRecordingIDs)
        for recordingID in expectedRecordingIDs {
            let job = try #require(try await repository.jobs(recordingID: recordingID).first)
            #expect(job.state == .pending)
            #expect(job.executionToken == nil)
            #expect(job.startedAt == nil)
            #expect(job.lastError == "recoveredAfterTermination")
        }
    }

    @Test func recoveredDeviceSnapshotRejectsStaleTokenAndAcceptsReplacementAttempt() async throws {
        let snapshot = try deviceSnapshot()
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let startedAt = Date(timeIntervalSince1970: 1_787_510_000)
        let recording = Recording(
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(3_108),
            state: .processing
        )
        try await repository.createRecording(recording, at: startedAt)
        for index in 0..<snapshot.transcriptionJobCount {
            let date = startedAt.addingTimeInterval(Double(index))
            try await repository.upsertJob(RecordingJob(
                recordingID: recording.id,
                chunkID: UUID(),
                kind: .transcription,
                state: .completed,
                attemptCount: 1,
                lastError: nil,
                createdAt: date,
                updatedAt: date
            ), at: date)
        }
        let staleToken = UUID()
        let finalizationID = UUID()
        let staleDate = startedAt.addingTimeInterval(-8_000)
        try await repository.upsertJob(RecordingJob(
            id: finalizationID,
            recordingID: recording.id,
            kind: .speakerFinalization,
            state: .running,
            attemptCount: snapshot.speakerFinalization.attemptCount,
            lastError: nil,
            executionToken: staleToken,
            startedAt: staleDate,
            createdAt: staleDate,
            updatedAt: staleDate
        ), at: staleDate)

        let recoveredAt = startedAt.addingTimeInterval(60)
        _ = try await repository.recoverUnfinished(at: recoveredAt)
        #expect(try await repository.validateSpeakerFinalization(
            jobID: finalizationID,
            recordingID: recording.id,
            executionToken: staleToken,
            pipelineVersion: SpeakerFinalizationJob.currentPipelineVersion
        ) == false)
        #expect(try await repository.finishSpeakerFinalization(
            jobID: finalizationID,
            recordingID: recording.id,
            executionToken: staleToken,
            state: .completed,
            at: recoveredAt.addingTimeInterval(1)
        ) == nil)

        let replacement = try #require(try await repository.claimSpeakerFinalization(
            jobID: finalizationID,
            recordingID: recording.id,
            pipelineVersion: SpeakerFinalizationJob.currentPipelineVersion,
            at: recoveredAt.addingTimeInterval(2)
        ))
        let replacementToken = try #require(replacement.executionToken)
        #expect(replacementToken != staleToken)
        #expect(replacement.attemptCount == snapshot.speakerFinalization.attemptCount + 1)
        #expect(try await repository.finishSpeakerFinalization(
            jobID: finalizationID,
            recordingID: recording.id,
            executionToken: replacementToken,
            state: .completed,
            at: recoveredAt.addingTimeInterval(3)
        )?.state == .completed)
    }

    @Test func failedFinalizerCanRetryWithoutRollingBackDurableASRText() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let transcriptStore = try TranscriptDocumentStore(rootURL: root)
        let reconciler = CompletionReconciler(
            repository: repository,
            transcriptStore: transcriptStore
        )
        let startedAt = Date(timeIntervalSince1970: 1_787_520_000)
        let recording = Recording(
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(30),
            isMeeting: true,
            state: .processing
        )
        let chunk = AudioChunk(
            recordingID: recording.id,
            relativePath: "Recordings/finalizer-retry/audio.m4a",
            startSample: 0,
            endSample: 480_000,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(30)
        )
        try await repository.createRecording(recording, at: startedAt)
        try await repository.upsertJob(RecordingJob(
            recordingID: recording.id,
            chunkID: chunk.id,
            kind: .transcription,
            state: .completed,
            attemptCount: 1,
            lastError: nil,
            createdAt: startedAt,
            updatedAt: startedAt.addingTimeInterval(10)
        ), at: startedAt.addingTimeInterval(10))
        let finalizationID = UUID()
        try await repository.upsertJob(RecordingJob(
            id: finalizationID,
            recordingID: recording.id,
            kind: .speakerFinalization,
            state: .pending,
            attemptCount: 0,
            lastError: nil,
            createdAt: startedAt,
            updatedAt: startedAt.addingTimeInterval(10)
        ), at: startedAt.addingTimeInterval(10))
        let transcript = TranscriptDocumentV1(
            recording: recording,
            chunks: [chunk],
            segmentDrafts: [
                .init(text: "ASR 文字必须保留", chunk: chunk),
            ],
            language: "zh",
            state: .processing,
            speakers: []
        )
        try await transcriptStore.write(transcript)

        let failedAttempt = try #require(try await repository.claimSpeakerFinalization(
            jobID: finalizationID,
            recordingID: recording.id,
            pipelineVersion: SpeakerFinalizationJob.currentPipelineVersion,
            at: startedAt.addingTimeInterval(11)
        ))
        let failedToken = try #require(failedAttempt.executionToken)
        _ = try #require(try await repository.finishSpeakerFinalization(
            jobID: finalizationID,
            recordingID: recording.id,
            executionToken: failedToken,
            state: .failed,
            lastError: "speaker model failed",
            terminationReason: "finalizerFailed",
            at: startedAt.addingTimeInterval(12)
        ))

        #expect(try await reconciler.reconcile(
            recordingID: recording.id,
            at: startedAt.addingTimeInterval(13)
        ) == .needsAttention)
        #expect(try await transcriptStore.document(recordingID: recording.id)?
            .segments.map(\.text) == ["ASR 文字必须保留"])

        let pending = try #require(try await repository.resetSpeakerFinalizationForRetranscription(
            recordingID: recording.id,
            at: startedAt.addingTimeInterval(14)
        ))
        #expect(pending.id == finalizationID)
        #expect(pending.state == .pending)
        #expect(pending.executionToken == nil)
        guard case let .needsSpeakerFinalization(jobID) = try await reconciler.reconcile(
            recordingID: recording.id,
            at: startedAt.addingTimeInterval(15)
        ) else {
            Issue.record("expected retryable speaker finalization")
            return
        }
        #expect(jobID == finalizationID)

        let retry = try #require(try await repository.claimSpeakerFinalization(
            jobID: finalizationID,
            recordingID: recording.id,
            pipelineVersion: SpeakerFinalizationJob.currentPipelineVersion,
            at: startedAt.addingTimeInterval(16)
        ))
        let retryToken = try #require(retry.executionToken)
        #expect(retry.attemptCount == 2)
        #expect(try await repository.finishSpeakerFinalization(
            jobID: finalizationID,
            recordingID: recording.id,
            executionToken: failedToken,
            state: .completed,
            at: startedAt.addingTimeInterval(17)
        ) == nil)
        _ = try #require(try await repository.finishSpeakerFinalization(
            jobID: finalizationID,
            recordingID: recording.id,
            executionToken: retryToken,
            state: .completed,
            at: startedAt.addingTimeInterval(18)
        ))
        #expect(try await reconciler.reconcile(
            recordingID: recording.id,
            at: startedAt.addingTimeInterval(19)
        ) == .completed)
        let completedTranscript = try #require(try await transcriptStore.document(
            recordingID: recording.id
        ))
        #expect(completedTranscript.state == RecordingState.complete.rawValue)
        #expect(completedTranscript.segments.map(\.text) == ["ASR 文字必须保留"])
    }

    @Test func retranscriptionResetReturnsAllSpeakerJobsToPending() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let now = Date(timeIntervalSince1970: 1_787_521_000)
        let recording = Recording(
            startedAt: now,
            endedAt: now.addingTimeInterval(30),
            isMeeting: true,
            state: .complete
        )
        try await repository.createRecording(recording, at: now)
        for _ in 0..<2 {
            try await repository.upsertJob(RecordingJob(
                recordingID: recording.id,
                chunkID: UUID(),
                kind: .transcription,
                state: .completed,
                attemptCount: 1,
                lastError: nil,
                createdAt: now,
                updatedAt: now
            ), at: now)
        }
        for kind in [RecordingJobKind.speakerEmbedding, .speakerFinalization] {
            try await repository.upsertJob(RecordingJob(
                recordingID: recording.id,
                chunkID: kind == .speakerEmbedding ? UUID() : nil,
                kind: kind,
                state: .completed,
                attemptCount: 1,
                lastError: nil,
                pipelineVersion: kind == .speakerEmbedding
                    ? SpeakerEmbeddingJob.currentPipelineVersion
                    : SpeakerFinalizationJob.currentPipelineVersion,
                createdAt: now,
                updatedAt: now
            ), at: now)
        }

        _ = try await repository.resetSpeakerFinalizationForRetranscription(
            recordingID: recording.id,
            at: now.addingTimeInterval(1)
        )
        try await repository.resetTranscriptionForRetranscription(
            recordingID: recording.id,
            at: now.addingTimeInterval(1)
        )

        let jobs = try await repository.jobs(recordingID: recording.id)
        #expect(jobs.filter { $0.kind == .transcription }.allSatisfy { $0.state == .pending })
        #expect(jobs.first { $0.kind == .speakerEmbedding }?.state == .pending)
        #expect(jobs.first { $0.kind == .speakerFinalization }?.state == .pending)

        let chunk = AudioChunk(
            recordingID: recording.id,
            relativePath: "Recordings/retry.m4a",
            startSample: 0,
            endSample: 16_000,
            startedAt: now,
            endedAt: now.addingTimeInterval(1)
        )
        let document = TranscriptDocumentV1(
            recording: recording,
            chunks: [chunk],
            segmentDrafts: [.init(text: "旧逐字稿", chunk: chunk)],
            language: "zh",
            state: .complete,
            speakers: ["说话人 1"]
        ).preparingForRetranscription(clearSegments: true)
        #expect(document.segments.isEmpty)
        #expect(document.speakers.isEmpty)
        #expect(document.speakerTurns.isEmpty)
        #expect(document.state == RecordingState.processing.rawValue)
    }

    private struct DeviceSnapshot: Decodable {
        struct Finalization: Decodable {
            let attemptCount: Int

            enum CodingKeys: String, CodingKey {
                case attemptCount = "attempt_count"
            }
        }

        let transcriptionJobCount: Int
        let speakerFinalization: Finalization

        enum CodingKeys: String, CodingKey {
            case transcriptionJobCount = "transcription_job_count"
            case speakerFinalization = "speaker_finalization"
        }
    }

    private func deviceSnapshot() throws -> DeviceSnapshot {
        let url = try #require(Bundle(for: SpeechNoteTestsBundleToken.self).url(
            forResource: "stale_speaker_finalization_device_snapshot",
            withExtension: "json"
        ))
        return try JSONDecoder().decode(DeviceSnapshot.self, from: Data(contentsOf: url))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("speaker-finalization-state-\(UUID().uuidString)", isDirectory: true)
    }
}
