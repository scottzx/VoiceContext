import Foundation
import Testing
@preconcurrency import AVFoundation
@testable import speech_note

struct RecordingCoreTests {
    @Test func domainModelsRoundTripWithoutLosingStateOrSampleBoundaries() throws {
        let startedAt = Date(timeIntervalSince1970: 1_785_913_200.125)
        let recording = Recording(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(12),
            title: "测试录音",
            isMeeting: true,
            state: .processing,
            retention: .init(expiresAt: startedAt.addingTimeInterval(600), isPinned: true),
            updatedAt: startedAt.addingTimeInterval(12),
            memo: "会后确认下一步"
        )
        let chunk = AudioChunk(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            recordingID: recording.id,
            relativePath: "Recordings/recording/audio.m4a",
            startSample: 160,
            endSample: 192_160,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(12)
        )
        let event = RecordingJournalEvent(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
            occurredAt: chunk.endedAt,
            payload: .chunkClosed(chunk)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970

        #expect(try decoder.decode(Recording.self, from: encoder.encode(recording)) == recording)
        #expect(try decoder.decode(RecordingJournalEvent.self, from: encoder.encode(event)) == event)
    }

    @Test func sqliteMigrationCreatesVersionOneSchema() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let index = try RecordingIndex(url: root.appendingPathComponent("index.sqlite"))

        #expect(index.schemaVersion == 10)
        #expect(index.appliedEventCount == 0)
    }

    @Test func recordingMemoPersistsIndependentlyAndBlankContentClearsIt() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let startedAt = Date(timeIntervalSince1970: 1_785_913_200)
        let recording = Recording(startedAt: startedAt, state: .complete)
        try await repository.createRecording(recording, at: startedAt)

        try await repository.setRecordingMemo(
            recordingID: recording.id,
            memo: "🎧 复听后确认甲方的上线日期\n⭐ 关键决策：保持本地处理",
            at: startedAt.addingTimeInterval(1)
        )

        let saved = try #require(await repository.recording(id: recording.id))
        #expect(saved.memo == "🎧 复听后确认甲方的上线日期\n⭐ 关键决策：保持本地处理")
        #expect(saved.title == recording.title)
        #expect(saved.state == .complete)

        let reopened = try RecordingRepository(rootURL: root)
        #expect(try await reopened.recording(id: recording.id)?.memo == saved.memo)

