import Foundation

enum RecordingTranscriptionDeferralChecks {
    actor Executions {
        private(set) var count = 0

        func run(interruptFirst: Bool) async throws {
            count += 1
            if interruptFirst, count == 1 {
                try await Task.sleep(for: .seconds(60))
            }
        }
    }

    actor NativeExecution {
        private(set) var count = 0
        private var first: CheckedContinuation<Void, Never>?
        private var second: CheckedContinuation<Void, Never>?

        func run() async {
            count += 1
            if count == 1 {
                // Like a detached/native call, this ignores parent cancellation.
                await withCheckedContinuation { first = $0 }
            } else {
                second?.resume()
                second = nil
            }
        }

        func finishFirst() { first?.resume(); first = nil }

        func waitForSecond() async {
            guard count < 2 else { return }
            await withCheckedContinuation { second = $0 }
        }
    }

    static func run() async throws {
        try await defersNewAndHistoricalJobsUntilCaptureStops()
        try await suspendsAndRetriesRunningJobWithoutLosingAudio()
        try await startsCaptureWithoutWaitingForNativeASR()
        print("PASS: capture defers all ASR, background grants cannot bypass it, interrupted ASR remains retryable")
    }

    static func defersNewAndHistoricalJobsUntilCaptureStops() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let old = Recording(startedAt: .distantPast, state: .processing)
        let current = Recording(startedAt: Date())
        try await repository.createRecording(old, at: old.startedAt)
        try await repository.createRecording(current, at: current.startedAt)
        let executions = Executions()
        let scheduler = ForegroundTranscriptionScheduler(repository: repository) { _ in
            try await executions.run(interruptFirst: false)
        }
        await scheduler.setCaptureActive(true)
        try await scheduler.enqueue(recordingID: old.id, chunkID: UUID()) { _ in }
        try await scheduler.enqueue(recordingID: current.id, chunkID: UUID()) { _ in }
        await scheduler.enteredBackground()
        await scheduler.setContinuedBackgroundExecutionAllowed(true)
        await scheduler.requestDrain()
        await scheduler.waitForIdle()
        let before = await scheduler.queueSnapshot()
        let countBefore = await executions.count
        precondition(countBefore == 0 && before.pending == 2 && before.running == 0)
        let currentRecording = try await repository.recording(id: current.id)
        precondition(currentRecording?.state == .recording)

        // The same durable queue handles a stop from the app or Lock Screen.
        await scheduler.setCaptureActive(false)
        await scheduler.waitForIdle()
        let after = await scheduler.queueSnapshot()
        let countAfter = await executions.count
        precondition(countAfter == 2 && after.completed == 2 && after.pending == 0)
    }

    static func suspendsAndRetriesRunningJobWithoutLosingAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let recording = Recording(startedAt: Date(), state: .processing)
        try await repository.createRecording(recording, at: recording.startedAt)
        let chunk = AudioChunk(
            recordingID: recording.id, relativePath: "saved-audio.m4a",
            startSample: 0, endSample: 16_000,
            startedAt: recording.startedAt,
            endedAt: recording.startedAt.addingTimeInterval(1)
        )
        try await repository.addChunk(chunk, at: chunk.endedAt)
        let chunksBeforeCapture = try await repository.chunks(recordingID: recording.id)
        let executions = Executions()
        let scheduler = ForegroundTranscriptionScheduler(repository: repository) { _ in
            try await executions.run(interruptFirst: true)
        }
        try await scheduler.enqueue(recordingID: recording.id, chunkID: chunk.id) { _ in }
        while await executions.count == 0 { await Task.yield() }

        await scheduler.setCaptureActive(true)
        let pending = try await repository.jobs(recordingID: recording.id)
        precondition(pending.count == 1 && pending[0].state == .pending)
        precondition(pending[0].terminationReason == "deferredUntilRecordingStops")
        precondition(pending[0].executionToken == nil && pending[0].attemptCount == 1)
        let savedChunks = try await repository.chunks(recordingID: recording.id)
        precondition(savedChunks == chunksBeforeCapture, "Deferring ASR must preserve saved audio metadata")

        await scheduler.setCaptureActive(false)
        await scheduler.waitForIdle()
        let finished = try await repository.jobs(recordingID: recording.id)
        precondition(finished[0].state == .completed && finished[0].attemptCount == 2)
    }

    static func startsCaptureWithoutWaitingForNativeASR() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let recording = Recording(startedAt: Date(), state: .processing)
        try await repository.createRecording(recording, at: recording.startedAt)
        let native = NativeExecution()
        let scheduler = ForegroundTranscriptionScheduler(repository: repository) { _ in
            await native.run()
        }
        try await scheduler.enqueue(recordingID: recording.id, chunkID: UUID()) { _ in }
        while await native.count == 0 { await Task.yield() }
        await scheduler.setCaptureActive(true)
        let jobs = try await repository.jobs(recordingID: recording.id)
        precondition(jobs.first?.state == .pending, "Capture can start while native ASR winds down")

        // A quick stop must restart the durable queue after the old worker exits.
        await scheduler.setCaptureActive(false)
        await native.finishFirst()
        await native.waitForSecond()
        await scheduler.waitForIdle()
        let finished = try await repository.jobs(recordingID: recording.id)
        precondition(finished.first?.state == .completed && finished.first?.attemptCount == 2)
        print("PASS: capture does not wait for native ASR; quick stop resumes ASR without parallel workers")
    }
}
