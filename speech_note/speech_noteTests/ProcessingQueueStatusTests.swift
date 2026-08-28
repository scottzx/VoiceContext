import Foundation
import Testing
@testable import speech_note

@MainActor
struct ProcessingQueueStatusTests {
    @Test func completedTasksGroupByRecordingWithOrderedStageChildren() throws {
        let recordingID = UUID()
        let transcriptionTime = Date(timeIntervalSince1970: 1_787_599_000)
        let speakerTime = transcriptionTime.addingTimeInterval(30)
        let progress = ProcessingStageProgress(
            completed: 2,
            total: 2,
            running: 0,
            pending: 0,
            failed: 0,
            cancelled: 0
        )
        var status = TranscriptionQueueStatus()
        status.completedTasks = [
            RecordingProcessingTaskItem(
                id: "\(recordingID.uuidString)-speakerProcessing",
                recordingID: recordingID,
                recordingTitle: "产品复盘会议",
                stage: .speakerProcessing,
                state: .completed,
                progress: progress,
                speakerFinalizationState: .completed,
                dependencyMessage: nil,
                lastError: nil,
                updatedAt: speakerTime
            ),
            RecordingProcessingTaskItem(
                id: "\(recordingID.uuidString)-transcription",
                recordingID: recordingID,
                recordingTitle: "产品复盘会议",
                stage: .transcription,
                state: .completed,
                progress: progress,
                speakerFinalizationState: nil,
                dependencyMessage: nil,
                lastError: nil,
                updatedAt: transcriptionTime
            )
        ]

        let group = try #require(status.completedRecordingGroups.first)
        #expect(status.completedRecordingGroups.count == 1)
        #expect(group.recordingTitle == "产品复盘会议")
        #expect(group.tasks.map(\.stage) == [.transcription, .speakerProcessing])
        #expect(group.tasks.map(\.progress.completed) == [2, 2])
        #expect(group.tasks.map(\.updatedAt) == [transcriptionTime, speakerTime])
    }