        try await reopened.setRecordingMemo(
            recordingID: recording.id,
            memo: "  \n ",
            at: startedAt.addingTimeInterval(2)
        )
        #expect(try await reopened.recording(id: recording.id)?.memo == nil)
    }

    @Test func flushedJournalReplaysIdempotentlyIntoSQLite() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try RecordingJournal(url: root.appendingPathComponent("events.jsonl"))
        let index = try RecordingIndex(url: root.appendingPathComponent("index.sqlite"))
        let startedAt = Date(timeIntervalSince1970: 1_785_913_200)
        let recording = Recording(startedAt: startedAt)
        let created = RecordingJournalEvent(
            occurredAt: startedAt,
            payload: .recordingCreated(recording)
        )
        let chunk = AudioChunk(
            recordingID: recording.id,
            relativePath: "Recordings/\(recording.id)/audio.m4a",
            startSample: 0,
            endSample: 16_000,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(1)
        )
        let closed = RecordingJournalEvent(
            occurredAt: chunk.endedAt,
            payload: .chunkClosed(chunk)
        )
        try journal.append(created)
        try journal.append(closed)

        for event in try journal.events() {
            _ = try index.apply(event)
        }
        for event in try journal.events() {
            _ = try index.apply(event)
        }

        #expect(index.appliedEventCount == 2)
        #expect(try index.recording(id: recording.id) == recording)
        #expect(try index.chunks(recordingID: recording.id) == [chunk])
    }

    @Test func repeatedRecoveryDoesNotDuplicateRecordingOrGap() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let startedAt = Date(timeIntervalSince1970: 1_785_913_200)
        let recording = Recording(startedAt: startedAt)
        try await repository.createRecording(recording, at: startedAt)
        let job = RecordingJob(
            id: UUID(),
            recordingID: recording.id,
            kind: .transcription,
            state: .running,
            attemptCount: 1,
            lastError: nil,
            createdAt: startedAt,
            updatedAt: startedAt
        )
        try await repository.upsertJob(job, at: startedAt)

        let first = try await repository.recoverUnfinished(at: startedAt.addingTimeInterval(30))
        let eventCountAfterFirstRecovery = await repository.appliedEventCount
        let second = try await repository.recoverUnfinished(at: startedAt.addingTimeInterval(60))

        #expect(first.interruptedRecordingIDs == [recording.id])
        #expect(second.interruptedRecordingIDs.isEmpty)
        #expect(await repository.appliedEventCount == eventCountAfterFirstRecovery)
        #expect(try await repository.recording(id: recording.id)?.state == .interrupted)
        #expect(try await repository.gaps(recordingID: recording.id).count == 1)
        let recoveredJobs = try await repository.jobs(recordingID: recording.id)
        #expect(recoveredJobs.count == 1)
        #expect(recoveredJobs[0].state == .pending)
        #expect(recoveredJobs[0].lastError == "recoveredAfterTermination")
    }

    @Test func recoveryRestoresMissingTranscriptionJobForStoppedProcessingRecording() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let startedAt = Date(timeIntervalSince1970: 1_785_913_200)
        let processing = Recording(
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(13),
            state: .processing
        )
        try await repository.createRecording(processing, at: startedAt)
        try await repository.changeState(
            recordingID: processing.id,
            to: .processing,
            endedAt: processing.endedAt,
            at: processing.endedAt!
        )
        let chunk = AudioChunk(
            recordingID: processing.id,
            relativePath: "Recordings/\(processing.id.uuidString)/audio.m4a",
            startSample: 0,
            endSample: 208_000,
            startedAt: startedAt,
            endedAt: processing.endedAt!
        )
        try await repository.addChunk(chunk, at: chunk.endedAt)

        _ = try await repository.recoverUnfinished(at: startedAt.addingTimeInterval(20))

        // The minute-level queue restores one job per closed chunk, not a
        // legacy whole-recording job with a nil chunkID.
        let job = try #require(await repository.jobs(recordingID: processing.id).first)
        #expect(job.kind == .transcription)
        #expect(job.chunkID == chunk.id)
        #expect(job.state == .pending)
        #expect(job.attemptCount == 0)
    }

    @Test func schedulerNeverCreatesLegacyWholeRecordingJobForNilChunkID() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let recording = Recording(startedAt: .distantPast, state: .processing)
        try await repository.createRecording(recording, at: recording.startedAt)
        let scheduler = ForegroundTranscriptionScheduler(repository: repository) { _ in }

        // Both enqueue and retry with a nil chunkID must not fabricate a
        // whole-recording job: the minute-level queue owns transcription.
        try await scheduler.enqueue(recordingID: recording.id) { _ in }
        try await scheduler.retry(recordingID: recording.id) { _ in }
        await scheduler.waitForIdle()

        #expect(try await repository.jobs(recordingID: recording.id).isEmpty)
    }

    @Test func schedulerDeduplicatesChunkScopedJobsAndDoesNotRetryCompletedOnes() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let recording = Recording(startedAt: .distantPast, state: .processing)
        try await repository.createRecording(recording, at: recording.startedAt)
        let chunkID = UUID()
        let executor = SchedulerExecutorProbe()
        let scheduler = ForegroundTranscriptionScheduler(repository: repository) { lease in
            await executor.record(lease.recordingID)
        }

        try await scheduler.enqueue(recordingID: recording.id, chunkID: chunkID) { _ in }
        try await scheduler.enqueue(recordingID: recording.id, chunkID: chunkID) { _ in }
        await scheduler.waitForIdle()

        let jobs = try await repository.jobs(recordingID: recording.id)
        #expect(jobs.count == 1)
        #expect(jobs[0].chunkID == chunkID)
        #expect(jobs[0].state == .completed)
        #expect(jobs[0].attemptCount == 1)
        #expect(await executor.recordingIDs == [recording.id])
    }

    @Test func completedRecordingClearsStaleContinuationMarkers() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let startedAt = Date(timeIntervalSince1970: 1_785_913_200)
        let recording = Recording(
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(120),
            state: .complete
        )
        try await repository.createRecording(recording, at: startedAt)
        let first = AudioChunk(
            recordingID: recording.id,
            relativePath: "Recordings/first.m4a",
            startSample: 0,
            endSample: 960_000,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60),
            requiresContinuation: true
        )
        let second = AudioChunk(
            recordingID: recording.id,
            relativePath: "Recordings/second.m4a",
            startSample: 960_000,
            endSample: 1_920_000,
            startedAt: startedAt.addingTimeInterval(60),
            endedAt: recording.endedAt!,
            requiresContinuation: true
        )
        try await repository.addChunk(first, at: first.endedAt)
        try await repository.addChunk(second, at: second.endedAt)

        let cleared = try await repository.clearContinuationMarkersForCompletedRecording(
            recordingID: recording.id,
            at: recording.endedAt!
        )

        #expect(Set(cleared) == [first.id, second.id])
        #expect(try await repository.chunks(recordingID: recording.id)
            .allSatisfy { !$0.requiresContinuation })
        // A second pass is idempotent and writes nothing new.
        let replayCleared = try await repository.clearContinuationMarkersForCompletedRecording(
            recordingID: recording.id,
            at: recording.endedAt!.addingTimeInterval(1)
        )
        #expect(replayCleared.isEmpty)
    }

    @Test func inProgressEndedRecordingKeepsMarkersForPendingSuccessorWork() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let startedAt = Date(timeIntervalSince1970: 1_785_913_200)
        let recording = Recording(
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(120),
            state: .processing
        )
        try await repository.createRecording(recording, at: startedAt)
        let first = AudioChunk(
            recordingID: recording.id,
            relativePath: "Recordings/first.m4a",
            startSample: 0,
            endSample: 960_000,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60),
            requiresContinuation: true
        )
        try await repository.addChunk(first, at: first.endedAt)

        let cleared = try await repository.clearContinuationMarkersForCompletedRecording(
            recordingID: recording.id,
            at: recording.endedAt!
        )

        // The Recording is only ended, not complete: the marker still tells
        // the next chunk's job to include this tail.
        #expect(cleared.isEmpty)
        #expect(try await repository.chunks(recordingID: recording.id).first?.requiresContinuation == true)
    }

    @Test func foregroundSchedulerCompletesShortRecordingAndPersistsItsJob() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let recording = Recording(startedAt: .distantPast, state: .processing)
        try await repository.createRecording(recording, at: recording.startedAt)
        let chunkID = UUID()
        let executor = SchedulerExecutorProbe()
        let outcomes = SchedulerOutcomeProbe()
        let scheduler = ForegroundTranscriptionScheduler(repository: repository) { lease in
            await executor.record(lease.recordingID)
        }

        try await scheduler.enqueue(recordingID: recording.id, chunkID: chunkID) { outcome in
            await outcomes.record(outcome)
        }
        await scheduler.waitForIdle()

        #expect(await executor.recordingIDs == [recording.id])
        let jobs = try await repository.jobs(recordingID: recording.id)
        #expect(jobs.count == 1)
        #expect(jobs[0].chunkID == chunkID)
        #expect(jobs[0].state == .completed)
        #expect(jobs[0].attemptCount == 1)
        #expect(await outcomes.values == [.init(recordingID: recording.id, chunkID: chunkID, state: .completed)])
    }

    @Test func schedulerLeavesNoSpeechFailureVisibleAndRetryable() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let recording = Recording(startedAt: .distantPast, state: .processing)
        try await repository.createRecording(recording, at: recording.startedAt)
        let chunkID = UUID()
        let outcomes = SchedulerOutcomeProbe()
        let scheduler = ForegroundTranscriptionScheduler(repository: repository) { _ in
            throw SchedulerTestError.noSpeech
        }

        try await scheduler.enqueue(recordingID: recording.id, chunkID: chunkID) { outcome in
            await outcomes.record(outcome)
        }
        await scheduler.waitForIdle()

        let failedJob = try #require(await repository.jobs(recordingID: recording.id).first)
        #expect(failedJob.state == .failed)
        #expect(failedJob.chunkID == chunkID)
        #expect(failedJob.attemptCount == 1)
        #expect(failedJob.lastError == SchedulerTestError.noSpeech.localizedDescription)
        #expect(await outcomes.values == [.init(
            recordingID: recording.id,
            chunkID: chunkID,
            state: .failed(message: SchedulerTestError.noSpeech.localizedDescription)
        )])

        await scheduler.enteredBackground()
        try await scheduler.retry(recordingID: recording.id) { outcome in
            await outcomes.record(outcome)
        }
        let pendingJob = try #require(await repository.jobs(recordingID: recording.id).first)
        #expect(pendingJob.state == .pending)
        await scheduler.enteredForeground()
        await scheduler.waitForIdle()
        let retriedJob = try #require(await repository.jobs(recordingID: recording.id).first)
        #expect(retriedJob.state == .failed)
        #expect(retriedJob.attemptCount == 2)
    }

    @Test func failedRecordingKeepsTheAudioAndErrorInputsRequiredByItsDetail() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let startedAt = Date(timeIntervalSince1970: 1_785_913_200)
        let recording = Recording(
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(13),
            title: "短录音",
            state: .failed,
            updatedAt: startedAt.addingTimeInterval(13)
        )
        let chunk = AudioChunk(
            recordingID: recording.id,
            relativePath: "Recordings/\(recording.id.uuidString)/audio.m4a",
            startSample: 0,
            endSample: 208_000,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(13)
        )
        let job = RecordingJob(
            id: UUID(),
            recordingID: recording.id,
            kind: .transcription,
            state: .failed,
            attemptCount: 1,
            lastError: SchedulerTestError.noSpeech.localizedDescription,
            createdAt: startedAt,
            updatedAt: startedAt.addingTimeInterval(13)
        )

        try await repository.createRecording(recording, at: startedAt)
        try await repository.addChunk(chunk, at: chunk.endedAt)
        try await repository.upsertJob(job, at: job.updatedAt)

        #expect(try await repository.recording(id: recording.id) == recording)
        #expect(try await repository.chunks(recordingID: recording.id) == [chunk])
        let storedJob = try #require(await repository.jobs(recordingID: recording.id).first)
        #expect(storedJob.state == .failed)
        #expect(storedJob.lastError == SchedulerTestError.noSpeech.localizedDescription)
    }

    @Test func schedulerDefersBackgroundWorkThenResumesCrashLeftJob() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let recording = Recording(startedAt: .distantPast, state: .processing)
        try await repository.createRecording(recording, at: recording.startedAt)
        let createdAt = Date(timeIntervalSince1970: 1_785_913_200)
        let running = RecordingJob(
            id: UUID(),
            recordingID: recording.id,
            kind: .transcription,
            state: .running,
            attemptCount: 1,
            lastError: nil,
            createdAt: createdAt,
            updatedAt: createdAt
        )
        try await repository.upsertJob(running, at: createdAt)
        let executor = SchedulerExecutorProbe()
        let outcomes = SchedulerOutcomeProbe()
        let scheduler = ForegroundTranscriptionScheduler(repository: repository) { lease in
            await executor.record(lease.recordingID)
        }

        await scheduler.enteredBackground()
        try await scheduler.resumePendingJobs { outcome in
            await outcomes.record(outcome)
        }
        #expect(await executor.recordingIDs.isEmpty)
        #expect(try await repository.jobs(recordingID: recording.id)[0].state == .pending)

        await scheduler.enteredForeground()
        await scheduler.waitForIdle()
        let completedJob = try #require(await repository.jobs(recordingID: recording.id).first)
        #expect(completedJob.state == .completed)
        #expect(completedJob.attemptCount == 2)
        #expect(await executor.recordingIDs == [recording.id])
        #expect(await outcomes.values == [.init(recordingID: recording.id, state: .completed)])
    }

    @Test func schedulerAdmissionAdmitsUnderSeriousThermalState() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let recording = Recording(startedAt: .distantPast, state: .processing)
        try await repository.createRecording(recording, at: recording.startedAt)
        let gate = InferenceLifecycleGate()
        let executor = SchedulerExecutorProbe()
        let scheduler = ForegroundTranscriptionScheduler(
            repository: repository,
            lifecycleGate: gate,
            admissionPolicy: TranscriptionAdmissionPolicy(
                thermalState: { .serious },
                isPurchaseLocked: { false }
            )
        ) { lease in
            try await gate.beginMetalWork()
            await executor.record(lease.recordingID)
            await gate.endMetalWork()
        }

        try await scheduler.enqueue(recordingID: recording.id, chunkID: UUID()) { _ in }
        await scheduler.waitForIdle()

        #expect(await executor.recordingIDs == [recording.id])
        #expect(await gate.metrics().submittedMetalWork == 1)
        let job = try #require(await repository.jobs(recordingID: recording.id).first)
        #expect(job.state == .completed)
    }

    @Test func schedulerAdmissionLocksPendingPurchaseWithoutSubmittingMetalWork() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let recording = Recording(startedAt: .distantPast, state: .processing)
        try await repository.createRecording(recording, at: recording.startedAt)
        let gate = InferenceLifecycleGate()
        let executor = SchedulerExecutorProbe()
        let scheduler = ForegroundTranscriptionScheduler(
            repository: repository,
            lifecycleGate: gate,
            admissionPolicy: TranscriptionAdmissionPolicy(
                thermalState: { .nominal },
                isPurchaseLocked: { true }
            )
        ) { lease in
            try await gate.beginMetalWork()
            await executor.record(lease.recordingID)
            await gate.endMetalWork()
        }

        try await scheduler.enqueue(recordingID: recording.id, chunkID: UUID()) { _ in }
        await scheduler.waitForIdle()

        #expect(await executor.recordingIDs.isEmpty)
        #expect(await gate.metrics().submittedMetalWork == 0)
        let job = try #require(await repository.jobs(recordingID: recording.id).first)
        #expect(job.state == .pending)
        #expect(job.lastError == "lockedPendingPurchase")
        #expect(
            RecordingProcessingState.resolve(
                legacyRecordingState: .processing,
                jobs: [job]
            ) == .lockedPendingPurchase
        )
    }

    @Test func duplicateForegroundAndResumePendingJobsDoesNotDoubleRun() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let recording = Recording(startedAt: .distantPast, state: .processing)
        try await repository.createRecording(recording, at: recording.startedAt)
        let createdAt = Date(timeIntervalSince1970: 1_785_913_200)
        let running = RecordingJob(
            id: UUID(),
            recordingID: recording.id,
            chunkID: UUID(),
            kind: .transcription,
            state: .running,
            attemptCount: 1,
            lastError: nil,
            createdAt: createdAt,
            updatedAt: createdAt
        )
        try await repository.upsertJob(running, at: createdAt)
        let executor = SchedulerExecutorProbe()
        let scheduler = ForegroundTranscriptionScheduler(repository: repository) { lease in
            await executor.record(lease.recordingID)
        }

        try await scheduler.resumePendingJobs { _ in }
        try await scheduler.resumePendingJobs { _ in }
        await scheduler.enteredForeground()
        await scheduler.enteredForeground()
        await scheduler.waitForIdle()

        #expect(await executor.recordingIDs == [recording.id])
        let job = try #require(await repository.jobs(recordingID: recording.id).first)
        #expect(job.state == .completed)
        #expect(job.attemptCount == 2)
    }

    @Test @MainActor func processingOutcomeCompletesShortRecordingAndKeepsNoSpeechFailureVisible() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let capture = MockRecordingCapture()
        let coordinator = RecordingSessionCoordinator(
            repository: repository,
            capture: capture,
            lowStorageGuard: LowStorageGuard(minimumAvailableBytes: 1) { _ in 1_000 },
            enablesRemoteStopCommand: false
        )

        let completedID = try await coordinator.start()
        capture.currentSample = 16_000
        try await coordinator.stop()
        try await coordinator.finishProcessing(recordingID: completedID, outcome: .completed)
        #expect(try await repository.recording(id: completedID)?.state == .complete)
        #expect(coordinator.presentationState == .idle)
        #expect(coordinator.activeRecordingID == nil)

        let failedID = try await coordinator.start()
        capture.currentSample = 16_000
        try await coordinator.stop()
        try await coordinator.finishProcessing(
            recordingID: failedID,
            outcome: .failed(message: SchedulerTestError.noSpeech.localizedDescription)
        )
        #expect(try await repository.recording(id: failedID)?.state == .failed)
        #expect(coordinator.presentationState == .failed(SchedulerTestError.noSpeech.localizedDescription))
    }

    @Test @MainActor func failedProcessingReleasesTheCaptureSessionForTheNextRecording() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let capture = MockRecordingCapture()
        let coordinator = RecordingSessionCoordinator(
            repository: repository,
            capture: capture,
            lowStorageGuard: LowStorageGuard(minimumAvailableBytes: 1) { _ in 1_000 },
            enablesRemoteStopCommand: false
        )

        let failedID = try await coordinator.start()
        capture.currentSample = 16_000
        try await coordinator.stop()
        try await coordinator.finishProcessing(
            recordingID: failedID,
            outcome: .failed(message: SchedulerTestError.noSpeech.localizedDescription)
        )

        #expect(coordinator.activeRecordingID == nil)
        let nextID = try await coordinator.start()
        #expect(nextID != failedID)
        #expect(coordinator.presentationState == .recording)
    }

    @Test @MainActor func successfulStopReleasesCaptureIdentityAndImmediatelyAllowsNextRecording() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let capture = MockRecordingCapture()
        let coordinator = RecordingSessionCoordinator(
            repository: repository,
            capture: capture,
            lowStorageGuard: LowStorageGuard(minimumAvailableBytes: 1) { _ in 1_000 },
            enablesRemoteStopCommand: false
        )

        let firstID = try await coordinator.start()
        capture.currentSample = 16_000
        let stoppedID = try await coordinator.stop()

        #expect(stoppedID == firstID)
        #expect(coordinator.activeRecordingID == nil)
        #expect(coordinator.captureState == .idle)
        #expect(capture.stopCount == 1)

        let secondID = try await coordinator.start()

        #expect(secondID != firstID)
        #expect(coordinator.activeRecordingID == secondID)
        #expect(coordinator.captureState == .recording)
        #expect(coordinator.presentationState == .recording)
        #expect(capture.startCount == 2)
    }

    @Test @MainActor func coordinatorCancelImmediatelyStopsCaptureAndResetsState() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let capture = MockRecordingCapture()
        let coordinator = RecordingSessionCoordinator(
            repository: repository,
            capture: capture,
            lowStorageGuard: LowStorageGuard(minimumAvailableBytes: 1) { _ in 1_000 },
            enablesRemoteStopCommand: false
        )

        let firstID = try await coordinator.start()
        #expect(coordinator.activeRecordingID == firstID)
        #expect(coordinator.captureState == .recording)
        #expect(coordinator.presentationState == .recording)

        await coordinator.cancel()

        #expect(coordinator.activeRecordingID == nil)
        #expect(coordinator.captureState == .idle)
        #expect(coordinator.presentationState == .idle)
        #expect(capture.cancelCount == 1)

        let secondID = try await coordinator.start()
        #expect(secondID != firstID)
        #expect(coordinator.activeRecordingID == secondID)
        #expect(coordinator.captureState == .recording)
        #expect(coordinator.presentationState == .recording)
    }

    @Test @MainActor func coordinatorCancelWithMismatchedIDDoesNotCancelActiveSession() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let capture = MockRecordingCapture()
        let coordinator = RecordingSessionCoordinator(
            repository: repository,
            capture: capture,
            lowStorageGuard: LowStorageGuard(minimumAvailableBytes: 1) { _ in 1_000 },
            enablesRemoteStopCommand: false
        )

        let firstID = try await coordinator.start()
        await coordinator.cancel(recordingID: UUID())

        #expect(coordinator.activeRecordingID == firstID)
        #expect(coordinator.captureState == .recording)
        #expect(capture.cancelCount == 0)

        await coordinator.cancel(recordingID: firstID)

        #expect(coordinator.activeRecordingID == nil)
        #expect(coordinator.captureState == .idle)
        #expect(capture.cancelCount == 1)
    }

    @Test @MainActor func modelCancelRecordingCancelsCaptureAndDeletesDraft() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let capture = MockRecordingCapture()
        let coordinator = RecordingSessionCoordinator(
            repository: repository,
            capture: capture,
            lowStorageGuard: LowStorageGuard(minimumAvailableBytes: 1) { _ in 1_000 },
            enablesRemoteStopCommand: false
        )
        let model = try RecordingCoreModel(rootURL: root, coordinator: coordinator)

        let recordingID = try await coordinator.start()
        #expect(model.activeRecordingID == recordingID)
        #expect(model.presentation == .recording)

        await model.cancelRecording()

        #expect(model.activeRecordingID == nil)
        #expect(model.presentation == .idle)
        #expect(capture.cancelCount == 1)
        #expect(try await repository.recording(id: recordingID) == nil)
        #expect(model.notice == "已取消录音。")
    }

    @Test @MainActor func deleteRecordingWhileActiveCancelsTaskFirstAndDeletesSafely() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let capture = MockRecordingCapture()
        let coordinator = RecordingSessionCoordinator(
            repository: repository,
            capture: capture,
            lowStorageGuard: LowStorageGuard(minimumAvailableBytes: 1) { _ in 1_000 },
            enablesRemoteStopCommand: false
        )
        let model = try RecordingCoreModel(rootURL: root, coordinator: coordinator)

        let recordingID = try await coordinator.start()
        #expect(model.activeRecordingID == recordingID)

        await model.deleteRecording(id: recordingID)

        #expect(model.activeRecordingID == nil)
        #expect(model.presentation == .idle)
        #expect(capture.cancelCount == 1)
        #expect(try await repository.recording(id: recordingID) == nil)
        #expect(model.notice == "已删除录音。")

        let nextID = try await coordinator.start()
        #expect(nextID != recordingID)
        #expect(model.activeRecordingID == nextID)
        #expect(model.presentation == .recording)
    }

    @Test @MainActor func deleteOtherRecordingWhileActiveLeavesActiveRecordingIntact() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let capture = MockRecordingCapture()
        let coordinator = RecordingSessionCoordinator(
            repository: repository,
            capture: capture,
            lowStorageGuard: LowStorageGuard(minimumAvailableBytes: 1) { _ in 1_000 },
            enablesRemoteStopCommand: false
        )
        let model = try RecordingCoreModel(rootURL: root, coordinator: coordinator)

        let oldDate = Date(timeIntervalSince1970: 1_785_900_000)
        let oldRecording = Recording(startedAt: oldDate, state: .complete)
        try await repository.createRecording(oldRecording, at: oldDate)

        let activeID = try await coordinator.start()
        #expect(model.activeRecordingID == activeID)
        #expect(model.presentation == .recording)

        await model.deleteRecording(id: oldRecording.id)

        #expect(try await repository.recording(id: oldRecording.id) == nil)
        #expect(model.notice == "已删除录音。")

        #expect(model.activeRecordingID == activeID)
        #expect(model.presentation == .recording)
        #expect(capture.cancelCount == 0)
    }

    @Test @MainActor func batchDeleteRecordingsIncludingActiveCancelsTaskFirst() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let capture = MockRecordingCapture()
        let coordinator = RecordingSessionCoordinator(
            repository: repository,
            capture: capture,
            lowStorageGuard: LowStorageGuard(minimumAvailableBytes: 1) { _ in 1_000 },
            enablesRemoteStopCommand: false
        )
        let model = try RecordingCoreModel(rootURL: root, coordinator: coordinator)

        let oldDate = Date(timeIntervalSince1970: 1_785_900_000)
        let old1 = Recording(startedAt: oldDate, state: .complete)
        let old2 = Recording(startedAt: oldDate.addingTimeInterval(10), state: .complete)
        try await repository.createRecording(old1, at: oldDate)
        try await repository.createRecording(old2, at: oldDate.addingTimeInterval(10))

        let activeID = try await coordinator.start()
        #expect(model.activeRecordingID == activeID)

        await model.deleteRecordings(ids: [old1.id, old2.id, activeID])

        #expect(model.activeRecordingID == nil)
        #expect(model.presentation == .idle)
        #expect(capture.cancelCount == 1)
        #expect(try await repository.recording(id: activeID) == nil)
        #expect(try await repository.recording(id: old1.id) == nil)
        #expect(try await repository.recording(id: old2.id) == nil)
    }

    @Test @MainActor func oldProcessingOutcomesNeverOverwriteNewCaptureState() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let capture = MockRecordingCapture()
        let coordinator = RecordingSessionCoordinator(
            repository: repository,
            capture: capture,
            lowStorageGuard: LowStorageGuard(minimumAvailableBytes: 1) { _ in 1_000 },
            enablesRemoteStopCommand: false
        )

        let completedID = try await coordinator.start()
        capture.currentSample = 16_000
        try await coordinator.stop()

        let failedRecording = Recording(
            startedAt: Date(timeIntervalSince1970: 1_785_913_220),
            endedAt: Date(timeIntervalSince1970: 1_785_913_221),
            state: .processing
        )
        try await repository.createRecording(failedRecording, at: failedRecording.startedAt)

        let activeID = try await coordinator.start()
        let expectedStartCount = capture.startCount

        try await coordinator.finishProcessing(recordingID: completedID, outcome: .completed)
        #expect(try await repository.recording(id: completedID)?.state == .complete)
        #expect(coordinator.activeRecordingID == activeID)
        #expect(coordinator.captureState == .recording)
        #expect(coordinator.presentationState == .recording)

        try await coordinator.finishProcessing(
            recordingID: failedRecording.id,
            outcome: .failed(message: SchedulerTestError.noSpeech.localizedDescription)
        )
        #expect(try await repository.recording(id: failedRecording.id)?.state == .failed)
        #expect(coordinator.activeRecordingID == activeID)
        #expect(coordinator.captureState == .recording)
        #expect(coordinator.presentationState == .recording)
        #expect(capture.startCount == expectedStartCount)
        #expect(capture.stopCount == 1)
    }

    @Test @MainActor func retryingOldFailedRecordingDoesNotBorrowNewMicrophoneSession() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let capture = MockRecordingCapture()
        let coordinator = RecordingSessionCoordinator(
            repository: repository,
            capture: capture,
            lowStorageGuard: LowStorageGuard(minimumAvailableBytes: 1) { _ in 1_000 },
            enablesRemoteStopCommand: false
        )
        let failedRecording = Recording(
            startedAt: Date(timeIntervalSince1970: 1_785_913_200),
            endedAt: Date(timeIntervalSince1970: 1_785_913_201),
            state: .failed
        )
        try await repository.createRecording(failedRecording, at: failedRecording.startedAt)

        let activeID = try await coordinator.start()
        let expectedStartCount = capture.startCount

        try await coordinator.retryProcessing(recordingID: failedRecording.id)

        #expect(try await repository.recording(id: failedRecording.id)?.state == .processing)
        #expect(coordinator.activeRecordingID == activeID)
        #expect(coordinator.captureState == .recording)
        #expect(coordinator.presentationState == .recording)
        #expect(capture.startCount == expectedStartCount)
        #expect(capture.stopCount == 0)
    }

    @Test @MainActor func lifecycleStateCombinesLiveCaptureWithDurableJobsAndRestoresFromPersistence() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let capture = MockRecordingCapture()
        let coordinator = RecordingSessionCoordinator(
            repository: repository,
            capture: capture,
            lowStorageGuard: LowStorageGuard(minimumAvailableBytes: 1) { _ in 1_000 },
            enablesRemoteStopCommand: false
        )
        let activeID = try await coordinator.start()
        let createdAt = Date(timeIntervalSince1970: 1_785_913_200)
        let pending = RecordingJob(
            id: UUID(),
            recordingID: activeID,
            kind: .voiceActivityDetection,
            state: .pending,
            attemptCount: 0,
            lastError: nil,
            createdAt: createdAt,
            updatedAt: createdAt
        )
        try await repository.upsertJob(pending, at: createdAt)

        #expect(try await coordinator.lifecycleState(recordingID: activeID) == .init(
            recordingID: activeID,
            capture: .recording,
            processing: .queued
        ))

        let running = RecordingJob(
            id: UUID(),
            recordingID: activeID,
            kind: .transcription,
            state: .running,
            attemptCount: 1,
            lastError: nil,
            createdAt: createdAt,
            updatedAt: createdAt
        )
        try await repository.upsertJob(running, at: createdAt)

        #expect(try await coordinator.lifecycleState(recordingID: activeID) == .init(
            recordingID: activeID,
            capture: .recording,
            processing: .processing
        ))

        let persistedRecording = Recording(
            startedAt: createdAt.addingTimeInterval(60),
            endedAt: createdAt.addingTimeInterval(90),
            state: .processing
        )
        try await repository.createRecording(persistedRecording, at: persistedRecording.startedAt)
        let deferred = RecordingJob(
            id: UUID(),
            recordingID: persistedRecording.id,
            kind: .transcription,
            state: .pending,
            attemptCount: 0,
            lastError: "deferredUntilForeground",
            createdAt: persistedRecording.startedAt,
            updatedAt: persistedRecording.startedAt
        )
        try await repository.upsertJob(deferred, at: deferred.updatedAt)

        let restartedCoordinator = RecordingSessionCoordinator(
            repository: repository,
            capture: MockRecordingCapture(),
            lowStorageGuard: LowStorageGuard(minimumAvailableBytes: 1) { _ in 1_000 },
            enablesRemoteStopCommand: false
        )

        #expect(try await restartedCoordinator.lifecycleState(recordingID: persistedRecording.id) == .init(
            recordingID: persistedRecording.id,
            capture: .idle,
            processing: .deferredUntilForeground
        ))
    }

    @Test func twoHourSegmentationHasExactContinuousOneMinuteBoundaries() {
        let sampleRate: Int64 = 16_000
        let segmentLength = 60 * sampleRate
        let totalFrames = 2 * 60 * 60 * sampleRate
        var planner = AACChunkBoundaryPlanner(segmentLengthSamples: segmentLength)
        var remaining = totalFrames
        var closedBoundaries: [Int64] = []

        while remaining > 0 {
            let packet = min(341, remaining)
            let slices = planner.slices(for: packet)
            for slice in slices where slice.closesSegment {
                closedBoundaries.append(slice.endSample)
            }
            remaining -= packet
        }

        #expect(planner.currentSample == totalFrames)
        #expect(closedBoundaries.count == 120)
        #expect(closedBoundaries == (1...120).map { Int64($0) * segmentLength })
        #expect(planner.currentSegmentStartSample == totalFrames)
    }

    @Test @MainActor func coordinatorStartsCaptureWithOneMinuteSegments() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let capture = MockRecordingCapture()
        let coordinator = RecordingSessionCoordinator(
            repository: repository,
            capture: capture,
            lowStorageGuard: LowStorageGuard(minimumAvailableBytes: 1) { _ in 1_000 },
            enablesRemoteStopCommand: false
        )

        _ = try await coordinator.start()

        #expect(capture.segmentDurations == [60])
    }

    @Test @MainActor func closedSegmentIsPersistedBeforeCaptureStops() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let capture = MockRecordingCapture()
        let coordinator = RecordingSessionCoordinator(
            repository: repository,
            capture: capture,
            lowStorageGuard: LowStorageGuard(minimumAvailableBytes: 1) { _ in 1_000 },
            enablesRemoteStopCommand: false
        )
        let recordingID = try await coordinator.start()
        let startedAt = Date(timeIntervalSince1970: 1_785_913_200)
        let closedSegment = AACSegmentRecorder.Segment(
            id: UUID(),
            url: root.appendingPathComponent("Recordings/closed-while-recording.m4a"),
            startSample: 0,
            endSample: 960_000,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60)
        )

        capture.emitClosedSegment(closedSegment)

        let deadline = Date().addingTimeInterval(5)
        var storedChunks = try await repository.chunks(recordingID: recordingID)
        while storedChunks.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(1))
            storedChunks = try await repository.chunks(recordingID: recordingID)
        }
        let storedChunk = try #require(storedChunks.first)
        #expect(capture.stopCount == 0)
        #expect(coordinator.presentationState == .recording)
        #expect(storedChunks.count == 1)
        #expect(storedChunk.id == closedSegment.id)
        #expect(storedChunk.relativePath == "Recordings/closed-while-recording.m4a")
        #expect(storedChunk.startSample == closedSegment.startSample)
        #expect(storedChunk.endSample == closedSegment.endSample)
    }

    @Test @MainActor func failedClosedChunkRemainsPendingAndRetriesBeforeLaterChunkInOrder() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let persistence = ChunkPersistenceProbe(repository: repository, failuresRemaining: 1)
        let capture = MockRecordingCapture()
        let coordinator = RecordingSessionCoordinator(
            repository: repository,
            capture: capture,
            lowStorageGuard: LowStorageGuard(minimumAvailableBytes: 1) { _ in 1_000 },
            enablesRemoteStopCommand: false,
            persistChunk: { chunk, date in
                try await persistence.persist(chunk, at: date)
            }
        )
        let recordingID = try await coordinator.start()
        let startedAt = Date(timeIntervalSince1970: 1_785_913_200)
        let first = AACSegmentRecorder.Segment(
            id: UUID(),
            url: root.appendingPathComponent("Recordings/first.m4a"),
            startSample: 0,
            endSample: 960_000,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60)
        )
        let second = AACSegmentRecorder.Segment(
            id: UUID(),
            url: root.appendingPathComponent("Recordings/second.m4a"),
            startSample: first.endSample,
            endSample: first.endSample + 960_000,
            startedAt: first.endedAt,
            endedAt: first.endedAt.addingTimeInterval(60)
        )

        capture.emitClosedSegment(first)

        let failureDeadline = Date().addingTimeInterval(5)
        while coordinator.segmentPersistenceFailureMessage == nil, Date() < failureDeadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(coordinator.segmentPersistenceFailureMessage == ChunkPersistenceProbe.Error.injected.localizedDescription)
        #expect(await persistence.attemptedChunkIDs == [first.id])
        #expect(try await repository.chunks(recordingID: recordingID).isEmpty)

        capture.emitClosedSegment(second)

        let retryDeadline = Date().addingTimeInterval(5)
        var storedChunks = try await repository.chunks(recordingID: recordingID)
        while storedChunks.count < 2, Date() < retryDeadline {
            try await Task.sleep(for: .milliseconds(1))
            storedChunks = try await repository.chunks(recordingID: recordingID)
        }
        #expect(await persistence.attemptedChunkIDs == [first.id, first.id, second.id])
        #expect(storedChunks.map(\.id) == [first.id, second.id])
        #expect(Set(storedChunks.map(\.id)).count == 2)
        #expect(coordinator.segmentPersistenceFailureMessage == nil)
        #expect(coordinator.presentationState == .recording)
    }

    @Test @MainActor func hierarchicalHourMinuteChunkPathIsPersistedAndIndexed() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let capture = MockRecordingCapture()
        let coordinator = RecordingSessionCoordinator(
            repository: repository,
            capture: capture,
            lowStorageGuard: LowStorageGuard(minimumAvailableBytes: 1) { _ in 1_000 },
            enablesRemoteStopCommand: false
        )
        let recordingID = try await coordinator.start()
        let startedAt = Date(timeIntervalSince1970: 1_785_913_200)

        let segmentID = UUID()
        let timeDir = AACChunkBoundaryPlanner.timeDirectory(for: 960_000) // "00/01"
        let chunkRelative = "Recordings/\(recordingID.uuidString.lowercased())/audio/\(timeDir)/audio-\(segmentID.uuidString.lowercased()).m4a"
        let chunkURL = root.appendingPathComponent(chunkRelative)
        try FileManager.default.createDirectory(at: chunkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("audio-payload".utf8).write(to: chunkURL)

        let hierarchicalSegment = AACSegmentRecorder.Segment(
            id: segmentID,
            url: chunkURL,
            startSample: 960_000,
            endSample: 1_120_000,
            startedAt: startedAt.addingTimeInterval(60),
            endedAt: startedAt.addingTimeInterval(70)
        )

        capture.emitClosedSegment(hierarchicalSegment)

        let deadline = Date().addingTimeInterval(5)
        var storedChunks = try await repository.chunks(recordingID: recordingID)
        while storedChunks.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(1))
            storedChunks = try await repository.chunks(recordingID: recordingID)
        }
        let storedChunk = try #require(storedChunks.first)
        #expect(storedChunk.id == segmentID)
        #expect(storedChunk.relativePath == chunkRelative)
        #expect(storedChunk.startSample == 960_000)
        #expect(storedChunk.endSample == 1_120_000)

        // Verify diagnostics recursively scans audio subdirectories without reporting unindexed file
        let diagnostics = RecordingDiagnostics()
        let issues = try await diagnostics.inspect(recordingID: recordingID, repository: repository)
        #expect(issues.isEmpty)
    }

    @Test @MainActor func stoppedCaptureRetriesFailedFlushWithoutStoppingCaptureTwice() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let persistence = ChunkPersistenceProbe(repository: repository, failuresRemaining: 1)
        let capture = MockRecordingCapture()
        capture.emitsSegmentClosedOnStop = false
        let coordinator = RecordingSessionCoordinator(
            repository: repository,
            capture: capture,
            lowStorageGuard: LowStorageGuard(minimumAvailableBytes: 1) { _ in 1_000 },
            enablesRemoteStopCommand: false,
            persistChunk: { chunk, date in
                try await persistence.persist(chunk, at: date)
            }
        )
        let recordingID = try await coordinator.start()
        capture.currentSample = 320_000

        await #expect(throws: ChunkPersistenceProbe.Error.injected) {
            try await coordinator.stop()
        }

        #expect(capture.stopCount == 1)
        #expect(coordinator.presentationState == .stopping)
        #expect(try await repository.recording(id: recordingID)?.state == .stopping)
        #expect(try await repository.chunks(recordingID: recordingID).isEmpty)

        try await coordinator.stop()

        let storedChunk = try #require(await repository.chunks(recordingID: recordingID).first)
        #expect(capture.stopCount == 1)
        #expect(await persistence.attemptedChunkIDs == [storedChunk.id, storedChunk.id])
        #expect(storedChunk.endSample == 320_000)
        #expect(coordinator.presentationState == .idle)
        #expect(coordinator.captureState == .idle)
        #expect(coordinator.activeRecordingID == nil)
        #expect(try await repository.recording(id: recordingID)?.state == .processing)
    }

    @Test @MainActor func pauseAndResumePersistExactUserPauseGap() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let capture = MockRecordingCapture()
        let clock = MutableTestClock(now: Date(timeIntervalSince1970: 1_785_913_200))
        let coordinator = RecordingSessionCoordinator(
            repository: repository,
            capture: capture,
            lowStorageGuard: LowStorageGuard(minimumAvailableBytes: 1) { _ in 1_000 },
            enablesRemoteStopCommand: false,
            now: { clock.now }
        )
        let recordingID = try await coordinator.start()
        capture.currentSample = 32_000
        clock.now = clock.now.addingTimeInterval(2)

        try await coordinator.pause()

        capture.currentSample = 80_000
        clock.now = clock.now.addingTimeInterval(3)
        try await coordinator.resume()

        let gaps = try await repository.gaps(recordingID: recordingID)
        let gap = try #require(gaps.first)
        #expect(gaps.count == 1)
        #expect(gap.reason == .userPause)
        #expect(gap.startSample == 32_000)
        #expect(gap.endSample == 80_000)
        #expect(coordinator.presentationState == .recording)
    }

    @Test func repositoryPreservesHistoricalAndArbitraryChunkSampleRanges() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let startedAt = Date(timeIntervalSince1970: 1_785_913_200)
        let recording = Recording(startedAt: startedAt)
        try await repository.createRecording(recording, at: startedAt)

        let fiveMinuteSampleCount: Int64 = 5 * 60 * 16_000
        let historicalChunk = AudioChunk(
            recordingID: recording.id,
            relativePath: "Recordings/legacy-five-minutes.m4a",
            startSample: 0,
            endSample: fiveMinuteSampleCount,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(5 * 60)
        )
        let arbitrarySampleCount: Int64 = 123_456
        let arbitraryChunk = AudioChunk(
            recordingID: recording.id,
            relativePath: "Recordings/arbitrary-length.m4a",
            startSample: historicalChunk.endSample,
            endSample: historicalChunk.endSample + arbitrarySampleCount,
            startedAt: historicalChunk.endedAt,
            endedAt: historicalChunk.endedAt.addingTimeInterval(
                TimeInterval(arbitrarySampleCount) / 16_000
            )
        )

        try await repository.addChunk(historicalChunk, at: historicalChunk.endedAt)
        try await repository.addChunk(arbitraryChunk, at: arbitraryChunk.endedAt)

        let storedChunks = try await repository.chunks(recordingID: recording.id)
        #expect(storedChunks.count == 2)
        let storedHistorical = try #require(storedChunks.first)
        let storedArbitrary = try #require(storedChunks.last)
        #expect(storedHistorical.id == historicalChunk.id)
        #expect(storedHistorical.recordingID == historicalChunk.recordingID)
        #expect(storedHistorical.relativePath == historicalChunk.relativePath)
        #expect(storedHistorical.startSample == historicalChunk.startSample)
        #expect(storedHistorical.endSample == historicalChunk.endSample)
        #expect(storedHistorical.state == historicalChunk.state)
        #expect(storedHistorical.isPinned == historicalChunk.isPinned)
        #expect(storedHistorical.audioRemovedAt == historicalChunk.audioRemovedAt)
        #expect(storedArbitrary.id == arbitraryChunk.id)
        #expect(storedArbitrary.recordingID == arbitraryChunk.recordingID)
        #expect(storedArbitrary.relativePath == arbitraryChunk.relativePath)
        #expect(storedArbitrary.startSample == arbitraryChunk.startSample)
        #expect(storedArbitrary.endSample == arbitraryChunk.endSample)
        #expect(storedArbitrary.state == arbitraryChunk.state)
        #expect(storedArbitrary.isPinned == arbitraryChunk.isPinned)
        #expect(storedArbitrary.audioRemovedAt == arbitraryChunk.audioRemovedAt)
        #expect(storedChunks.map { $0.endSample - $0.startSample } == [
            fiveMinuteSampleCount,
            arbitrarySampleCount,
        ])
    }

    @Test func presentationProgressSeparatesCaptureFromProcessingAndReportsTranscribedUpTo() {
        let startedAt = Date(timeIntervalSince1970: 1_785_913_200)
        let recording = Recording(
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(125),
            state: .processing
        )
        let pending = RecordingJob(
            id: UUID(),
            recordingID: recording.id,
            chunkID: UUID(),
            kind: .transcription,
            state: .pending,
            attemptCount: 0,
            lastError: "deferredUntilForeground",
            createdAt: startedAt,
            updatedAt: startedAt
        )
        let progress = RecordingPresentationProgress.resolve(
            recording: recording,
            jobs: [pending],
            liveCaptureState: nil,
            lastFinalizedTranscriptSample: 96_000,
            sampleRate: 16_000
        )
        #expect(progress.capture == .idle)
        #expect(progress.processing == .deferredUntilForeground)
        #expect(progress.transcribedUpTo == 6)
        #expect(progress.outstandingItemCount == 1)
        #expect(progress.canRetry == false)
        #expect(RecordingStatusStyle.transcribedUpToText(progress.transcribedUpTo) == "已转写至 +0:06")
        #expect(RecordingStatusStyle.outstandingItemsText(progress.outstandingItemCount) == "还剩 1 项")
        #expect(RecordingStatusStyle.processingText(for: .needsAttention).contains("重试"))
        #expect(RecordingStatusStyle.processingText(for: .complete) == "全部完成")
    }

    @Test @MainActor func stopReleasesCaptureChromeWhileRecordingKeepsProcessingState() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let capture = MockRecordingCapture()
        let coordinator = RecordingSessionCoordinator(
            repository: repository,
            capture: capture,
            lowStorageGuard: LowStorageGuard(minimumAvailableBytes: 1) { _ in 1_000 },
            enablesRemoteStopCommand: false
        )
        let firstID = try await coordinator.start()
        capture.currentSample = 16_000
        try await coordinator.stop()

        #expect(coordinator.presentationState == .idle)
        #expect(coordinator.captureState == .idle)
        #expect(coordinator.activeRecordingID == nil)
        #expect(try await repository.recording(id: firstID)?.state == .processing)

        let secondID = try await coordinator.start()
        #expect(secondID != firstID)
        #expect(coordinator.presentationState == .recording)
        #expect(coordinator.activeRecordingID == secondID)
        #expect(try await coordinator.lifecycleState(recordingID: firstID) == .init(
            recordingID: firstID,
            capture: .idle,
            processing: .processing
        ))
        #expect(try await coordinator.lifecycleState(recordingID: secondID) == .init(
            recordingID: secondID,
            capture: .recording,
            processing: .idle
        ))
    }

    @Test func illegalRecordingStateTransitionsAreRejected() throws {
        var machine = RecordingStateMachine(state: .recording)
        #expect(try machine.apply(.pause) == .paused)
        #expect(throws: RecordingStateMachine.TransitionError.self) {
            try machine.apply(.processingCompleted)
        }
        #expect(try machine.apply(.resume) == .recording)
        #expect(try machine.apply(.stopRequested) == .stopping)
        #expect(try machine.apply(.captureStopped) == .processing)
        #expect(try machine.apply(.processingCompleted) == .complete)
        #expect(try machine.apply(.retryProcessing) == .processing)
    }

    @Test @MainActor func coordinatorDoesNotTouchMicrophoneBeforeExplicitStartOrWhenStorageIsLow() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let capture = MockRecordingCapture()
        let guardrail = LowStorageGuard(minimumAvailableBytes: 100) { _ in 99 }
        let coordinator = RecordingSessionCoordinator(
            repository: repository,
            capture: capture,
            lowStorageGuard: guardrail,
            enablesRemoteStopCommand: false
        )

        #expect(capture.startCount == 0)
        await #expect(throws: LowStorageGuard.StorageError.insufficient(
            availableBytes: 99,
            minimumBytes: 100
        )) {
            try await coordinator.start()
        }
        #expect(capture.startCount == 0)
        #expect(coordinator.presentationState == .idle)
    }

    @Test @MainActor func backgroundCaptureInterruptionGapAndStopShareOneTruthfulState() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let capture = MockRecordingCapture()
        let startedAt = Date(timeIntervalSince1970: 1_785_913_200)
        let coordinator = RecordingSessionCoordinator(
            repository: repository,
            capture: capture,
            lowStorageGuard: LowStorageGuard(minimumAvailableBytes: 1) { _ in 1_000 },
            enablesRemoteStopCommand: false,
            now: { startedAt }
        )

        let recordingID = try await coordinator.start()
        #expect(coordinator.presentationState == .recording)
        #expect(capture.startCount == 1)
        coordinator.applicationEnteredBackground()
        #expect(coordinator.isApplicationInBackground)
        #expect(capture.stopCount == 0)

        capture.currentSample = 32_000
        capture.emit(.init(
            kind: .interruptionBegan,
            occurredAt: startedAt.addingTimeInterval(2),
            sampleIndex: 32_000
        ))
        #expect(await presentationState(of: coordinator, becomes: .interrupted))

        capture.currentSample = 48_000
        capture.emit(.init(
            kind: .interruptionEnded(shouldResume: true),
            occurredAt: startedAt.addingTimeInterval(3),
            sampleIndex: 48_000
        ))
        #expect(await presentationState(of: coordinator, becomes: .recording))

        try await coordinator.stop()
        #expect(capture.stopCount == 1)
        #expect(coordinator.presentationState == .idle)
        #expect(coordinator.captureState == .idle)
        #expect(coordinator.activeRecordingID == nil)
        #expect(try await repository.recording(id: recordingID)?.state == .processing)
        let gaps = try await repository.gaps(recordingID: recordingID)
        #expect(gaps.count == 1)
        #expect(gaps[0].startSample == 32_000)
        #expect(gaps[0].endSample == 48_000)
        let chunks = try await repository.chunks(recordingID: recordingID)
        #expect(chunks.count == 1)
        #expect(chunks[0].startSample == 0)
        #expect(chunks[0].endSample == 48_000)
    }

    @Test func retentionPurgesExpiredMeetingAndPersonalAudioButPreservesPinnedAudioAndDocuments() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let now = Date(timeIntervalSince1970: 1_785_913_200)
        let expiredStart = now.addingTimeInterval(-8 * 24 * 60 * 60)

        let personal = Recording(startedAt: expiredStart, isMeeting: false)
        let meeting = Recording(startedAt: expiredStart, isMeeting: true)
        var pinnedRecording = Recording(startedAt: expiredStart)
        pinnedRecording.retention.isPinned = true
        let chunkPinnedRecording = Recording(startedAt: expiredStart)
        for recording in [personal, meeting, pinnedRecording, chunkPinnedRecording] {
            try await repository.createRecording(recording, at: expiredStart)
        }

        let personalChunk = try await makeStoredChunk(for: personal, root: root)
        let meetingChunk = try await makeStoredChunk(for: meeting, root: root)
        let pinnedRecordingChunk = try await makeStoredChunk(for: pinnedRecording, root: root)
        var pinnedChunk = try await makeStoredChunk(for: chunkPinnedRecording, root: root)
        pinnedChunk.isPinned = true
        for chunk in [personalChunk, meetingChunk, pinnedRecordingChunk, pinnedChunk] {
            try await repository.addChunk(chunk, at: chunk.endedAt)
        }

        let transcriptURL = root.appendingPathComponent("Documents/transcript.json")
        try FileManager.default.createDirectory(
            at: transcriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("transcript remains".utf8).write(to: transcriptURL)

        let result = try await repository.purgeExpiredAudio(at: now)

        #expect(Set(result.removedChunkIDs) == Set([personalChunk.id, meetingChunk.id]))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(personalChunk.relativePath).path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(meetingChunk.relativePath).path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(pinnedRecordingChunk.relativePath).path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(pinnedChunk.relativePath).path))
        #expect(FileManager.default.fileExists(atPath: transcriptURL.path))
        #expect(try await repository.chunks(recordingID: personal.id)[0].state == .audioRemoved)
        #expect(try await repository.chunks(recordingID: meeting.id)[0].state == .audioRemoved)
    }

    @Test func diagnosticsLocalizeCorruptionOverlapAndUnexplainedMissingSamples() {
        let recordingID = UUID()
        let first = AudioChunk(
            recordingID: recordingID,
            relativePath: "first.m4a",
            startSample: 0,
            endSample: 16_000,
            startedAt: .distantPast,
            endedAt: .distantPast.addingTimeInterval(1)
        )
        let overlapping = AudioChunk(
            recordingID: recordingID,
            relativePath: "overlap.m4a",
            startSample: 15_000,
            endSample: 24_000,
            startedAt: .distantPast,
            endedAt: .distantPast.addingTimeInterval(1)
        )
        let afterMissingRange = AudioChunk(
            recordingID: recordingID,
            relativePath: "missing.m4a",
            startSample: 32_000,
            endSample: 48_000,
            startedAt: .distantPast,
            endedAt: .distantPast.addingTimeInterval(1)
        )
        let diagnostics = RecordingDiagnostics(
            fileExists: { !$0.lastPathComponent.hasPrefix("missing") },
            isPlayableAudio: { !$0.lastPathComponent.hasPrefix("overlap") }
        )

        let issues = diagnostics.inspect(
            chunks: [afterMissingRange, first, overlapping],
            gaps: [],
            rootURL: URL(fileURLWithPath: "/recordings")
        )

        #expect(issues.contains(.overlappingChunks(
            previousChunkID: first.id,
            nextChunkID: overlapping.id,
            overlapSamples: 1_000
        )))
        #expect(issues.contains(.unexplainedMissingSamples(
            previousChunkID: overlapping.id,
            nextChunkID: afterMissingRange.id,
            missingSamples: 8_000
        )))
        #expect(issues.contains(.unreadableAudioFile(
            chunkID: overlapping.id,
            relativePath: overlapping.relativePath
        )))
        #expect(issues.contains(.missingAudioFile(
            chunkID: afterMissingRange.id,
            relativePath: afterMissingRange.relativePath
        )))
    }

    @Test func explicitGapExplainsTimelineDiscontinuity() {
        let recordingID = UUID()
        let first = AudioChunk(
            recordingID: recordingID,
            relativePath: "first.m4a",
            startSample: 0,
            endSample: 16_000,
            startedAt: .distantPast,
            endedAt: .distantPast.addingTimeInterval(1)
        )
        let second = AudioChunk(
            recordingID: recordingID,
            relativePath: "second.m4a",
            startSample: 32_000,
            endSample: 48_000,
            startedAt: .distantPast,
            endedAt: .distantPast.addingTimeInterval(1)
        )
        let gap = RecordingGap(
            id: UUID(),
            recordingID: recordingID,
            reason: .systemInterruption,
            startSample: 16_000,
            endSample: 32_000,
            startedAt: .distantPast,
            endedAt: .distantPast.addingTimeInterval(1)
        )
        let diagnostics = RecordingDiagnostics(fileExists: { _ in true }, isPlayableAudio: { _ in true })

        #expect(diagnostics.inspect(
            chunks: [first, second],
            gaps: [gap],
            rootURL: URL(fileURLWithPath: "/recordings")
        ).isEmpty)
    }

    @Test func diagnosticsReportsUnindexedAudioWithoutDeletingOrIndexingIt() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let recording = Recording(startedAt: Date(timeIntervalSince1970: 1_785_913_200))
        try await repository.createRecording(recording, at: recording.startedAt)
        let relativePath = "Recordings/\(recording.id.uuidString.lowercased())/audio/orphan.m4a"
        let orphanURL = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: orphanURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x7F, count: 128).write(to: orphanURL)

        let issues = try await RecordingDiagnostics().inspect(
            recordingID: recording.id,
            repository: repository
        )

        #expect(issues == [.unindexedAudioFile(relativePath: relativePath)])
        #expect(FileManager.default.fileExists(atPath: orphanURL.path))
        #expect(try await repository.chunks(recordingID: recording.id).isEmpty)
    }

    @Test func validationReportRecordsDeviceSystemAndPendingHumanChecks() {
        let report = RecordingValidationReport(
            deviceModel: "iPhone 15 Pro",
            operatingSystem: "iOS 26.5",
            appBuild: "0.1.0-dev",
            startedAt: Date(timeIntervalSince1970: 1_785_913_200),
            completedAt: nil,
            checks: [.init(id: "two-hour", title: "2 小时分片", outcome: .pending, notes: "等待 Human")],
            integrityIssues: []
        )

        let markdown = report.markdown()
        #expect(markdown.contains("iPhone 15 Pro"))
        #expect(markdown.contains("iOS 26.5"))
        #expect(markdown.contains("2 小时分片 | pending | 等待 Human"))
    }

    @Test func successfulShortSpeechPersistsCanonicalJSONAndMarkdown() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let startedAt = Date(timeIntervalSince1970: 1_785_913_200.125)
        let recording = Recording(
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(13),
            title: "短录音",
            state: .processing
        )
        let chunk = AudioChunk(
            recordingID: recording.id,
            relativePath: "Recordings/short.m4a",
            startSample: 0,
            endSample: 208_000,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(13)
        )
        let document = TranscriptDocumentV1(
            recording: recording,
            chunks: [chunk],
            segmentTexts: [(chunkID: chunk.id, text: "这是一条十三秒的测试录音。")],
            timezone: "Asia/Shanghai"
        )
        try document.requireContent()

        let store = try TranscriptDocumentStore(rootURL: root)
        try await store.write(document)

        #expect(try await store.document(recordingID: recording.id) == document)
        let json = try String(contentsOf: await store.jsonURL(for: recording.id), encoding: .utf8)
        #expect(json.contains("\"started_at\" : \"2026-08-05T07:00:00.125Z\""))
        let markdown = try #require(await store.markdown(recordingID: recording.id))
        #expect(markdown.contains("schema: voice-context/transcript@1"))
        #expect(markdown.contains("这是一条十三秒的测试录音。"))
    }

    @Test func transcriptStoreReadsLegacyAcronymIDKeysWrittenOnDevice() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recordingID = UUID(uuidString: "BA485C93-6D6E-42E9-ADDA-B8DA50B2CA7C")!
        let chunkID = UUID(uuidString: "D1765381-81EC-4761-BDDF-8978200D4197")!
        let segmentID = UUID(uuidString: "BA485C93-6D6E-42E9-ADDA-B8DA00000001")!
        let json = """
        {
          "schema": "voice-context/transcript@1",
          "recording_id": "\(recordingID.uuidString)",
          "kind": "recording",
          "state": "complete",
          "revision": 1,
          "tags": [],
          "started_at": "2026-08-06T03:51:28Z",
          "ended_at": "2026-08-06T03:51:41Z",
          "timezone": "Asia/Shanghai",
          "language": "zh",
          "audio": {
            "local_only": true,
            "available_on_this_device": true,
            "retention": "seven_days"
          },
          "speech_spans": [],
          "speakers": [],
          "segments": [{
            "id": "\(segmentID.uuidString)",
            "sequence": 1,
            "started_at": "2026-08-06T03:51:28Z",
            "offset_milliseconds": 0,
            "text": "已省略的真机测试文本",
            "source_chunk_id": "\(chunkID.uuidString)",
            "speech_span_i_ds": []
          }],
          "gaps": []
        }
        """
        let store = try TranscriptDocumentStore(rootURL: root)
        try Data(json.utf8).write(to: await store.jsonURL(for: recordingID))

        let document = try #require(await store.document(recordingID: recordingID))
        #expect(document.recordingID == recordingID)
        #expect(document.segments.first?.sourceChunkID == chunkID)
        #expect(document.segments.first?.speechSpanIDs == [])
    }

    @Test func emptyOrFailedSpeechDoesNotBecomeAnEmptyCompletedDocument() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = Recording(startedAt: .distantPast, endedAt: .distantPast.addingTimeInterval(13), state: .processing)
        let chunk = AudioChunk(
            recordingID: recording.id,
            relativePath: "Recordings/empty.m4a",
            startSample: 0,
            endSample: 208_000,
            startedAt: recording.startedAt,
            endedAt: recording.endedAt!
        )
        let document = TranscriptDocumentV1(
            recording: recording,
            chunks: [chunk],
            segmentTexts: [(chunkID: chunk.id, text: "   ")]
        )

        #expect(throws: TranscriptDocumentV1.DocumentError.emptyTranscript) {
            try document.requireContent()
        }
        let store = try TranscriptDocumentStore(rootURL: root)
        #expect(try await store.document(recordingID: recording.id) == nil)
    }

    @Test func markdownIsRebuiltFromTheStoredJSONDocument() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let startedAt = Date(timeIntervalSince1970: 1_785_913_200)
        let recording = Recording(startedAt: startedAt, endedAt: startedAt.addingTimeInterval(2), state: .processing)
        let chunk = AudioChunk(
            recordingID: recording.id,
            relativePath: "Recordings/one.m4a",
            startSample: 16_000,
            endSample: 32_000,
            startedAt: startedAt.addingTimeInterval(1),
            endedAt: startedAt.addingTimeInterval(2)
        )
        let document = TranscriptDocumentV1(
            recording: recording,
            chunks: [chunk],
            segmentTexts: [(chunkID: chunk.id, text: "第二秒开始的文本。")]
        )
        let store = try TranscriptDocumentStore(rootURL: root)
        try await store.write(document)

        let decoded = try #require(await store.document(recordingID: recording.id))
        #expect(try await store.markdown(recordingID: recording.id) == TranscriptMarkdownRenderer.render(decoded))
        #expect(decoded.segments.first?.offsetMilliseconds == 1_000)
    }

    @Test func transcriptSchemaFixturePassesRoundTripAndMarkdownConsistency() async throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/transcript_v1_schema_fixture.json")
        let fixtureData = try Data(contentsOf: fixtureURL)
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TranscriptDocumentStore(rootURL: root)
        let recordingID = UUID(uuidString: "BA485C93-6D6E-42E9-ADDA-B8DA50B2CA7C")!
        try fixtureData.write(to: await store.jsonURL(for: recordingID))

        let document = try #require(await store.document(recordingID: recordingID))
        #expect(document.schema == TranscriptDocumentV1.schema)
        #expect(document.revision == 1)
        #expect(document.segments.map(\.sequence) == [1, 2])
        #expect(document.segments.map(\.offsetMilliseconds) == [0, 60_000])
        #expect(document.segments.map(\.text) == ["第一分钟的文本。", "第二分钟的文本。"])
        #expect(document.segments.map(\.startSample) == [0, 960_000])
        #expect(document.segments.map(\.endSample) == [960_000, 1_920_000])
        #expect(document.segments[0].sourceRanges.map(\.sourceID) == [
            UUID(uuidString: "D1765381-81EC-4761-BDDF-8978200D4197")!
        ])

        try await store.write(document)
        let reloaded = try #require(await store.document(recordingID: recordingID))
        #expect(reloaded == document)
        let markdown = try #require(await store.markdown(recordingID: recordingID))
        #expect(markdown == TranscriptMarkdownRenderer.render(reloaded))
        #expect(markdown.contains("schema: voice-context/transcript@1"))
        #expect(markdown.contains("revision: 1"))
        #expect(markdown.contains("第一分钟的文本。"))
        #expect(markdown.contains("第二分钟的文本。"))
    }

    @Test func transcriptSequenceIsDerivedByChunkStartTimeNotSubmissionOrder() {
        let startedAt = Date(timeIntervalSince1970: 1_785_913_200)
        let recording = Recording(
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(120),
            state: .processing
        )
        let later = AudioChunk(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            recordingID: recording.id,
            relativePath: "Recordings/later.m4a",
            startSample: 960_000,
            endSample: 1_920_000,
            startedAt: startedAt.addingTimeInterval(60),
            endedAt: startedAt.addingTimeInterval(120)
        )
        let earlier = AudioChunk(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            recordingID: recording.id,
            relativePath: "Recordings/earlier.m4a",
            startSample: 0,
            endSample: 960_000,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60)
        )
        let document = TranscriptDocumentV1(
            recording: recording,
            chunks: [later, earlier],
            // Intentionally reversed relative to absolute time.
            segmentTexts: [
                (chunkID: later.id, text: "后到的一分钟"),
                (chunkID: earlier.id, text: "先发生的一分钟"),
            ],
            language: "zh",
            state: .processing
        )

        #expect(document.segments.map(\.sequence) == [1, 2])
        #expect(document.segments.map(\.sourceChunkID) == [earlier.id, later.id])
        #expect(document.segments.map(\.offsetMilliseconds) == [0, 60_000])
        #expect(document.segments.map(\.text) == ["先发生的一分钟", "后到的一分钟"])
    }

    @Test func transcriptAppendIsIdempotentAndBumpsRevisionWithoutDuplicateSegments() {
        let startedAt = Date(timeIntervalSince1970: 1_785_913_200)
        let recording = Recording(
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(120),
            state: .processing
        )
        let first = AudioChunk(
            recordingID: recording.id,
            relativePath: "Recordings/first.m4a",
            startSample: 0,
            endSample: 960_000,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60)
        )
        let second = AudioChunk(
            recordingID: recording.id,
            relativePath: "Recordings/second.m4a",
            startSample: 960_000,
            endSample: 1_920_000,
            startedAt: startedAt.addingTimeInterval(60),
            endedAt: startedAt.addingTimeInterval(120)
        )
        let initial = TranscriptDocumentV1(
            recording: recording,
            chunks: [first, second],
            segmentTexts: [(chunkID: first.id, text: "第一段")],
            language: "zh",
            state: .processing
        )
        let once = initial.appending(
            recording: recording,
            chunks: [first, second],
            text: "第二段",
            sourceChunkID: second.id
        )
        let retry = once.appending(
            recording: recording,
            chunks: [first, second],
            text: "第二段-重试",
            sourceChunkID: second.id,
            replacingSourceChunkIDs: [second.id]
        )

        #expect(initial.revision == 1)
        #expect(once.revision == 2)
        #expect(retry.revision == 3)
        #expect(once.segments.count == 2)
        #expect(retry.segments.count == 2)
        #expect(retry.segments.map(\.text) == ["第一段", "第二段-重试"])
        #expect(retry.segments.map(\.sequence) == [1, 2])
    }

    @Test func transcriptCrossChunkSegmentStoresOrderedSourceRangesAndAbsoluteBounds() {
        let startedAt = Date(timeIntervalSince1970: 1_785_913_200)
        let recording = Recording(
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(120),
            state: .processing
        )
        let first = AudioChunk(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            recordingID: recording.id,
            relativePath: "Recordings/a.m4a",
            startSample: 0,
            endSample: 960_000,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60)
        )
        let second = AudioChunk(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            recordingID: recording.id,
            relativePath: "Recordings/b.m4a",
            startSample: 960_000,
            endSample: 1_920_000,
            startedAt: startedAt.addingTimeInterval(60),
            endedAt: startedAt.addingTimeInterval(120)
        )
        let ranges = [
            TranscriptDocumentV1.SourceRange(
                sourceKind: .audioChunk,
                sourceID: first.id,
                startSample: 950_400,
                endSample: 960_000
            ),
            TranscriptDocumentV1.SourceRange(
                sourceKind: .audioChunk,
                sourceID: second.id,
                startSample: 960_000,
                endSample: 979_200
            ),
        ]
        let document = TranscriptDocumentV1(
            recording: recording,
            chunks: [first, second],
            segmentDrafts: [
                TranscriptDocumentV1.SegmentDraft(
                    text: "跨分片一句话",
                    sourceRanges: ranges
                )
            ],
            language: "zh",
            state: .processing
        )

        #expect(document.segments.count == 1)
        let segment = document.segments[0]
        #expect(segment.startSample == 950_400)
        #expect(segment.endSample == 979_200)
        #expect(segment.offsetMilliseconds == 59_400)
        #expect(segment.sourceRanges.map(\.sourceID) == [first.id, second.id])
        #expect(segment.sourceRanges.map(\.startSample) == [950_400, 960_000])
        #expect(segment.sourceRanges.map(\.endSample) == [960_000, 979_200])
        #expect(segment.sourceChunkID == first.id)
        #expect(segment.playbackStartTime == 950_400.0 / 16_000)
    }

    @Test func transcriptLegacySourceChunkIDMigratesAndRollbackDualWrites() async throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/transcript_v1_legacy_source_chunk_fixture.json")
        let fixtureData = try Data(contentsOf: fixtureURL)
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TranscriptDocumentStore(rootURL: root)
        let recordingID = UUID(uuidString: "BA485C93-6D6E-42E9-ADDA-B8DA50B2CA7C")!
        let chunkID = UUID(uuidString: "D1765381-81EC-4761-BDDF-8978200D4197")!
        try fixtureData.write(to: await store.jsonURL(for: recordingID))

        let migrated = try #require(await store.document(recordingID: recordingID))
        #expect(migrated.segments.count == 1)
        #expect(migrated.segments[0].sourceChunkID == chunkID)
        #expect(migrated.segments[0].sourceRanges.count == 1)
        #expect(migrated.segments[0].sourceRanges[0].sourceID == chunkID)
        #expect(migrated.segments[0].sourceRanges[0].sourceKind == .audioChunk)
        #expect(migrated.segments[0].startSample == 0)
        #expect(migrated.segments[0].text == "旧版单一 source_chunk_id。")
        #expect(migrated.legacyRollbackSegments().map(\.sourceChunkID) == [chunkID])

        try await store.write(migrated)
        let encoded = try String(contentsOf: await store.jsonURL(for: recordingID), encoding: .utf8)
        #expect(encoded.contains("\"source_ranges\""))
        #expect(encoded.contains("\"source_chunk_id\""))
        #expect(encoded.contains(chunkID.uuidString))

        let reloaded = try #require(await store.document(recordingID: recordingID))
        #expect(reloaded == migrated)
        #expect(reloaded.segments[0].text == migrated.segments[0].text)
        #expect(reloaded.segments[0].offsetMilliseconds == migrated.segments[0].offsetMilliseconds)
        let markdown = try #require(await store.markdown(recordingID: recordingID))
        #expect(markdown.contains("旧版单一 source_chunk_id。"))
        #expect(markdown.contains("schema: voice-context/transcript@1"))
    }

    @Test func transcriptRetryByStableSampleIdentityDoesNotDuplicateSegments() {
        let startedAt = Date(timeIntervalSince1970: 1_785_913_200)
        let recording = Recording(
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(120),
            state: .processing
        )
        let first = AudioChunk(
            recordingID: recording.id,
            relativePath: "Recordings/first.m4a",
            startSample: 0,
            endSample: 960_000,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60)
        )
        let second = AudioChunk(
            recordingID: recording.id,
            relativePath: "Recordings/second.m4a",
            startSample: 960_000,
            endSample: 1_920_000,
            startedAt: startedAt.addingTimeInterval(60),
            endedAt: startedAt.addingTimeInterval(120)
        )
        let ranges = [
            TranscriptDocumentV1.SourceRange(
                sourceKind: .audioChunk,
                sourceID: first.id,
                startSample: 950_400,
                endSample: 960_000
            ),
            TranscriptDocumentV1.SourceRange(
                sourceKind: .audioChunk,
                sourceID: second.id,
                startSample: 960_000,
                endSample: 979_200
            ),
        ]
        let draft = TranscriptDocumentV1.SegmentDraft(
            text: "跨分片原文",
            sourceRanges: ranges
        )
        let initial = TranscriptDocumentV1(
            recording: recording,
            chunks: [first, second],
            segmentDrafts: [draft],
            language: "zh",
            state: .processing
        )
        let retry = initial.appending(
            recording: recording,
            chunks: [first, second],
            draft: TranscriptDocumentV1.SegmentDraft(
                text: "跨分片重试",
                sourceRanges: ranges
            ),
            replacingSourceIDs: [first.id, second.id]
        )
        let sameIdentity = retry.appending(
            recording: recording,
            chunks: [first, second],
            draft: TranscriptDocumentV1.SegmentDraft(
                text: "跨分片再次重试",
                startSample: 950_400,
                endSample: 979_200,
                sourceRanges: ranges
            )
        )

        #expect(initial.segments.count == 1)
        #expect(retry.segments.count == 1)
        #expect(sameIdentity.segments.count == 1)
        #expect(retry.segments[0].text == "跨分片重试")
        #expect(sameIdentity.segments[0].text == "跨分片再次重试")
        #expect(sameIdentity.segments[0].id == initial.segments[0].id)
        #expect(sameIdentity.revision == 3)
    }

    @Test func transcriptTimelineExportAndDeleteCleanupHandleMultipleSourceRanges() {
        let startedAt = Date(timeIntervalSince1970: 1_785_913_200)
        let recording = Recording(
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(120),
            state: .complete
        )
        let first = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let second = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let third = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let document = TranscriptDocumentV1(
            recording: recording,
            chunks: [
                AudioChunk(
                    id: first,
                    recordingID: recording.id,
                    relativePath: "Recordings/a.m4a",
                    startSample: 0,
                    endSample: 960_000,
                    startedAt: startedAt,
                    endedAt: startedAt.addingTimeInterval(60)
                ),
                AudioChunk(
                    id: second,
                    recordingID: recording.id,
                    relativePath: "Recordings/b.m4a",
                    startSample: 960_000,
                    endSample: 1_920_000,
                    startedAt: startedAt.addingTimeInterval(60),
                    endedAt: startedAt.addingTimeInterval(120)
                ),
                AudioChunk(
                    id: third,
                    recordingID: recording.id,
                    relativePath: "Recordings/c.m4a",
                    startSample: 1_920_000,
                    endSample: 2_880_000,
                    startedAt: startedAt.addingTimeInterval(120),
                    endedAt: startedAt.addingTimeInterval(180)
                ),
            ],
            segmentDrafts: [
                TranscriptDocumentV1.SegmentDraft(
                    text: "跨片",
                    sourceRanges: [
                        .init(sourceID: first, startSample: 950_400, endSample: 960_000),
                        .init(sourceID: second, startSample: 960_000, endSample: 979_200),
                    ]
                ),
                TranscriptDocumentV1.SegmentDraft(
                    text: "单片",
                    sourceRanges: [
                        .init(sourceID: third, startSample: 2_000_000, endSample: 2_100_000),
                    ]
                ),
            ],
            language: "zh"
        )

        #expect(document.segment(atPlaybackTime: 950_400.0 / 16_000)?.text == "跨片")
        #expect(document.segment(atPlaybackTime: 2_050_000.0 / 16_000)?.text == "单片")
        #expect(document.segmentForErrorLocation(sourceID: second)?.text == "跨片")
        #expect(document.exportSourceIDs() == [first, second, third])

        let afterPartialDelete = document.updatingAudioAvailability(availableSourceIDs: [third])
        #expect(afterPartialDelete.audio.availableOnThisDevice == true)
        #expect(afterPartialDelete.revision == document.revision + 1)

        let afterFullDelete = document.updatingAudioAvailability(availableSourceIDs: [])
        #expect(afterFullDelete.audio.availableOnThisDevice == false)
        #expect(afterFullDelete.segments.map(\.text) == ["跨片", "单片"])
    }

    @Test func transcriptStoreWriteLeavesNoHalfFilesAndIsReconstructible() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let startedAt = Date(timeIntervalSince1970: 1_785_913_200.125)
        let recording = Recording(
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60),
            title: "原子写入",
            state: .processing
        )
        let chunk = AudioChunk(
            recordingID: recording.id,
            relativePath: "Recordings/atomic.m4a",
            startSample: 0,
            endSample: 960_000,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60)
        )
        let document = TranscriptDocumentV1(
            recording: recording,
            chunks: [chunk],
            segmentTexts: [(chunkID: chunk.id, text: "原子写入文本")],
            timezone: "Asia/Shanghai",
            language: "zh"
        )
        let store = try TranscriptDocumentStore(rootURL: root)
        try await store.write(document)

        let transcriptsRoot = await store.rootURL
        let names = try FileManager.default.contentsOfDirectory(atPath: transcriptsRoot.path)
        #expect(names.allSatisfy { !$0.hasSuffix(".writing") })
        #expect(names.contains("\(recording.id.uuidString).json"))
        #expect(names.contains("\(recording.id.uuidString).md"))

        let decoded = try #require(await store.document(recordingID: recording.id))
        #expect(decoded == document)
        let markdown = try #require(await store.markdown(recordingID: recording.id))
        #expect(markdown == TranscriptMarkdownRenderer.render(decoded))
        #expect(markdown.contains("2026-08-05T07:00:00.125Z"))
    }

    @Test func schedulerProcessesSameRecordingChunksInStartSampleOrderDespiteCreatedAtSkew() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let startedAt = Date(timeIntervalSince1970: 1_785_913_200)
        let recording = Recording(
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(120),
            state: .processing
        )
        try await repository.createRecording(recording, at: startedAt)
        let firstChunk = AudioChunk(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            recordingID: recording.id,
            relativePath: "Recordings/first.m4a",
            startSample: 0,
            endSample: 960_000,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60)
        )
        let secondChunk = AudioChunk(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            recordingID: recording.id,
            relativePath: "Recordings/second.m4a",
            startSample: 960_000,
            endSample: 1_920_000,
            startedAt: startedAt.addingTimeInterval(60),
            endedAt: startedAt.addingTimeInterval(120)
        )
        try await repository.addChunk(firstChunk, at: firstChunk.endedAt)
        try await repository.addChunk(secondChunk, at: secondChunk.endedAt)

        // Persist the later chunk's job with an earlier createdAt to prove the
        // scheduler orders by chunk start sample, not job creation skew.
        let laterCreated = startedAt.addingTimeInterval(1)
        let earlierCreated = startedAt.addingTimeInterval(2)
        try await repository.upsertJob(
            RecordingJob(
                id: UUID(),
                recordingID: recording.id,
                chunkID: secondChunk.id,
                kind: .transcription,
                state: .pending,
                attemptCount: 0,
                lastError: nil,
                createdAt: laterCreated,
                updatedAt: laterCreated
            ),
            at: laterCreated
        )
        try await repository.upsertJob(
            RecordingJob(
                id: UUID(),
                recordingID: recording.id,
                chunkID: firstChunk.id,
                kind: .transcription,
                state: .pending,
                attemptCount: 0,
                lastError: nil,
                createdAt: earlierCreated,
                updatedAt: earlierCreated
            ),
            at: earlierCreated
        )

        let order = SchedulerChunkOrderProbe()
        let scheduler = ForegroundTranscriptionScheduler(repository: repository) { lease in
            guard case let .audioChunk(chunkID) = lease.sourceTarget else {
                Issue.record("expected immutable audio chunk target")
                return
            }
            await order.record(chunkID)
        }

        try await scheduler.resumePendingJobs { _ in }
        await scheduler.waitForIdle()

        #expect(await order.chunkIDs == [firstChunk.id, secondChunk.id])
        let jobs = try await repository.jobs(recordingID: recording.id)
        #expect(jobs.count == 2)
        #expect(jobs.allSatisfy { $0.state == .completed })
    }

    @Test func schedulerDrainsMultipleRecordingsFIFOUnderThermalLoad() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let older = Recording(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            startedAt: Date(timeIntervalSince1970: 1_785_913_200),
            endedAt: Date(timeIntervalSince1970: 1_785_913_260),
            state: .processing
        )
        let newer = Recording(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            startedAt: Date(timeIntervalSince1970: 1_785_913_300),
            endedAt: Date(timeIntervalSince1970: 1_785_913_360),
            state: .processing
        )
        try await repository.createRecording(older, at: older.startedAt)
        try await repository.createRecording(newer, at: newer.startedAt)
        let olderChunk = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
        let newerChunk = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001")!

        let thermal = ThermalStateProbe(initial: .serious)
        let gate = InferenceLifecycleGate()
        let order = SchedulerChunkOrderProbe()
        let scheduler = ForegroundTranscriptionScheduler(
            repository: repository,
            lifecycleGate: gate,
            admissionPolicy: TranscriptionAdmissionPolicy(
                thermalState: { thermal.current() },
                isPurchaseLocked: { false }
            )
        ) { lease in
            try await gate.beginMetalWork()
            guard case let .audioChunk(chunkID) = lease.sourceTarget else {
                Issue.record("expected immutable audio chunk target")
                return
            }
            await order.record(chunkID)
            await gate.endMetalWork()
        }

        try await scheduler.enqueue(recordingID: older.id, chunkID: olderChunk) { _ in }
        try await scheduler.enqueue(recordingID: newer.id, chunkID: newerChunk) { _ in }
        await scheduler.waitForIdle()

        #expect(await order.chunkIDs == [olderChunk, newerChunk])
        #expect(try await repository.jobs(recordingID: older.id)[0].state == .completed)
        #expect(try await repository.jobs(recordingID: newer.id)[0].state == .completed)
        #expect(await gate.metrics().peakInFlightMetalWork <= 1)
    }


    /// #49: start a new Recording while an older one is still processing or
    /// failed. Capture chrome, durable jobs, transcript segments, and the
    /// global Metal gate must stay isolated; same-Recording chunks remain
    /// ordered and Metal in-flight never exceeds 1.
    @Test @MainActor func dualRecordingIsolationKeepsJobsMetalAndCaptureSeparated() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let capture = MockRecordingCapture()
        let coordinator = RecordingSessionCoordinator(
            repository: repository,
            capture: capture,
            lowStorageGuard: LowStorageGuard(minimumAvailableBytes: 1) { _ in 1_000 },
            enablesRemoteStopCommand: false
        )

        let processingStarted = Date(timeIntervalSince1970: 1_785_913_200)
        let processing = Recording(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            startedAt: processingStarted,
            endedAt: processingStarted.addingTimeInterval(120),
            state: .processing
        )
        let failedStarted = Date(timeIntervalSince1970: 1_785_913_100)
        let failed = Recording(
            id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
            startedAt: failedStarted,
            endedAt: failedStarted.addingTimeInterval(60),
            state: .failed
        )
        try await repository.createRecording(failed, at: failed.startedAt)
        try await repository.createRecording(processing, at: processing.startedAt)

        let processingChunkA = AudioChunk(
            id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
            recordingID: processing.id,
            relativePath: "Recordings/processing-a.m4a",
            startSample: 0,
            endSample: 960_000,
            startedAt: processingStarted,
            endedAt: processingStarted.addingTimeInterval(60)
        )
        let processingChunkB = AudioChunk(
            id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!,
            recordingID: processing.id,
            relativePath: "Recordings/processing-b.m4a",
            startSample: 960_000,
            endSample: 1_920_000,
            startedAt: processingStarted.addingTimeInterval(60),
            endedAt: processingStarted.addingTimeInterval(120)
        )
        let failedChunk = AudioChunk(
            id: UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!,
            recordingID: failed.id,
            relativePath: "Recordings/failed.m4a",
            startSample: 0,
            endSample: 960_000,
            startedAt: failedStarted,
            endedAt: failedStarted.addingTimeInterval(60)
        )
        try await repository.addChunk(processingChunkA, at: processingChunkA.endedAt)
        try await repository.addChunk(processingChunkB, at: processingChunkB.endedAt)
        try await repository.addChunk(failedChunk, at: failedChunk.endedAt)

        try await repository.upsertJob(
            RecordingJob(
                id: UUID(),
                recordingID: failed.id,
                chunkID: failedChunk.id,
                kind: .transcription,
                state: .failed,
                attemptCount: 1,
                lastError: SchedulerTestError.noSpeech.localizedDescription,
                createdAt: failedStarted,
                updatedAt: failed.endedAt!
            ),
            at: failed.endedAt!
        )

        // Live capture of a third Recording must succeed while older work exists.
        let liveID = try await coordinator.start()
        #expect(liveID != processing.id)
        #expect(liveID != failed.id)
        #expect(coordinator.captureState == .recording)
        #expect(coordinator.presentationState == .recording)
        #expect(coordinator.activeRecordingID == liveID)

        let gate = InferenceLifecycleGate()
        let order = SchedulerChunkOrderProbe()
        let held = MetalHoldBarrier()
        let scheduler = ForegroundTranscriptionScheduler(
            repository: repository,
            lifecycleGate: gate
        ) { lease in
            try await gate.beginMetalWork()
            guard case let .audioChunk(chunkID) = lease.sourceTarget else {
                Issue.record("expected immutable audio chunk target")
                return
            }
            await order.record(chunkID)
            // Hold briefly so a peer drain would observe metalBusy if it raced.
            await held.holdBriefly()
            await gate.endMetalWork()
        }

        // Retry the failed Recording while the new capture is live; it must not
        // reclaim the microphone or cross into the live Recording's jobs.
        try await coordinator.retryProcessing(recordingID: failed.id)
        try await scheduler.retry(recordingID: failed.id) { _ in }
        try await scheduler.enqueue(recordingID: processing.id, chunkID: processingChunkB.id) { _ in }
        try await scheduler.enqueue(recordingID: processing.id, chunkID: processingChunkA.id) { _ in }
        await scheduler.waitForIdle()

        #expect(coordinator.activeRecordingID == liveID)
        #expect(coordinator.captureState == .recording)
        #expect(coordinator.presentationState == .recording)
        #expect(capture.startCount == 1)
        #expect(capture.stopCount == 0)

        // Same-Recording chunks stay start-sample ordered; failed retry runs as
        // its own Recording without contaminating the live capture identity.
        let observed = await order.chunkIDs
        let processingOrder = observed.filter {
            $0 == processingChunkA.id || $0 == processingChunkB.id
        }
        #expect(processingOrder == [processingChunkA.id, processingChunkB.id])
        #expect(observed.contains(failedChunk.id))
        #expect(Set(observed) == [failedChunk.id, processingChunkA.id, processingChunkB.id])
        #expect(await gate.metrics().peakInFlightMetalWork <= 1)
        #expect(try await repository.jobs(recordingID: processing.id).allSatisfy { $0.state == .completed })
        #expect(try await repository.jobs(recordingID: failed.id).allSatisfy { $0.state == .completed })
        #expect(try await repository.jobs(recordingID: liveID).isEmpty)

        // Stop releases mic chrome immediately; older completed jobs stay put.
        capture.currentSample = 16_000
        try await coordinator.stop()
        #expect(coordinator.captureState == .idle)
        #expect(coordinator.presentationState == .idle)
        #expect(coordinator.activeRecordingID == nil)
        #expect(capture.stopCount == 1)
        #expect(try await repository.recording(id: liveID)?.state == .processing)
        #expect(try await repository.jobs(recordingID: processing.id).count == 2)
        #expect(try await repository.jobs(recordingID: failed.id).count == 1)
    }

    /// #49: high thermal load admits transcription and does not block a new capture
    /// session.
    @Test @MainActor func schedulerAdmissionLeavesCaptureFreeAndCompletesUnderThermalLoad() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let capture = MockRecordingCapture()
        let coordinator = RecordingSessionCoordinator(
            repository: repository,
            capture: capture,
            lowStorageGuard: LowStorageGuard(minimumAvailableBytes: 1) { _ in 1_000 },
            enablesRemoteStopCommand: false
        )
        let older = Recording(
            startedAt: Date(timeIntervalSince1970: 1_785_913_200),
            endedAt: Date(timeIntervalSince1970: 1_785_913_260),
            state: .processing
        )
        try await repository.createRecording(older, at: older.startedAt)
        let chunkID = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000001")!

        let thermal = ThermalStateProbe(initial: .serious)
        let gate = InferenceLifecycleGate()
        let scheduler = ForegroundTranscriptionScheduler(
            repository: repository,
            lifecycleGate: gate,
            admissionPolicy: TranscriptionAdmissionPolicy(
                thermalState: { thermal.current() },
                isPurchaseLocked: { false }
            )
        ) { _ in
            try await gate.beginMetalWork()
            await gate.endMetalWork()
        }

        try await scheduler.enqueue(recordingID: older.id, chunkID: chunkID) { _ in }
        await scheduler.waitForIdle()
        #expect(try await repository.jobs(recordingID: older.id)[0].state == .completed)
        #expect(await gate.metrics().submittedMetalWork == 1)

        let liveID = try await coordinator.start()
        #expect(liveID != older.id)
        #expect(coordinator.captureState == .recording)
        #expect(capture.startCount == 1)
        #expect(coordinator.activeRecordingID == liveID)
    }

    /// #49: source_ranges seek helpers must honour half-open sample windows,
    /// land in the nearest prior segment across gaps, and resolve error
    /// locations through any range of a cross-chunk utterance.
    @Test func sourceRangesSeekHelpersCoverBoundariesGapsAndErrorLocations() {
        let startedAt = Date(timeIntervalSince1970: 1_785_913_200)
        let recording = Recording(
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(180),
            state: .complete
        )
        let first = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let second = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let third = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let document = TranscriptDocumentV1(
            recording: recording,
            chunks: [
                AudioChunk(
                    id: first,
                    recordingID: recording.id,
                    relativePath: "Recordings/a.m4a",
                    startSample: 0,
                    endSample: 960_000,
                    startedAt: startedAt,
                    endedAt: startedAt.addingTimeInterval(60)
                ),
                AudioChunk(
                    id: second,
                    recordingID: recording.id,
                    relativePath: "Recordings/b.m4a",
                    startSample: 960_000,
                    endSample: 1_920_000,
                    startedAt: startedAt.addingTimeInterval(60),
                    endedAt: startedAt.addingTimeInterval(120)
                ),
                AudioChunk(
                    id: third,
                    recordingID: recording.id,
                    relativePath: "Recordings/c.m4a",
                    startSample: 1_920_000,
                    endSample: 2_880_000,
                    startedAt: startedAt.addingTimeInterval(120),
                    endedAt: startedAt.addingTimeInterval(180)
                ),
            ],
            segmentDrafts: [
                TranscriptDocumentV1.SegmentDraft(
                    text: "跨片连续",
                    sourceRanges: [
                        .init(sourceID: first, startSample: 940_000, endSample: 960_000),
                        .init(sourceID: second, startSample: 960_000, endSample: 1_000_000),
                    ]
                ),
                TranscriptDocumentV1.SegmentDraft(
                    text: "间隙后",
                    sourceRanges: [
                        .init(sourceID: third, startSample: 2_100_000, endSample: 2_200_000),
                    ]
                ),
            ],
            language: "zh"
        )

        #expect(document.segments.count == 2)
        #expect(document.segments[0].playbackStartTime == 940_000.0 / 16_000)
        #expect(document.segments[0].playbackEndTime == 1_000_000.0 / 16_000)

        // Inclusive start of the first range.
        #expect(document.segment(atPlaybackTime: 940_000.0 / 16_000)?.text == "跨片连续")
        // Sample inside the second range of the same utterance.
        #expect(document.segment(atPlaybackTime: 980_000.0 / 16_000)?.text == "跨片连续")
        // Half-open end: endSample itself is outside the segment window and
        // falls into the gap before the next utterance.
        #expect(document.segment(atPlaybackTime: 1_000_000.0 / 16_000)?.text == "跨片连续")
        // Deep gap before the later utterance still resolves to the prior one.
        #expect(document.segment(atPlaybackTime: 1_500_000.0 / 16_000)?.text == "跨片连续")
        #expect(document.segment(atPlaybackTime: 2_150_000.0 / 16_000)?.text == "间隙后")

        #expect(document.segmentsReferencing(sourceID: first).map(\.text) == ["跨片连续"])
        #expect(document.segmentsReferencing(sourceID: second).map(\.text) == ["跨片连续"])
        #expect(document.segmentForErrorLocation(sourceID: first)?.text == "跨片连续")
        #expect(document.segmentForErrorLocation(sourceID: second)?.text == "跨片连续")
        #expect(document.segmentForErrorLocation(sourceID: third)?.text == "间隙后")
        #expect(document.exportSourceIDs() == [first, second, third])
    }

    /// #49: model fail + retry must not invent duplicate segments, even when a
    /// second Recording is being captured in parallel.
    @Test func failedModelRetryDoesNotDuplicateSegmentsAcrossIsolatedRecordings() {
        let startedAt = Date(timeIntervalSince1970: 1_785_913_200)
        let older = Recording(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60),
            state: .processing
        )
        let newer = Recording(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            startedAt: startedAt.addingTimeInterval(120),
            state: .recording
        )
        let olderChunk = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
        let newerChunk = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001")!

        let olderChunks = [
            AudioChunk(
                id: olderChunk,
                recordingID: older.id,
                relativePath: "Recordings/older.m4a",
                startSample: 0,
                endSample: 960_000,
                startedAt: older.startedAt,
                endedAt: older.endedAt!
            ),
        ]
        var olderDoc = TranscriptDocumentV1(
            recording: older,
            chunks: olderChunks,
            segmentDrafts: [],
            language: "zh"
        )
        let draft = TranscriptDocumentV1.SegmentDraft(
            text: "重试成功",
            sourceRanges: [
                .init(sourceID: olderChunk, startSample: 16_000, endSample: 48_000),
            ]
        )
        olderDoc = olderDoc.appending(
            recording: older,
            chunks: olderChunks,
            draft: draft,
            replacingSourceIDs: [olderChunk]
        )
        olderDoc = olderDoc.appending(
            recording: older,
            chunks: olderChunks,
            draft: draft,
            replacingSourceIDs: [olderChunk]
        )
        #expect(olderDoc.segments.count == 1)
        #expect(olderDoc.segments[0].text == "重试成功")
        // Empty draft start is revision 1; each idempotent append bumps once.
        #expect(olderDoc.revision == 3)

        let newerDoc = TranscriptDocumentV1(
            recording: newer,
            chunks: [
                AudioChunk(
                    id: newerChunk,
                    recordingID: newer.id,
                    relativePath: "Recordings/newer.m4a",
                    startSample: 0,
                    endSample: 160_000,
                    startedAt: newer.startedAt,
                    endedAt: newer.startedAt.addingTimeInterval(10)
                ),
            ],
            segmentDrafts: [
                TranscriptDocumentV1.SegmentDraft(
                    text: "新录音片段",
                    sourceRanges: [
                        .init(sourceID: newerChunk, startSample: 0, endSample: 32_000),
                    ]
                ),
            ],
            language: "zh"
        )
        #expect(newerDoc.segments.map(\.text) == ["新录音片段"])
        #expect(Set(olderDoc.segments.map(\.id)).isDisjoint(with: Set(newerDoc.segments.map(\.id))))
        #expect(olderDoc.exportSourceIDs() == [olderChunk])
        #expect(newerDoc.exportSourceIDs() == [newerChunk])
    }

    @Test @MainActor func closedChunkEnqueuesWithoutWaitingForRecordingStop() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let capture = MockRecordingCapture()
        let coordinator = RecordingSessionCoordinator(
            repository: repository,
            capture: capture,
            lowStorageGuard: LowStorageGuard(minimumAvailableBytes: 1) { _ in 1_000 },
            enablesRemoteStopCommand: false
        )
        let enqueued = SchedulerChunkOrderProbe()
        coordinator.onChunkClosed = { _, chunkID in
            await enqueued.record(chunkID)
        }

        let recordingID = try await coordinator.start()
        let closed = AACSegmentRecorder.Segment(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            url: root.appendingPathComponent("Recordings/\(recordingID.uuidString)/minute.m4a"),
            startSample: 0,
            endSample: 960_000,
            startedAt: Date(timeIntervalSince1970: 1_785_913_200),
            endedAt: Date(timeIntervalSince1970: 1_785_913_260)
        )
        try FileManager.default.createDirectory(
            at: closed.url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0x00]).write(to: closed.url)
        capture.emitClosedSegment(closed)

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, await enqueued.chunkIDs.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(await enqueued.chunkIDs == [closed.id])
        #expect(coordinator.captureState == .recording)
        #expect(coordinator.activeRecordingID == recordingID)
        let chunks = try await repository.chunks(recordingID: recordingID)
        #expect(chunks.contains { $0.id == closed.id && $0.state == .closed })
    }

    @Test @MainActor func playerSurfacesReadableErrorInsteadOfSilentFailure() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Not a decodable AAC file: AVAudioPlayer refuses to load it.
        let url = root.appendingPathComponent("broken.m4a")
        try Data([0x00, 0xFF, 0xFE]).write(to: url)
        let startedAt = Date(timeIntervalSince1970: 1_785_913_200)
        let chunk = AudioChunk(
            recordingID: UUID(),
            relativePath: "broken.m4a",
            startSample: 0,
            endSample: 16_000,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(1)
        )
        let player = RecordingAudioTimelinePlayer()

        player.load(chunks: [chunk], rootURL: root)
        player.play()

        #expect(!player.isPlaying)
        #expect(player.playbackError != nil)
        #expect(player.residentPlayerCount == 0)
    }

    @Test @MainActor func playerWithNoPlayableChunksReportsItInsteadOfCrashing() throws {
        let player = RecordingAudioTimelinePlayer()

        player.load(chunks: [], rootURL: FileManager.default.temporaryDirectory)
        player.play()

        #expect(!player.isPlaying)
        #expect(player.playbackError != nil)
    }

    @Test @MainActor func longTimelineDoesNotKeepOneAudioPlayerPerChunkResident() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let relativePath = "fixture.m4a"
        let audioURL = root.appendingPathComponent(relativePath)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: AACSegmentRecorder.targetSampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        do {
            let file = try AVAudioFile(forWriting: audioURL, settings: settings)
            let format = try #require(AVAudioFormat(
                standardFormatWithSampleRate: AACSegmentRecorder.targetSampleRate,
                channels: 1
            ))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
            buffer.frameLength = 4_096
            buffer.floatChannelData![0].initialize(repeating: 0.2, count: Int(buffer.frameLength))
            try file.write(from: buffer)
        }

        let startedAt = Date(timeIntervalSince1970: 1_785_913_200)
        var chunks: [AudioChunk] = []
        for index in 0..<114 {
            let startSample = Int64(index) * 4_096
            let endSample = Int64(index + 1) * 4_096
            let chunkStartedAt = startedAt.addingTimeInterval(Double(index) * 0.256)
            let chunkEndedAt = startedAt.addingTimeInterval(Double(index + 1) * 0.256)
            chunks.append(AudioChunk(
                recordingID: UUID(),
                relativePath: relativePath,
                startSample: startSample,
                endSample: endSample,
                startedAt: chunkStartedAt,
                endedAt: chunkEndedAt
            ))
        }
        let player = RecordingAudioTimelinePlayer()

        player.load(chunks: chunks, rootURL: root)

        #expect(player.loadedItemCount == 114)
        #expect(player.residentPlayerCount <= 1)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingCoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    @MainActor
    private func presentationState(
        of coordinator: RecordingSessionCoordinator,
        becomes expected: RecordingSessionCoordinator.PresentationState,
        within timeout: TimeInterval = 5
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if coordinator.presentationState == expected { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return coordinator.presentationState == expected
    }

    private func makeStoredChunk(for recording: Recording, root: URL) async throws -> AudioChunk {
        let relativePath = "Recordings/\(recording.id.uuidString)/audio.m4a"
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x7F, count: 128).write(to: url)
        return AudioChunk(
            recordingID: recording.id,
            relativePath: relativePath,
            startSample: 0,
            endSample: 16_000,
            startedAt: recording.startedAt,
            endedAt: recording.startedAt.addingTimeInterval(1)
        )
    }

    @Test func cumulativeAudioDurationCalculatesFromSegmentsAcrossTimeGaps() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = try RecordingRepository(rootURL: root)
        let recordingID = UUID()
        let start = Date(timeIntervalSince1970: 1_785_900_000)
        let end = start.addingTimeInterval(8 * 3600)
        let recording = Recording(
            id: recordingID,
            startedAt: start,
            endedAt: end,
            state: .complete
        )
        try await repository.createRecording(recording, at: start)

        let chunk1 = AudioChunk(
            id: UUID(),
            recordingID: recordingID,
            relativePath: "Recordings/\(recordingID.uuidString.lowercased())/audio/chunk1.m4a",
            startSample: 0,
            endSample: 480_000,
            startedAt: start,
            endedAt: start.addingTimeInterval(30)
        )
        try await repository.addChunk(chunk1, at: start.addingTimeInterval(30))

        let chunk2 = AudioChunk(
            id: UUID(),
            recordingID: recordingID,
            relativePath: "Recordings/\(recordingID.uuidString.lowercased())/audio/chunk2.m4a",
            startSample: 480_000,
            endSample: 960_000,
            startedAt: end.addingTimeInterval(-30),
            endedAt: end
        )
        try await repository.addChunk(chunk2, at: end)

        let allDurations = try await repository.allAudioDurations()
        #expect(allDurations[recordingID] == 60.0)
    }

    @Test func recordingLocationPersistenceAndUpdating() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let startedAt = Date(timeIntervalSince1970: 1_785_913_200)
        let recording = Recording(
            startedAt: startedAt,
            title: "地点测试",
            locationName: "北京市海淀区中关村南大街1号"
        )
        try await repository.createRecording(recording, at: startedAt)

        let loaded = try await repository.recording(id: recording.id)
        #expect(loaded?.locationName == "北京市海淀区中关村南大街1号")

        try await repository.setRecordingLocation(
            recordingID: recording.id,
            locationName: "上海市浦东新区张江高科技园区",
            at: startedAt.addingTimeInterval(10)
        )
        let updated = try await repository.recording(id: recording.id)
        #expect(updated?.locationName == "上海市浦东新区张江高科技园区")

        try await repository.setRecordingLocation(
            recordingID: recording.id,
            locationName: "",
            at: startedAt.addingTimeInterval(20)
        )
        let cleared = try await repository.recording(id: recording.id)
        #expect(cleared?.locationName == nil)
    }

    @Test func atomicClaimAllowsOnlyOneGlobalLeaseAndRejectsLateCompletion() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repositoryA = try RecordingRepository(rootURL: root)
        let repositoryB = try RecordingRepository(rootURL: root)
        let date = Date(timeIntervalSince1970: 1_785_913_200)
        let recording = Recording(startedAt: date, state: .processing)
        try await repositoryA.createRecording(recording, at: date)
        let first = RecordingJob(
            recordingID: recording.id,
            chunkID: UUID(),
            kind: .transcription,
            state: .pending,
            attemptCount: 0,
            lastError: nil,
            createdAt: date,
            updatedAt: date
        )
        let second = RecordingJob(
            recordingID: recording.id,
            chunkID: UUID(),
            kind: .transcription,
            state: .pending,
            attemptCount: 0,
            lastError: nil,
            createdAt: date.addingTimeInterval(1),
            updatedAt: date.addingTimeInterval(1)
        )
        try await repositoryA.upsertJob(first, at: date)
        try await repositoryA.upsertJob(second, at: date.addingTimeInterval(1))

        async let claimA = repositoryA.claimTranscriptionJob(id: first.id, at: date.addingTimeInterval(2))
        async let claimB = repositoryB.claimTranscriptionJob(id: second.id, at: date.addingTimeInterval(2))
        let leases = try await [claimA, claimB].compactMap { $0 }
        let lease = try #require(leases.first)
        #expect(leases.count == 1)
        #expect(try await repositoryA.validateExecutionLease(lease))

        _ = try await repositoryA.finishExecutionLease(
            lease,
            state: .pending,
            lastError: "backgroundTaskExpired",
            terminationReason: "backgroundTaskExpired",
            at: date.addingTimeInterval(3)
        )
        #expect(try await repositoryA.validateExecutionLease(lease) == false)
        #expect(try await repositoryA.finishExecutionLease(
            lease,
            state: .completed,
            at: date.addingTimeInterval(4)
        ) == nil)
    }

    @Test func completionReconcilerBackfillsFinalizationAndRepairsLostCompletionCallback() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let transcriptStore = try TranscriptDocumentStore(rootURL: root)
        let reconciler = CompletionReconciler(repository: repository, transcriptStore: transcriptStore)
        let startedAt = Date(timeIntervalSince1970: 1_785_913_200)
        let recording = Recording(
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60),
            isMeeting: true,
            state: .processing
        )
        try await repository.createRecording(recording, at: startedAt)
        try await repository.upsertJob(RecordingJob(
            recordingID: recording.id,
            chunkID: UUID(),
            kind: .transcription,
            state: .completed,
            attemptCount: 1,
            lastError: nil,
            createdAt: startedAt,
            updatedAt: startedAt.addingTimeInterval(10)
        ), at: startedAt.addingTimeInterval(10))

        let firstPass = try await reconciler.reconcile(
            recordingID: recording.id,
            at: startedAt.addingTimeInterval(11)
        )
        guard case let .needsSpeakerFinalization(finalizationID) = firstPass else {
            Issue.record("expected finalization backfill")
            return
        }
        #expect(try await repository.recording(id: recording.id)?.state == .processing)

        var finalization = try #require(await repository.jobs(recordingID: recording.id)
            .first { $0.id == finalizationID })
        finalization.state = .completed
        finalization.attemptCount = 1
        finalization.updatedAt = startedAt.addingTimeInterval(12)
        try await repository.upsertJob(finalization, at: finalization.updatedAt)

        #expect(try await reconciler.reconcile(
            recordingID: recording.id,
            at: startedAt.addingTimeInterval(13)
        ) == .completed)
        #expect(try await repository.recording(id: recording.id)?.state == .complete)
        #expect(try await transcriptStore.document(recordingID: recording.id)?.state
            == RecordingState.complete.rawValue)
    }

    @Test func realDeviceStaleSpeakerFinalizationRecoversToPendingWithoutHidingTranscriptProgress() async throws {
        struct DeviceSnapshot: Decodable {
            struct Finalization: Decodable {
                let state: String
                let attemptCount: Int

                enum CodingKeys: String, CodingKey {
                    case state
                    case attemptCount = "attempt_count"
                }
            }

            let recordingState: String
            let transcriptionJobCount: Int
            let completedTranscriptionJobCount: Int
            let speakerFinalization: Finalization

            enum CodingKeys: String, CodingKey {
                case recordingState = "recording_state"
                case transcriptionJobCount = "transcription_job_count"
                case completedTranscriptionJobCount = "completed_transcription_job_count"
                case speakerFinalization = "speaker_finalization"
            }
        }

        let fixtureURL = try #require(Bundle(for: SpeechNoteTestsBundleToken.self).url(
            forResource: "stale_speaker_finalization_device_snapshot",
            withExtension: "json"
        ))
        let snapshot = try JSONDecoder().decode(
            DeviceSnapshot.self,
            from: Data(contentsOf: fixtureURL)
        )
        #expect(snapshot.recordingState == RecordingState.processing.rawValue)
        #expect(snapshot.transcriptionJobCount == snapshot.completedTranscriptionJobCount)
        #expect(snapshot.speakerFinalization.state == RecordingJobState.running.rawValue)

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
        let staleStartedAt = startedAt.addingTimeInterval(-8_000)
        try await repository.upsertJob(RecordingJob(
            recordingID: recording.id,
            kind: .speakerFinalization,
            state: .running,
            attemptCount: snapshot.speakerFinalization.attemptCount,
            lastError: nil,
            executionToken: UUID(),
            startedAt: staleStartedAt,
            createdAt: staleStartedAt,
            updatedAt: staleStartedAt
        ), at: staleStartedAt)

        _ = try await repository.recoverUnfinished(at: startedAt.addingTimeInterval(60))

        let jobs = try await repository.jobs(recordingID: recording.id)
        let finalization = try #require(jobs.first { $0.kind == .speakerFinalization })
        #expect(finalization.state == .pending)
        #expect(finalization.executionToken == nil)
        #expect(finalization.startedAt == nil)
        #expect(finalization.lastError == "recoveredAfterTermination")
        #expect(try await repository.recording(id: recording.id)?.state == .processing)
        #expect(RecordingProcessingState.resolve(
            legacyRecordingState: .processing,
            jobs: jobs
        ) == .speakerFinalization)
    }

    @Test func diskReconciliationRestoresMissingChunksAndSampleRanges() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let startedAt = Date(timeIntervalSince1970: 1_785_913_200)
        let recording = Recording(startedAt: startedAt, state: .recording)
        try await repository.createRecording(recording, at: startedAt)

        let chunk1ID = UUID()
        let chunk2ID = UUID()
        let chunk3ID = UUID()
        let recFolder = root.appendingPathComponent("Recordings/\(recording.id.uuidString.lowercased())/audio")
        let dir00 = recFolder.appendingPathComponent("00/00")
        let dir01 = recFolder.appendingPathComponent("00/01")
        let dir02 = recFolder.appendingPathComponent("00/02")
        try FileManager.default.createDirectory(at: dir00, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir01, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir02, withIntermediateDirectories: true)

        let file1 = dir00.appendingPathComponent("audio-\(chunk1ID.uuidString.lowercased()).m4a")
        let file2 = dir01.appendingPathComponent("audio-\(chunk2ID.uuidString.lowercased()).m4a")
        let file3 = dir02.appendingPathComponent("audio-\(chunk3ID.uuidString.lowercased()).m4a")
        try Data(repeating: 0x55, count: 4000).write(to: file1)
        try Data(repeating: 0x55, count: 4000).write(to: file2)
        try Data(repeating: 0x55, count: 4000).write(to: file3)

        let restored = try await repository.reconcileChunksFromDisk(recordingID: recording.id)
        #expect(restored.count == 3)

        let indexedChunks = try await repository.chunks(recordingID: recording.id)
            .sorted { $0.startSample < $1.startSample }
        #expect(indexedChunks.count == 3)
        #expect(indexedChunks[0].id == chunk1ID)
        #expect(indexedChunks[1].id == chunk2ID)
        #expect(indexedChunks[2].id == chunk3ID)
        #expect(indexedChunks[0].startSample == 0)
        #expect(indexedChunks[1].startSample == indexedChunks[0].endSample)
        #expect(indexedChunks[2].startSample == indexedChunks[1].endSample)
    }

    @Test func recoverUnfinishedPerformsDiskReconciliationAndTransitionsState() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let startedAt = Date(timeIntervalSince1970: 1_785_913_200)
        let recording = Recording(startedAt: startedAt, state: .recording)
        try await repository.createRecording(recording, at: startedAt)

        let chunkID = UUID()
        let recFolder = root.appendingPathComponent("Recordings/\(recording.id.uuidString.lowercased())/audio/00/00")
        try FileManager.default.createDirectory(at: recFolder, withIntermediateDirectories: true)
        let file = recFolder.appendingPathComponent("audio-\(chunkID.uuidString.lowercased()).m4a")
        try Data(repeating: 0x55, count: 4000).write(to: file)

        let result = try await repository.recoverUnfinished(at: startedAt.addingTimeInterval(60))
        #expect(result.interruptedRecordingIDs.contains(recording.id))

        let updated = try #require(await repository.recording(id: recording.id))
        #expect(updated.state == .interrupted)
        #expect(updated.endedAt != nil)
        let chunks = try await repository.chunks(recordingID: recording.id)
        #expect(chunks.count == 1)
        #expect(chunks[0].id == chunkID)
    }
}

