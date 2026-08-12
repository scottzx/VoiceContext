import Foundation
import Observation
import UIKit

/// App-level model for the 0.1.0 recording-core device validation. Owns the
/// repository, the session coordinator, and the observable evidence the
/// validation screen needs: state, chunk/gap snapshots, recovery results,
/// integrity diagnostics, and the shareable report.
@MainActor
@Observable
final class RecordingCoreModel {
    struct RecoverySummary: Equatable {
        let date: Date
        let replayedEventCount: Int
        let recoveredRecordingIDs: [UUID]
    }

    struct Snapshot: Equatable {
        var recording: Recording?
        var chunks: [AudioChunk] = []
        var gaps: [RecordingGap] = []
        var appliedEventCount = 0
        var schemaVersion = 0
    }

    private(set) var presentation: RecordingSessionCoordinator.PresentationState = .idle
    private(set) var activeRecordingID: UUID?
    private(set) var snapshot = Snapshot()
    private(set) var recordings: [Recording] = []
    private(set) var recoveries: [RecoverySummary] = []
    private(set) var inputLevel: Float?
    private(set) var integrityIssues: [RecordingIntegrityIssue]?
    private(set) var inspectedRecordingID: UUID?
    private(set) var notice: String?
    private(set) var reportURL: URL?
    private(set) var isInBackground = false

    let repository: RecordingRepository
    private let recorder = AACSegmentRecorder()
    private let coordinator: RecordingSessionCoordinator
    private let inferenceService: SenseVoiceInferenceService
    private let transcriptStore: TranscriptDocumentStore
    private let transcriptionScheduler: ForegroundTranscriptionScheduler
    private let diagnostics = RecordingDiagnostics()
    private var refreshTask: Task<Void, Never>?

