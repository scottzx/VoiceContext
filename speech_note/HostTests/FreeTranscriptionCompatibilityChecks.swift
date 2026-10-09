import Foundation

enum FreeTranscriptionCompatibilityChecks {
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("yima-free-transcription-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let recording = Recording(startedAt: date, endedAt: date.addingTimeInterval(1),
                                  speakerProcessingEnabled: false, state: .processing)
        let chunk = AudioChunk(recordingID: recording.id, relativePath: "saved-audio.m4a",
                               startSample: 0, endSample: 16_000, startedAt: date,
                               endedAt: date.addingTimeInterval(1))
        let job = RecordingJob(recordingID: recording.id, chunkID: chunk.id,
                               kind: .transcription, state: .pending, attemptCount: 0,
                               lastError: "lockedPendingPurchase", createdAt: date, updatedAt: date)
        let original = try RecordingRepository(rootURL: root)
        try await original.createRecording(recording, at: date)
        try await original.addChunk(chunk, at: date)
        try await original.upsertJob(job, at: date)
        let audioURL = root.appendingPathComponent(chunk.relativePath)
        let audioBytes = Data("preserved historical audio".utf8)
        try audioBytes.write(to: audioURL)
        let store = try TranscriptDocumentStore(rootURL: root)
        let document = TranscriptDocumentV1(recording: recording, chunks: [chunk],
                                            segmentTexts: [(chunk.id, "已经保存的文稿")])
        try await store.write(document)
        let transcriptURL = root.appendingPathComponent("Transcripts/\(recording.id.uuidString).json")
        let transcriptBytes = try Data(contentsOf: transcriptURL)

        // An expired/unpurchased old installation upgrades by retaining pending
        // rows and their sources, without importing or rewriting a trial ledger.
        let reloaded = try RecordingRepository(rootURL: root)
        _ = try await reloaded.replayJournal()
        let pending = try await reloaded.jobs(recordingID: recording.id)
        precondition(pending == [job])
        precondition(RecordingProcessingState.resolve(legacyRecordingState: .processing, jobs: pending) == .queued)
        let legacy = try JSONDecoder().decode(RecordingProcessingState.self,
                                             from: Data("\"lockedPendingPurchase\"".utf8))
        precondition(legacy == .lockedPendingPurchase)

        let readiness = FreeTranscriptionModelReadiness()
        let executions = FreeTranscriptionExecutionProbe()
        let scheduler = ForegroundTranscriptionScheduler(
            repository: reloaded,
            admissionPolicy: TranscriptionAdmissionPolicy(isModelReady: { readiness.isReady })
        ) { lease in
            await executions.record(lease.jobID)
        }
        try await scheduler.resumePendingJobs { _ in }
        await scheduler.waitForIdle()
        let waiting = try await reloaded.jobs(recordingID: recording.id)
        precondition(waiting.count == 1 && waiting[0].state == .pending)
        precondition(waiting[0].lastError == "modelsNotReady")
        let executionsBeforeDownload = await executions.ids
        precondition(executionsBeforeDownload.isEmpty)

        readiness.markReady()
        await scheduler.requestDrain()
        await scheduler.waitForIdle()
        let completed = try await reloaded.jobs(recordingID: recording.id)
        precondition(completed.count == 1 && completed[0].id == job.id)
        precondition(completed[0].state == .completed && completed[0].lastError == nil)
        precondition(completed[0].attemptCount == 1)
        let completedExecutionIDs = await executions.ids
        let preservedAudio = try Data(contentsOf: audioURL)
        let preservedTranscript = try Data(contentsOf: transcriptURL)
        precondition(completedExecutionIDs == [job.id])
        precondition(preservedAudio == audioBytes)
        precondition(preservedTranscript == transcriptBytes)
        print("PASS: historical purchase-locked jobs resume for free after models are ready; audio and transcript bytes preserved")