final class SpeechNoteTestsBundleToken: NSObject {}

private enum SchedulerTestError: LocalizedError {
    case noSpeech

    var errorDescription: String? { "Silero VAD 未形成语音片段" }
}

private actor SchedulerExecutorProbe {
    private(set) var recordingIDs: [UUID] = []

    func record(_ recordingID: UUID) {
        recordingIDs.append(recordingID)
    }
}

private actor SchedulerOutcomeProbe {
    private(set) var values: [ForegroundTranscriptionScheduler.Outcome] = []

    func record(_ outcome: ForegroundTranscriptionScheduler.Outcome) {
        values.append(outcome)
    }
}

private actor MetalHoldBarrier {
    func holdBriefly() async {
        try? await Task.sleep(for: .milliseconds(15))
    }
}

private actor SchedulerChunkOrderProbe {
    private(set) var chunkIDs: [UUID] = []

    func record(_ chunkID: UUID) {
        chunkIDs.append(chunkID)
    }
}

/// Sync box so `TranscriptionAdmissionPolicy` can sample thermal state without
/// crossing an actor boundary from its synchronous evaluator.
private final class ThermalStateProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var state: ProcessInfo.ThermalState

    init(initial: ProcessInfo.ThermalState) {
        state = initial
    }

    func current() -> ProcessInfo.ThermalState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func set(_ state: ProcessInfo.ThermalState) {
        lock.lock()
        defer { lock.unlock() }
        self.state = state
    }
}