    convenience init() throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try self.init(rootURL: documents.appendingPathComponent("VoiceContext", isDirectory: true))
    }

    init(rootURL: URL) throws {
        repository = try RecordingRepository(rootURL: rootURL)
        let transcriptStore = try TranscriptDocumentStore(rootURL: rootURL)
        self.transcriptStore = transcriptStore
        coordinator = RecordingSessionCoordinator(repository: repository, capture: recorder)
        let inferenceService = SenseVoiceInferenceService()
        self.inferenceService = inferenceService
        transcriptionScheduler = ForegroundTranscriptionScheduler(
            repository: repository,
            execute: { [repository, inferenceService, transcriptStore] recordingID in
                let chunks = try await repository.chunks(recordingID: recordingID)
                    .filter { $0.state == .closed }
                    .sorted { $0.startSample < $1.startSample }
                guard !chunks.isEmpty else {
                    throw SenseVoiceInferenceService.InferenceError.runtime("录音没有已关闭的音频分片")
                }
                guard let recording = try await repository.recording(id: recordingID) else {
                    throw SenseVoiceInferenceService.InferenceError.runtime("找不到待写入文稿的录音")
                }

                let jobs = try await repository.jobs(recordingID: recordingID)
                let runningJob = jobs.last {
                    $0.kind == .transcription && $0.state == .running
                }

                // Jobs created before minute-level processing have no chunk
                // scope. Keep them as a one-time compatibility path.
                guard let chunkID = runningJob?.chunkID else {
                    var transcriptionResults: [(chunkID: UUID, text: String)] = []
                    for chunk in chunks {
                        let result = try await inferenceService.transcribe(
                            recordingURL: repository.rootURL.appendingPathComponent(chunk.relativePath)
                        )
                        transcriptionResults.append((chunkID: chunk.id, text: result.text))
                    }
                    let document = TranscriptDocumentV1(
                        recording: recording,
                        chunks: chunks,
                        segmentTexts: transcriptionResults
                    )
                    try document.requireContent()
                    try await transcriptStore.write(document)
                    return
                }

                guard let chunk = chunks.first(where: { $0.id == chunkID }) else {
                    throw SenseVoiceInferenceService.InferenceError.runtime("找不到待转写的音频分片")
                }
                let previous = chunks.last {
                    $0.endSample == chunk.startSample && $0.requiresContinuation
                }
                let sourceChunks = previous.map { [$0, chunk] } ?? [chunk]
                let result = try await inferenceService.transcribe(
                    recordingURLs: sourceChunks.map {
                        repository.rootURL.appendingPathComponent($0.relativePath)
                    },
                    startingAt: sourceChunks[0].startSample
                )
                // The final-chunk rule must reflect whether capture has already
                // stopped. This job may have started while the Recording was
                // still active, and the value read above can predate the stop
                // that closed the last chunk. Re-read at decision time so an
                // open tail on the final chunk is committed, not left waiting
                // for a successor that will never be closed.
                let settledRecording = try await repository.recording(id: recordingID)
                let isFinalChunk = settledRecording?.endedAt != nil && chunks.last?.id == chunk.id

                if result.endsWithOpenSpeech && !isFinalChunk {
                    _ = try await repository.setChunkContinuation(
                        id: chunk.id,
                        requiresContinuation: true,
                        at: Date()
                    )
                    return
                }

                if let previous {
                    _ = try await repository.setChunkContinuation(
                        id: previous.id,
                        requiresContinuation: false,
                        at: Date()
                    )
                }
                if isFinalChunk || chunk.requiresContinuation {
                    // A final chunk has no successor to consume an open tail,
                    // so its marker must not survive the finished Recording;
                    // the second branch re-clears a marker that a prior run of
                    // this chunk left behind.
                    _ = try await repository.setChunkContinuation(
                        id: chunk.id,
                        requiresContinuation: false,
                        at: Date()
                    )
                }

                let document = try await transcriptStore.document(recordingID: recordingID)
                let updated = document?.appending(
                    recording: recording,
                    chunks: chunks,
                    text: result.text,
                    sourceChunkID: previous?.id ?? chunk.id,
                    replacingSourceChunkIDs: sourceChunks.map(\.id)
                ) ?? TranscriptDocumentV1(
                    recording: recording,
                    chunks: sourceChunks,
                    segmentTexts: [(previous?.id ?? chunk.id, result.text)],
                    state: .processing
                )
                try updated.requireContent()
                try await transcriptStore.write(updated)
            }
        )
        coordinator.onStateChanged = { [weak self] state in
            self?.presentationChanged(to: state)
        }
        recorder.onMeteringUpdate = { [weak self] metrics in
            Task { @MainActor [weak self] in
                self?.inputLevel = metrics.displayLevel
            }
        }
        coordinator.onChunkClosed = { [weak self] recordingID, chunkID in
            guard let self else { return }
            try? await self.transcriptionScheduler.enqueue(
                recordingID: recordingID,
                chunkID: chunkID,
                onOutcome: { [weak self] outcome in
                    await self?.applyTranscriptionOutcome(outcome)
                }
            )
        }
    }

    /// Fallback for the error path of the UI: a tmp-backed model that keeps
    /// the screen renderable if the Documents-backed repository fails.
    static func makePlaceholder() -> RecordingCoreModel {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceContext-fallback", isDirectory: true)
        return try! RecordingCoreModel(rootURL: url)
    }

    // MARK: - Session control

    var captureIsActive: Bool {
        switch presentation {
        case .recording, .paused, .interrupted:
            true
        case .idle, .stopping, .processing, .failed:
            false
        }
    }

    func start(title: String? = nil, isMeeting: Bool = false) async {
        notice = nil
        do {
            let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let recordingID = try await coordinator.start(
                isMeeting: isMeeting,
                title: normalizedTitle?.isEmpty == false ? normalizedTitle : nil
            )
            activeRecordingID = recordingID
        } catch {
            notice = "开始失败：\(error.localizedDescription)"
        }
        await refresh()
    }

    func pauseOrResume() async {
        do {
            if presentation == .paused {
                try await coordinator.resume()
            } else {
                try await coordinator.pause()
            }
        } catch {
            notice = error.localizedDescription
        }
        await refresh()
    }

    func stop() async {
        do {
            // The final under-60s chunk is closed and enqueued inside
            // coordinator.stop() (via onChunkClosed). The minute-level queue
            // owns transcription, so stop must not also enqueue a legacy
            // whole-recording job with a nil chunkID.
            _ = try await coordinator.stop()
        } catch {
            notice = error.localizedDescription
        }
        await refresh()
    }

    /// Retained for the debug validation screen. Production transitions are
    /// driven by `ForegroundTranscriptionScheduler` after capture stops.
    func markProcessingCompleted() async {
        do {
            guard let recordingID = snapshot.recording?.id else {
                throw RecordingSessionCoordinator.CoordinatorError.noActiveSession
            }
            try await coordinator.markProcessingCompleted(recordingID: recordingID)
        } catch {
            notice = error.localizedDescription
        }
        await refresh()
    }

    func retryTranscription(recordingID: UUID) async {
        do {
            try await coordinator.retryProcessing(recordingID: recordingID)
            try await transcriptionScheduler.retry(
                recordingID: recordingID,
                onOutcome: { [weak self] outcome in
                    await self?.applyTranscriptionOutcome(outcome)
                }
            )
        } catch {
            notice = "重试失败：\(error.localizedDescription)"
        }
        await refresh()
    }

    /// The details surface reads the canonical JSON document. A nil value is
    /// truthful for pending/failed processing and is not an empty transcript.
    func transcript(recordingID: UUID) async throws -> TranscriptDocumentV1? {
        try await transcriptStore.document(recordingID: recordingID)
    }

    func scenePhaseChanged(to phase: ScenePhaseLike) {
        switch phase {
        case .background:
            coordinator.applicationEnteredBackground()
            isInBackground = true
            Task { [inferenceService, transcriptionScheduler] in
                await transcriptionScheduler.enteredBackground()
                _ = await inferenceService.enteredBackground()
            }
        case .active:
            coordinator.applicationBecameActive()
            isInBackground = false
            Task { [inferenceService, transcriptionScheduler] in
                await inferenceService.enteredForeground()
                await transcriptionScheduler.enteredForeground()
            }
        default:
            break
        }
    }

    // MARK: - Recovery evidence

    func recoverOnLaunch() async {
        await runRecovery()
    }

    func runRecoveryAgain() async {
        await runRecovery()
    }

    private func runRecovery() async {
        do {
            let result = try await repository.recoverUnfinished(at: Date())
            try await enqueueHistoricalChunkJobs()
            try await transcriptionScheduler.resumePendingJobs(
                onOutcome: { [weak self] outcome in
                    await self?.applyTranscriptionOutcome(outcome)
                }
            )
            recoveries.append(RecoverySummary(
                date: Date(),
                replayedEventCount: result.replayedEventCount,
                recoveredRecordingIDs: result.interruptedRecordingIDs
            ))
            notice = result.interruptedRecordingIDs.isEmpty
                ? "恢复检查完成：没有未完成的录音（幂等）。"
                : "恢复完成：\(result.interruptedRecordingIDs.count) 条录音转为 interrupted。"
        } catch {
            notice = "恢复失败：\(error.localizedDescription)"
        }
        await refresh()
    }

    /// Backfills old recordings into the same durable per-chunk queue used by
    /// new captures. Complete recordings with an existing successful
    /// transcript are left untouched; failed or never-processed recordings
    /// are split into independently retryable closed-chunk jobs.
    private func enqueueHistoricalChunkJobs() async throws {
        let records = try await repository.recordings()
        for recording in records {
            guard recording.endedAt != nil else { continue }
            let chunks = try await repository.chunks(recordingID: recording.id)
                .filter { $0.state == .closed }
                .sorted { $0.startSample < $1.startSample }
            guard !chunks.isEmpty else { continue }

            let jobs = try await repository.jobs(recordingID: recording.id)
            let chunkJobIDs = Set(jobs.compactMap { job in
                job.kind == .transcription ? job.chunkID : nil
            })
            let existingTranscript = try await transcriptStore.document(recordingID: recording.id)

            // Some builds completed the canonical document but crashed before
            // reconciling the Recording projection. A previous migration may
            // also already have queued chunk jobs. The completed document is
            // authoritative: retire every redundant transcription job before
            // the scheduler resumes and repair the aggregate state.
            if existingTranscript?.state == RecordingState.complete.rawValue {
                let reconciledAt = Date()
                for var job in jobs where
                    job.kind == .transcription && job.state != .completed
                {
                    job.state = .completed
                    job.lastError = "supersededByCompletedTranscript"
                    job.updatedAt = reconciledAt
                    try await repository.upsertJob(job, at: reconciledAt)
                }
                if recording.state != .complete {
                    try await repository.changeState(
                        recordingID: recording.id,
                        to: .complete,
                        endedAt: recording.endedAt,
                        at: reconciledAt
                    )
                }
                _ = try await repository.clearContinuationMarkersForCompletedRecording(
                    recordingID: recording.id,
                    at: reconciledAt
                )
                continue
            }

            // The old implementation used one whole-recording job. It must
            // never race the durable chunk queue or run the long recording
            // twice, whether the chunk jobs were created in this launch or a
            // previous one.
            for var legacyJob in jobs where
                legacyJob.kind == .transcription &&
                legacyJob.chunkID == nil &&
                legacyJob.state != .completed
            {
                legacyJob.state = .completed
                legacyJob.lastError = "supersededByChunkJobs"
                legacyJob.updatedAt = Date()
                try await repository.upsertJob(legacyJob, at: legacyJob.updatedAt)
            }

            // A durable per-chunk queue already exists and will be resumed
            // below. Do not create duplicate jobs on repeated launches.
            guard chunkJobIDs.isEmpty else { continue }

            for chunk in chunks {
                try await transcriptionScheduler.enqueue(
                    recordingID: recording.id,
                    chunkID: chunk.id,
                    onOutcome: { [weak self] outcome in
                        await self?.applyTranscriptionOutcome(outcome)
                    }
                )
            }
        }
    }

    private func applyTranscriptionOutcome(_ outcome: ForegroundTranscriptionScheduler.Outcome) async {
        do {
            switch outcome.state {
            case .failed:
                try await coordinator.finishProcessing(
                    recordingID: outcome.recordingID,
                    outcome: outcome.state
                )
            case .completed:
                let jobs = try await repository.jobs(recordingID: outcome.recordingID)
                    .filter { $0.kind == .transcription }
                guard !jobs.isEmpty, jobs.allSatisfy({ $0.state == .completed }) else {
                    await refresh()
                    return
                }
                try await coordinator.finishProcessing(
                    recordingID: outcome.recordingID,
                    outcome: outcome.state
                )
                if let recording = try await repository.recording(id: outcome.recordingID),
                   recording.state == .complete {
                    _ = try await repository.clearContinuationMarkersForCompletedRecording(
                        recordingID: outcome.recordingID,
                        at: Date()
                    )
                    if let document = try await transcriptStore.document(recordingID: outcome.recordingID) {
                        try await transcriptStore.write(document.updatingState(.complete))
                    }
                }
            }
        } catch {
            // A scheduler failure must remain visible rather than being
            // converted into a completed Recording by a UI fallback.
            notice = "转写状态更新失败：\(error.localizedDescription)"
        }
        await refresh()
    }

    // MARK: - Diagnostics and report

    func runDiagnostics() async {
        var recordingID = activeRecordingID
        if recordingID == nil {
            recordingID = await latestRecordingID()
        }
        guard let recordingID else {
            notice = "没有可诊断的录音。"
            return
        }
        do {
            integrityIssues = try await diagnostics.inspect(recordingID: recordingID, repository: repository)
            inspectedRecordingID = recordingID
            notice = integrityIssues?.isEmpty == true
                ? "完整性诊断通过：无重叠、无未解释缺口、音频可读。"
                : "完整性诊断发现 \(integrityIssues?.count ?? 0) 个问题。"
        } catch {
            notice = "诊断失败：\(error.localizedDescription)"
        }
    }

    func makeReport() async {
        if integrityIssues == nil {
            await runDiagnostics()
        }
        var checks: [RecordingValidationReport.Check] = []
        if let issues = integrityIssues {
            checks.append(RecordingValidationReport.Check(
                id: "integrity",
                title: "完整性诊断（边界/缺口/可读性）",
                outcome: issues.isEmpty ? .passed : .failed,
                notes: inspectedRecordingID.map { "Recording \($0.uuidString.prefix(8))" } ?? ""
            ))
        }
        checks.append(contentsOf: manualChecks())

        var report = RecordingValidationReport(
            deviceModel: Self.deviceModel(),
            operatingSystem: "iOS \(UIDevice.current.systemVersion)",
            appBuild: Self.appBuild(),
            startedAt: Date(),
            completedAt: nil,
            checks: checks,
            integrityIssues: integrityIssues ?? []
        )
        report.checks.append(RecordingValidationReport.Check(
            id: "chunks",
            title: "chunk 边界汇总",
            outcome: .pending,
            notes: chunkBoundarySummary()
        ))

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let url = repository.rootURL
            .deletingLastPathComponent()
            .appendingPathComponent("validation-report-\(formatter.string(from: Date())).md")
        do {
            try report.markdown().write(to: url, atomically: true, encoding: .utf8)
            reportURL = url
            notice = "报告已生成：\(url.lastPathComponent)"
        } catch {
            notice = "报告写入失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Private

    private func presentationChanged(to state: RecordingSessionCoordinator.PresentationState) {
        presentation = state
        // The coordinator owns the microphone-session lifetime. Keep this
        // convenience value in sync so an outcome cannot leave the UI model
        // pointing at a released capture session.
        activeRecordingID = coordinator.activeRecordingID
        switch state {
        case .recording, .stopping, .processing, .paused:
            startPolling()
        case .interrupted:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            startPolling()
        case .failed:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .idle:
            stopPolling()
            inputLevel = nil
        }
        Task { await refresh() }
    }

    private func startPolling() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func stopPolling() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func refresh() async {
        do {
            recordings = try await repository.recordings()
                .sorted { $0.startedAt > $1.startedAt }
        } catch {
            notice = "读取记录列表失败：\(error.localizedDescription)"
        }

        var recordingID = activeRecordingID
        if recordingID == nil {
            recordingID = await latestRecordingID()
        }
        guard let recordingID else {
            snapshot = Snapshot(
                appliedEventCount: await repository.appliedEventCount,
                schemaVersion: await repository.schemaVersion
            )
            return
        }
        do {
            snapshot = Snapshot(
                recording: try await repository.recording(id: recordingID),
                chunks: try await repository.chunks(recordingID: recordingID)
                    .sorted { $0.startSample < $1.startSample },
                gaps: try await repository.gaps(recordingID: recordingID)
                    .sorted { $0.startedAt < $1.startedAt },
                appliedEventCount: await repository.appliedEventCount,
                schemaVersion: await repository.schemaVersion
            )
        } catch {
            notice = "读取索引失败：\(error.localizedDescription)"
        }
    }

    private func latestRecordingID() async -> UUID? {
        guard let recordings = try? await repository.recordings() else { return nil }
        return recordings.max(by: { $0.startedAt < $1.startedAt })?.id
    }

    private func manualChecks() -> [RecordingValidationReport.Check] {
        let titles = [
            ("background-30min", "30 分钟后台连续（锁屏/切换 App）"),
            ("lockscreen-stop", "锁屏/控制中心停止入口"),
            ("two-hour-chunks", "2 小时连续分片（60 秒边界，约 120 片）"),
            ("interruption-gap", "电话/Siri 中断产生 gap 且 UI 显示 interrupted"),
            ("route-gap", "蓝牙断连/路由变化产生显式 gap"),
            ("termination-recovery", "强制终止后恢复 interrupted 且重复恢复幂等"),
            ("low-storage", "低存储拒绝新录音（请求麦克风前，原因明确）"),
        ]
        return titles.map { RecordingValidationReport.Check(id: $0.0, title: $0.1, outcome: .pending, notes: "") }
    }

    private func chunkBoundarySummary() -> String {
        guard !snapshot.chunks.isEmpty else { return "无 chunk" }
        let totalSamples = snapshot.chunks.map { $0.endSample - $0.startSample }.reduce(0, +)
        let lines = snapshot.chunks.map {
            "  \($0.startSample)–\($0.endSample)（\(String(format: "%.1f", Double($0.endSample - $0.startSample) / 16_000))s，\($0.state.rawValue)）"
        }
        return "共 \(snapshot.chunks.count) 个 chunk，合计 \(String(format: "%.1f", Double(totalSamples) / 16_000))s：\n" + lines.joined(separator: "\n")
    }

    private static func deviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { buffer in
            buffer.baseAddress.map { String(cString: $0.assumingMemoryBound(to: CChar.self)) } ?? UIDevice.current.model
        }
        return "\(UIDevice.current.model) \(machine)"
    }

    private static func appBuild() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "speech_note \(version) (\(build))"
    }
}

/// Mirrors SwiftUI.ScenePhase without importing SwiftUI into the model.
enum ScenePhaseLike {
    case active
    case inactive
    case background
}