    @Test func queueAggregatesEachRecordingIntoTwoStageCounts() async throws {
        let root = temporaryQueueDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try RecordingCoreModel(rootURL: root)
        let now = Date(timeIntervalSince1970: 1_787_600_000)
        let meeting = Recording(
            startedAt: now,
            endedAt: now.addingTimeInterval(120),
            title: "52 分段会议",
            isMeeting: true,
            state: .processing
        )
        try await model.repository.createRecording(meeting, at: now)
        for (index, state) in [RecordingJobState.completed, .running].enumerated() {
            try await model.repository.upsertJob(RecordingJob(
                recordingID: meeting.id,
                chunkID: UUID(),
                kind: .transcription,
                state: state,
                attemptCount: state == .pending ? 0 : 1,
                lastError: nil,
                createdAt: now,
                updatedAt: now.addingTimeInterval(Double(index))
            ), at: now)
        }
        try await model.repository.upsertJob(RecordingJob(
            recordingID: meeting.id,
            chunkID: UUID(),
            kind: .speakerEmbedding,
            state: .completed,
            attemptCount: 1,
            lastError: nil,
            createdAt: now,
            updatedAt: now
        ), at: now)

        let status = await model.fetchTranscriptionQueueStatus()
        let transcription = try #require(status.runningTasks.first {
            $0.recordingID == meeting.id && $0.stage == .transcription
        })
        let speaker = try #require(status.todoTasks.first {
            $0.recordingID == meeting.id && $0.stage == .speakerProcessing
        })
        #expect(transcription.progress.completed == 1)
        #expect(transcription.progress.total == 2)
        #expect(speaker.progress.completed == 1)
        #expect(speaker.progress.total == 2)
        #expect(speaker.dependencyMessage == "等待逐字稿识别完成")
    }

    @Test func personalRecordingIsCompleteWhenASRCompletesAndSpeakerStageIsSkipped() async throws {
        let root = temporaryQueueDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try RecordingCoreModel(rootURL: root)
        let now = Date(timeIntervalSince1970: 1_787_601_000)
        let recording = Recording(
            startedAt: now,
            endedAt: now.addingTimeInterval(30),
            isMeeting: false,
            state: .complete
        )
        try await model.repository.createRecording(recording, at: now)
        try await model.repository.upsertJob(RecordingJob(
            recordingID: recording.id,
            kind: .transcription,
            state: .completed,
            attemptCount: 1,
            lastError: nil,
            createdAt: now,
            updatedAt: now
        ), at: now)

        let status = await model.fetchTranscriptionQueueStatus()
        let item = try #require(status.completedTasks.first)
        #expect(item.recordingID == recording.id)
        #expect(item.stage == .transcription)
        #expect(status.completedTasks.count == 1)
    }

    @Test func stopAllMovesASRAndSpeakerWorkIntoTheCancelledList() async throws {
        let root = temporaryQueueDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try RecordingCoreModel(rootURL: root)
        let now = Date(timeIntervalSince1970: 1_787_602_000)
        let recording = Recording(
            startedAt: now,
            endedAt: now.addingTimeInterval(30),
            title: "待关停会议",
            isMeeting: true,
            state: .processing
        )
        try await model.repository.createRecording(recording, at: now)
        for (kind, state) in [
            (RecordingJobKind.transcription, RecordingJobState.pending),
            (.speakerEmbedding, .failed),
            (.speakerFinalization, .failed)
        ] {
            try await model.repository.upsertJob(RecordingJob(
                recordingID: recording.id,
                chunkID: kind == .speakerFinalization ? nil : UUID(),
                kind: kind,
                state: state,
                attemptCount: state == .pending ? 0 : 1,
                lastError: state == .failed ? "音频不可用" : nil,
                createdAt: now,
                updatedAt: now
            ), at: now)
        }

        await model.stopAllTranscriptionJobs()
        await model.forceReconcileAndResume()

        let status = await model.fetchTranscriptionQueueStatus()
        let cancelled = status.cancelledTasks.filter { $0.recordingID == recording.id }
        #expect(cancelled.count == 2)
        #expect(status.todoTasks.isEmpty)
        #expect(status.runningTasks.isEmpty)
        #expect(status.failedTasks.isEmpty)
        #expect(cancelled.first { $0.stage == .transcription }?.progress.cancelled == 1)
        #expect(cancelled.first { $0.stage == .speakerProcessing }?.progress.cancelled == 1)
        #expect(cancelled.first {
            $0.stage == .speakerProcessing
        }?.speakerFinalizationState == .cancelled)

        let persistedJobs = try await model.repository.jobs(recordingID: recording.id)
        #expect(persistedJobs.allSatisfy { $0.state == .cancelled })
    }

    @Test func stopAllCancelsSixteenMeetingsWhoseSpeakerStagesHaveNotBeenMaterialized() async throws {
        let root = temporaryQueueDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try RecordingCoreModel(rootURL: root)
        let now = Date(timeIntervalSince1970: 1_787_602_500)
        var recordingIDs: [UUID] = []
        for index in 0..<16 {
            let recording = Recording(
                startedAt: now.addingTimeInterval(Double(index)),
                endedAt: now.addingTimeInterval(Double(index + 30)),
                title: "下游任务尚未创建 \(index + 1)",
                isMeeting: true,
                state: .processing
            )
            recordingIDs.append(recording.id)
            try await model.repository.createRecording(recording, at: now)
            try await model.repository.upsertJob(RecordingJob(
                recordingID: recording.id,
                kind: .transcription,
                state: .completed,
                attemptCount: 1,
                lastError: nil,
                createdAt: now,
                updatedAt: now
            ), at: now)
        }

        let before = await model.fetchTranscriptionQueueStatus()
        #expect(before.todoTasks.count == 16)
        #expect(before.runningTasks.isEmpty)
        #expect(before.completedTasks.count == 16)

        await model.stopAllTranscriptionJobs()

        let after = await model.fetchTranscriptionQueueStatus()
        #expect(after.todoTasks.isEmpty)
        #expect(after.runningTasks.isEmpty)
        #expect(after.failedTasks.isEmpty)
        #expect(after.cancelledTasks.count == 16)
        #expect(after.completedTasks.count == 16)
        for recordingID in recordingIDs {
            let persistedJobs = try await model.repository.jobs(recordingID: recordingID)
            #expect(persistedJobs.contains {
                $0.kind == .speakerFinalization && $0.state == .cancelled
            })
        }
    }

    @Test func manualCompletionFinishesOnlyTheOutstandingStages() async throws {
        let root = temporaryQueueDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try RecordingCoreModel(rootURL: root)
        let now = Date(timeIntervalSince1970: 1_787_603_000)
        let recording = Recording(
            startedAt: now,
            endedAt: now.addingTimeInterval(30),
            title: "保留逐字稿的会议",
            isMeeting: true,
            state: .processing
        )
        try await model.repository.createRecording(recording, at: now)
        for (kind, state) in [
            (RecordingJobKind.transcription, RecordingJobState.completed),
            (.speakerEmbedding, .failed),
            (.speakerFinalization, .failed)
        ] {
            try await model.repository.upsertJob(RecordingJob(
                recordingID: recording.id,
                chunkID: kind == .speakerFinalization ? nil : UUID(),
                kind: kind,
                state: state,
                attemptCount: 1,
                lastError: state == .failed ? "音频不可用" : nil,
                createdAt: now,
                updatedAt: now
            ), at: now)
        }

        await model.markProcessingCompleted(recordingID: recording.id)

        let jobs = try await model.repository.jobs(recordingID: recording.id)
        #expect(jobs.allSatisfy { $0.state == .completed })
        let status = await model.fetchTranscriptionQueueStatus()
        #expect(status.completedTasks.filter { $0.recordingID == recording.id }.count == 2)
    }

    @Test func completingSpeakerTaskDoesNotRewriteCompletedTranscription() async throws {
        let root = temporaryQueueDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try RecordingCoreModel(rootURL: root)
        let now = Date(timeIntervalSince1970: 1_787_604_000)
        let recording = Recording(
            startedAt: now,
            endedAt: now.addingTimeInterval(30),
            title: "只完成声文整理",
            isMeeting: true,
            state: .processing
        )
        try await model.repository.createRecording(recording, at: now)
        let transcription = RecordingJob(
            recordingID: recording.id,
            kind: .transcription,
            state: .completed,
            attemptCount: 1,
            lastError: nil,
            createdAt: now,
            updatedAt: now
        )
        try await model.repository.upsertJob(transcription, at: now)
        try await model.repository.upsertJob(RecordingJob(
            recordingID: recording.id,
            kind: .speakerFinalization,
            state: .failed,
            attemptCount: 1,
            lastError: "声纹不可用",
            createdAt: now,
            updatedAt: now
        ), at: now)

        await model.markProcessingTaskCompleted(
            recordingID: recording.id,
            stage: .speakerProcessing
        )
        await model.forceReconcileAndResume()

        let jobs = try await model.repository.jobs(recordingID: recording.id)
        let persistedTranscription = try #require(jobs.first { $0.id == transcription.id })
        #expect(persistedTranscription.state == .completed)
        #expect(persistedTranscription.terminationReason == nil)
        #expect(jobs.first {
            $0.kind == .speakerFinalization
        }?.terminationReason == "userMarkedComplete")
        let status = await model.fetchTranscriptionQueueStatus()
        #expect(status.runningTasks.isEmpty)
        #expect(status.failedTasks.isEmpty)
        #expect(status.completedTasks.filter { $0.recordingID == recording.id }.count == 2)
    }

    @Test func restartingSpeakerTaskWaitsForCancelledTranscriptionDependency() async throws {
        let root = temporaryQueueDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try RecordingCoreModel(rootURL: root)
        let now = Date(timeIntervalSince1970: 1_787_605_000)
        let recording = Recording(
            startedAt: now,
            endedAt: now.addingTimeInterval(30),
            title: "依赖未恢复",
            isMeeting: true,
            state: .processing
        )
        try await model.repository.createRecording(recording, at: now)
        for kind in [RecordingJobKind.transcription, .speakerFinalization] {
            try await model.repository.upsertJob(RecordingJob(
                recordingID: recording.id,
                kind: kind,
                state: .cancelled,
                attemptCount: 0,
                lastError: nil,
                terminationReason: "userCancelled",
                createdAt: now,
                updatedAt: now
            ), at: now)
        }

        await model.restartCancelledProcessingTask(
            recordingID: recording.id,
            stage: .speakerProcessing
        )

        let status = await model.fetchTranscriptionQueueStatus()
        let speaker = try #require(status.todoTasks.first {
            $0.recordingID == recording.id && $0.stage == .speakerProcessing
        })
        #expect(speaker.dependencyMessage == "等待逐字稿识别完成")
        #expect(status.runningTasks.isEmpty)
        let jobs = try await model.repository.jobs(recordingID: recording.id)
        #expect(jobs.first { $0.kind == .transcription }?.state == .cancelled)
        #expect(jobs.first { $0.kind == .speakerFinalization }?.state == .pending)
    }
}

private func temporaryQueueDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ProcessingQueueStatusTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