private actor ChunkPersistenceProbe {
    enum Error: LocalizedError, Equatable {
        case injected

        var errorDescription: String? { "测试注入的 chunk 持久化失败" }
    }

    private let repository: RecordingRepository
    private var failuresRemaining: Int
    private(set) var attemptedChunkIDs: [UUID] = []

    init(repository: RecordingRepository, failuresRemaining: Int) {
        self.repository = repository
        self.failuresRemaining = failuresRemaining
    }

    func persist(_ chunk: AudioChunk, at date: Date) async throws {
        attemptedChunkIDs.append(chunk.id)
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw Error.injected
        }
        try await repository.addChunk(chunk, at: date)
    }
}

@MainActor
private final class MutableTestClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}

@MainActor
private final class MockRecordingCapture: RecordingCapturing {
    var onSegmentClosed: (@Sendable (AACSegmentRecorder.Segment) -> Void)?
    var onCaptureEvent: (@Sendable (AACSegmentRecorder.CaptureEvent) -> Void)?
    var currentSample: Int64 = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var cancelCount = 0
    private(set) var segmentDurations: [TimeInterval] = []
    var emitsSegmentClosedOnStop = true
    private(set) var lastStoppedSegment: AACSegmentRecorder.Segment?
    private var directory: URL?

    func start(in directory: URL, segmentDuration: TimeInterval, initialSampleOffset: Int64 = 0) async throws {
        self.directory = directory
        startCount += 1
        segmentDurations.append(segmentDuration)
    }

    func pause() throws {}

    func resume() throws {}

    func cancel() {
        cancelCount += 1
    }

    func stop() throws -> AACSegmentRecorder.Segment {
        stopCount += 1
        let segment = AACSegmentRecorder.Segment(
            id: UUID(),
            url: (directory ?? FileManager.default.temporaryDirectory)
                .appendingPathComponent("mock.m4a"),
            startSample: 0,
            endSample: currentSample,
            startedAt: Date(timeIntervalSince1970: 1_785_913_200),
            endedAt: Date(timeIntervalSince1970: 1_785_913_203)
        )
        lastStoppedSegment = segment
        if emitsSegmentClosedOnStop {
            onSegmentClosed?(segment)
        }
        return segment
    }

    func emit(_ event: AACSegmentRecorder.CaptureEvent) {
        onCaptureEvent?(event)
    }

    func emitClosedSegment(_ segment: AACSegmentRecorder.Segment) {
        onSegmentClosed?(segment)
    }
}