        let coldRepository = try RecordingRepository(rootURL: root.appendingPathComponent("cold-background"))
        try await coldRepository.createRecording(recording, at: date)
        try await coldRepository.upsertJob(job, at: date)
        let coldExecutions = FreeTranscriptionExecutionProbe()
        let coldScheduler = ForegroundTranscriptionScheduler(
            repository: coldRepository,
            admissionPolicy: TranscriptionAdmissionPolicy(isModelReady: { true }),
            initiallyInBackground: true
        ) { lease in
            await coldExecutions.record(lease.jobID)
        }
        try await coldScheduler.resumePendingJobs { _ in }
        await coldScheduler.requestDrain()
        await coldScheduler.waitForIdle()
        let backgroundExecutionIDs = await coldExecutions.ids
        let backgroundJobs = try await coldRepository.jobs(recordingID: recording.id)
        precondition(backgroundExecutionIDs.isEmpty)
        precondition(backgroundJobs.count == 1 && backgroundJobs[0].state == .pending)
        precondition(backgroundJobs[0].attemptCount == 0)

        await coldScheduler.enteredForeground()
        await coldScheduler.waitForIdle()
        await coldScheduler.enteredForeground()
        await coldScheduler.requestDrain()
        await coldScheduler.waitForIdle()
        let foregroundExecutionIDs = await coldExecutions.ids
        let foregroundJobs = try await coldRepository.jobs(recordingID: recording.id)
        precondition(foregroundExecutionIDs == [job.id])
        precondition(foregroundJobs.count == 1 && foregroundJobs[0].state == .completed)
        precondition(foregroundJobs[0].attemptCount == 1)
        print("PASS: models ready during cold background launch do not execute; foreground resumes the job exactly once")

        let recoveringRepository = try RecordingRepository(rootURL: root.appendingPathComponent("initial-recovery"))
        try await recoveringRepository.createRecording(recording, at: date)
        try await recoveringRepository.upsertJob(job, at: date)
        let recoveringExecutions = FreeTranscriptionExecutionProbe()
        let recoveringScheduler = ForegroundTranscriptionScheduler(
            repository: recoveringRepository,
            admissionPolicy: TranscriptionAdmissionPolicy(isModelReady: { true }),
            requiresInitialRecovery: true
        ) { lease in
            await recoveringExecutions.record(lease.jobID)
        }
        await recoveringScheduler.enteredForeground()
        await recoveringScheduler.requestDrain()
        await recoveringScheduler.waitForIdle()
        let executionsBeforeRecovery = await recoveringExecutions.ids
        let jobsBeforeRecovery = try await recoveringRepository.jobs(recordingID: recording.id)
        precondition(executionsBeforeRecovery.isEmpty)
        precondition(jobsBeforeRecovery.count == 1 && jobsBeforeRecovery[0].state == .pending)
        precondition(jobsBeforeRecovery[0].attemptCount == 0)

        try await recoveringScheduler.resumePendingJobs { _ in }
        await recoveringScheduler.waitForIdle()
        await recoveringScheduler.enteredForeground()
        await recoveringScheduler.requestDrain()
        await recoveringScheduler.waitForIdle()
        let executionsAfterRecovery = await recoveringExecutions.ids
        let jobsAfterRecovery = try await recoveringRepository.jobs(recordingID: recording.id)
        precondition(executionsAfterRecovery == [job.id])
        precondition(jobsAfterRecovery.count == 1 && jobsAfterRecovery[0].state == .completed)
        precondition(jobsAfterRecovery[0].attemptCount == 1)
        print("PASS: early foreground notifications cannot execute before initial recovery; recovery resumes the job exactly once")
    }
}

private nonisolated final class FreeTranscriptionModelReadiness: @unchecked Sendable {
    private let lock = NSLock()
    private var ready = false

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ready
    }

    func markReady() {
        lock.lock()
        defer { lock.unlock() }
        ready = true
    }
}

private actor FreeTranscriptionExecutionProbe {
    private(set) var ids: [UUID] = []
    func record(_ id: UUID) { ids.append(id) }
}
