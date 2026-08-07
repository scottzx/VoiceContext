import Foundation
import Testing
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
            updatedAt: startedAt.addingTimeInterval(12)
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

        #expect(index.schemaVersion == 1)
        #expect(index.appliedEventCount == 0)
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

        _ = try await repository.recoverUnfinished(at: startedAt.addingTimeInterval(20))

        let job = try #require(await repository.jobs(recordingID: processing.id).first)
        #expect(job.kind == .transcription)
        #expect(job.state == .pending)
        #expect(job.attemptCount == 0)
    }

    @Test func foregroundSchedulerCompletesShortRecordingAndPersistsItsJob() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let recording = Recording(startedAt: .distantPast, state: .processing)
        try await repository.createRecording(recording, at: recording.startedAt)
        let executor = SchedulerExecutorProbe()
        let outcomes = SchedulerOutcomeProbe()
        let scheduler = ForegroundTranscriptionScheduler(repository: repository) { recordingID in
            await executor.record(recordingID)
        }

        try await scheduler.enqueue(recordingID: recording.id) { outcome in
            await outcomes.record(outcome)
        }
        await scheduler.waitForIdle()

        #expect(await executor.recordingIDs == [recording.id])
        let jobs = try await repository.jobs(recordingID: recording.id)
        #expect(jobs.count == 1)
        #expect(jobs[0].state == .completed)
        #expect(jobs[0].attemptCount == 1)
        #expect(await outcomes.values == [.init(recordingID: recording.id, state: .completed)])
    }

    @Test func schedulerLeavesNoSpeechFailureVisibleAndRetryable() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let recording = Recording(startedAt: .distantPast, state: .processing)
        try await repository.createRecording(recording, at: recording.startedAt)
        let outcomes = SchedulerOutcomeProbe()
        let scheduler = ForegroundTranscriptionScheduler(repository: repository) { _ in
            throw SchedulerTestError.noSpeech
        }

        try await scheduler.enqueue(recordingID: recording.id) { outcome in
            await outcomes.record(outcome)
        }
        await scheduler.waitForIdle()

        let failedJob = try #require(await repository.jobs(recordingID: recording.id).first)
        #expect(failedJob.state == .failed)
        #expect(failedJob.attemptCount == 1)
        #expect(failedJob.lastError == SchedulerTestError.noSpeech.localizedDescription)
        #expect(await outcomes.values == [.init(
            recordingID: recording.id,
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
        let scheduler = ForegroundTranscriptionScheduler(repository: repository) { recordingID in
            await executor.record(recordingID)
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

    @Test func twoHourSegmentationHasExactContinuousFiveMinuteBoundaries() {
        let sampleRate: Int64 = 16_000
        let segmentLength = 5 * 60 * sampleRate
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
        #expect(closedBoundaries.count == 24)
        #expect(closedBoundaries == (1...24).map { Int64($0) * segmentLength })
        #expect(planner.currentSegmentStartSample == totalFrames)
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
        #expect(coordinator.presentationState == .processing)
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
}

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

@MainActor
private final class MockRecordingCapture: RecordingCapturing {
    var onSegmentClosed: (@Sendable (AACSegmentRecorder.Segment) -> Void)?
    var onCaptureEvent: (@Sendable (AACSegmentRecorder.CaptureEvent) -> Void)?
    var currentSample: Int64 = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var directory: URL?

    func start(in directory: URL, segmentDuration: TimeInterval) async throws {
        self.directory = directory
        startCount += 1
    }

    func pause() throws {}

    func resume() throws {}

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
        onSegmentClosed?(segment)
        return segment
    }

    func emit(_ event: AACSegmentRecorder.CaptureEvent) {
        onCaptureEvent?(event)
    }
}
