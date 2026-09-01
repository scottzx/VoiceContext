import AVFAudio
import Foundation
import Observation
import OSLog
import UIKit
import UniformTypeIdentifiers

/// App-level model for the 0.1.0 recording-core device validation. Owns the
/// repository, the session coordinator, and the observable evidence the
/// validation screen needs: state, chunk/gap snapshots, recovery results,
/// integrity diagnostics, and the shareable report.

nonisolated struct PublicExportPackage: Equatable, Sendable {
    let title: String
    let isMeeting: Bool
    let relativeJSONPath: String
    let relativeMarkdownPath: String
    let jsonURL: URL
    let markdownURL: URL
    /// Consumer export artifacts (#65 / FR-ADD-EXP-*). Temp Share Sheet copies.
    let plainTextURL: URL?
    let subtitlesURL: URL?
    let audioURL: URL?
    let plainTextDisabledReason: String?
    let subtitlesDisabledReason: String?
    let audioDisabledReason: String?

    init(
        title: String,
        isMeeting: Bool,
        relativeJSONPath: String,
        relativeMarkdownPath: String,
        jsonURL: URL,
        markdownURL: URL,
        plainTextURL: URL? = nil,
        subtitlesURL: URL? = nil,
        audioURL: URL? = nil,
        plainTextDisabledReason: String? = nil,
        subtitlesDisabledReason: String? = nil,
        audioDisabledReason: String? = nil
    ) {
        self.title = title
        self.isMeeting = isMeeting
        self.relativeJSONPath = relativeJSONPath
        self.relativeMarkdownPath = relativeMarkdownPath
        self.jsonURL = jsonURL
        self.markdownURL = markdownURL
        self.plainTextURL = plainTextURL
        self.subtitlesURL = subtitlesURL
        self.audioURL = audioURL
        self.plainTextDisabledReason = plainTextDisabledReason
        self.subtitlesDisabledReason = subtitlesDisabledReason
        self.audioDisabledReason = audioDisabledReason
    }
}

/// In-flight Files/Photos import progress. Independent of microphone capture so
/// long standardize/extract work never blocks a new recording session.
struct ImportActivity: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case queued
        case preparing
        case extractingAudio(progress: Double)
        case importing
        case enqueueing
    }

    var phase: Phase
    var sourceLabel: String

    var statusText: String {
        switch phase {
        case .queued:
            return "导入排队中：\(sourceLabel)"
        case .preparing:
            return "正在准备导入：\(sourceLabel)"
        case let .extractingAudio(progress):
            let percent = max(0, min(100, Int((progress * 100).rounded())))
            return "正在抽取音轨 \(percent)%：\(sourceLabel)"
        case .importing:
            return "正在导入：\(sourceLabel)"
        case .enqueueing:
            return "已导入，正在排队转写：\(sourceLabel)"
        }
    }
}

@MainActor
@Observable
final class RecordingCoreModel {
    private static let transcriptionCenterLog = Logger(
        subsystem: "YiJie.speech_note",
        category: "TranscriptionCenter"
    )
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

    enum MeetingParticipantError: LocalizedError {
        case notMeeting
        case transcriptUnavailable
        case emptyName

        var errorDescription: String? {
            switch self {
            case .notMeeting:
                "只有多人会议可以记录参会人。"
            case .transcriptUnavailable:
                "会议文档尚未建立，请等逐字稿开始生成后再添加。"
            case .emptyName:
                "参会人姓名不能为空。"
            }
        }
    }

    private(set) var presentation: RecordingSessionCoordinator.PresentationState = .idle
    private(set) var activeRecordingID: UUID?
    /// Capture-session progress for the live recording chrome. Independent of
    /// any older Recording that may still be processing in the background.
    private(set) var sessionProgress: RecordingPresentationProgress?
    private(set) var snapshot = Snapshot()
    private(set) var recordings: [Recording] = []
    private(set) var audioDurations: [UUID: TimeInterval] = [:]
    private(set) var recoveries: [RecoverySummary] = []
    private(set) var inputLevel: Float?
    private(set) var integrityIssues: [RecordingIntegrityIssue]?
    private(set) var inspectedRecordingID: UUID?
    private(set) var notice: String?
    /// Non-nil while a Files/Photos import is copying, extracting, or enqueueing.
    private(set) var importActivity: ImportActivity?
    private(set) var reportURL: URL?
    private(set) var isInBackground = false
    private var importTaskRunning = false

    let repository: RecordingRepository
    private let recorder = AACSegmentRecorder()
    private let coordinator: RecordingSessionCoordinator
    private let inferenceService: SenseVoiceInferenceService
    private let transcriptStore: TranscriptDocumentStore
    private let publicDocumentPublisher: PublicDocumentPublisher
    private let attachmentStore: RecordingAttachmentStore
    private let speakerFinalizationCoordinator: SpeakerFinalizationCoordinator
    private let completionReconciler: CompletionReconciler
    private let skillPackSeeder: PublicSkillPackSeeder
    let folderCatalogStore: FolderCatalogStore
    private let folderiCloudMirror: FolderiCloudMirror
    private(set) var folderCatalog: FolderCatalogDocument = .empty()
    let clientCatalogStore: ClientCatalogStore
    private(set) var clientCatalog: ClientCatalogDocument = .empty()
    private let voiceprintArchiveURL: URL
    private let voiceprintKeyProvider: any VoiceprintArchiveKeyProviding
    private let voiceprintSyncConfiguration: EncryptedVoiceprintiCloudMirror.Configuration
    private let transcriptionScheduler: ForegroundTranscriptionScheduler
    private let backgroundTranscriptionContinuation: BackgroundTranscriptionContinuation
    let trialEntitlement: TrialEntitlementController
    private let trialLedger: TrialQuotaLedger
    private let diagnostics = RecordingDiagnostics()
    private var refreshTask: Task<Void, Never>?
    private var pendingSpeakerFinalizationIDs: Set<UUID> = []
    private var speakerFinalizationDrainTask: Task<Void, Never>?

    convenience init() throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try self.init(rootURL: documents.appendingPathComponent("VoiceContext", isDirectory: true))
    }

    init(
        rootURL: URL,
        coordinator customCoordinator: RecordingSessionCoordinator? = nil,
        trialLedger: TrialQuotaLedger? = nil,
        purchaseClient: (any PurchaseUnlockClient)? = nil,
        voiceprintArchiveURL: URL? = nil,
        voiceprintKeyProvider: any VoiceprintArchiveKeyProviding = VoiceprintArchiveKeyStore.shared,
        voiceprintSyncConfiguration: EncryptedVoiceprintiCloudMirror.Configuration = .init()
    ) throws {
        repository = try RecordingRepository(rootURL: rootURL)
        let transcriptStore = try TranscriptDocumentStore(rootURL: rootURL)
        self.transcriptStore = transcriptStore
        publicDocumentPublisher = PublicDocumentPublisher(rootURL: rootURL, enableDefaultiCloudMirror: true)
        attachmentStore = RecordingAttachmentStore(rootURL: rootURL)
        speakerFinalizationCoordinator = SpeakerFinalizationCoordinator()
        completionReconciler = CompletionReconciler(
            repository: repository,
            transcriptStore: transcriptStore
        )
        skillPackSeeder = PublicSkillPackSeeder(rootURL: rootURL)
        folderCatalogStore = FolderCatalogStore(rootURL: rootURL)
        folderiCloudMirror = FolderiCloudMirror(localRootURL: rootURL)
        clientCatalogStore = ClientCatalogStore(rootURL: rootURL)
        self.voiceprintArchiveURL = try voiceprintArchiveURL ?? VoiceprintArchiveStorage.defaultURL()
        self.voiceprintKeyProvider = voiceprintKeyProvider
        self.voiceprintSyncConfiguration = voiceprintSyncConfiguration
        coordinator = customCoordinator ?? RecordingSessionCoordinator(repository: repository, capture: recorder)
        let lifecycleGate = InferenceLifecycleGate()
        let inferenceService = SenseVoiceInferenceService(lifecycleGate: lifecycleGate)
        self.inferenceService = inferenceService
        let ledger = trialLedger ?? TrialQuotaLedger()
        self.trialLedger = ledger
        let entitlement = TrialEntitlementController(
            ledger: ledger,
            client: purchaseClient ?? StoreKitPurchaseUnlockClient()
        )
        self.trialEntitlement = entitlement
        let transcriptionScheduler = ForegroundTranscriptionScheduler(
            repository: repository,
            lifecycleGate: lifecycleGate,
            admissionPolicy: TranscriptionAdmissionPolicy(
                isPurchaseLocked: {
                    TrialQuotaLedger.isManualTrialEnabled && ledger.isPurchaseLocked
                }
            ),
            execute: { [repository, inferenceService, transcriptStore, publicDocumentPublisher] lease in
                let recordingID = lease.recordingID
                guard let recording = try await repository.recording(id: recordingID) else {
                    throw SenseVoiceInferenceService.InferenceError.runtime("找不到待写入文稿的录音")
                }

                if case let .processingRange(rangeID) = lease.sourceTarget {
                    _ = try await Self.executeImportedRangeJob(
                        recording: recording,
                        rangeID: rangeID,
                        lease: lease,
                        repository: repository,
                        inferenceService: inferenceService,
                        transcriptStore: transcriptStore,
                        publicDocumentPublisher: publicDocumentPublisher
                    )
                    return
                }

                let chunks = try await repository.chunks(recordingID: recordingID)
                    .filter { $0.state == .closed }
                    .sorted { $0.startSample < $1.startSample }
                guard !chunks.isEmpty else {
                    throw SenseVoiceInferenceService.InferenceError.runtime("录音没有已关闭的音频分片")
                }

                // Jobs created before minute-level processing have no chunk
                // scope. Keep them as a one-time compatibility path.
                guard case let .audioChunk(chunkID) = lease.sourceTarget else {
                    var transcriptionResults: [(chunkID: UUID, text: String)] = []
                    var detectedLanguage = ""
                    var temporarySpeakers: [String] = []
                    for chunk in chunks {
                        let result = try await inferenceService.transcribe(
                            recordingURL: Self.audioURL(for: chunk, rootURL: repository.rootURL),
                            languageMode: recording.languageMode
                        )
                        transcriptionResults.append((chunkID: chunk.id, text: result.text))
                        if detectedLanguage.isEmpty {
                            detectedLanguage = result.detectedLanguage
                        }
                        temporarySpeakers = TemporarySpeakerLabeling.mergeRosters(
                            temporarySpeakers,
                            result.temporarySpeakers
                        )
                    }
                    let existingParticipants = try await transcriptStore
                        .document(recordingID: recordingID)?.participants ?? []
                    let document = TranscriptDocumentV1(
                        recording: recording,
                        chunks: chunks,
                        segmentTexts: transcriptionResults,
                        language: detectedLanguage,
                        speakers: temporarySpeakers,
                        participants: existingParticipants
                    )
                    try document.requireContent()
                    guard try await repository.validateExecutionLease(lease) else {
                        throw JobExecutionLeaseError.invalidated
                    }
                    try await transcriptStore.write(document)
                    try? await Self.publishPublicDocuments(
                        document: document,
                        repository: repository,
                        transcriptStore: transcriptStore,
                        publisher: publicDocumentPublisher
                    )
                    return
                }

                guard let chunk = chunks.first(where: { $0.id == chunkID }) else {
                    throw SenseVoiceInferenceService.InferenceError.runtime("找不到待转写的音频分片")
                }

                let result: SenseVoiceInferenceService.Result
                do {
                    result = try await inferenceService.transcribe(
                        recordingURLs: [Self.audioURL(for: chunk, rootURL: repository.rootURL)],
                        startingAt: chunk.startSample,
                        languageMode: recording.languageMode
                    )
                } catch let error as SpeechAnalysisService.AnalysisError {
                    guard case .noSpeechDetected = error else { throw error }
                    // VAD detected no speech (e.g. final silent segment):
                    // Safely mark continuation cleared and consider this chunk job cleanly completed.
                    guard try await repository.validateExecutionLease(lease) else {
                        throw JobExecutionLeaseError.invalidated
                    }
                    try SpeakerObservationStore.replaceBatch(
                        [],
                        rootURL: repository.rootURL,
                        recordingID: recordingID,
                        batchID: chunk.id
                    )
                    _ = try? await repository.setChunkContinuation(
                        id: chunk.id,
                        requiresContinuation: false,
                        at: Date()
                    )
                    return
                } catch let error as SenseVoiceInferenceService.InferenceError {
                    guard case .emptyTranscript = error else { throw error }
                    // ASR returned empty transcript:
                    // Safely mark continuation cleared and consider this chunk job cleanly completed.
                    guard try await repository.validateExecutionLease(lease) else {
                        throw JobExecutionLeaseError.invalidated
                    }
                    try SpeakerObservationStore.replaceBatch(
                        [],
                        rootURL: repository.rootURL,
                        recordingID: recordingID,
                        batchID: chunk.id
                    )
                    _ = try? await repository.setChunkContinuation(
                        id: chunk.id,
                        requiresContinuation: false,
                        at: Date()
                    )
                    return
                }

                guard try await repository.validateExecutionLease(lease) else {
                    throw JobExecutionLeaseError.invalidated
                }
                _ = try? await repository.setChunkContinuation(
                    id: chunk.id,
                    requiresContinuation: false,
                    at: Date()
                )

                var drafts: [TranscriptDocumentV1.SegmentDraft] = []
                let newObservations = result.speakerObservations
                if !result.sentenceResults.isEmpty {
                    for u in result.sentenceResults {
                        let sourceRange = TranscriptDocumentV1.SourceRange(
                            sourceKind: .audioChunk,
                            sourceID: chunk.id,
                            startSample: u.startSample,
                            endSample: u.endSample
                        )
                        drafts.append(
                            TranscriptDocumentV1.SegmentDraft(
                                text: u.text,
                                startSample: u.startSample,
                                endSample: u.endSample,
                                sourceRanges: [sourceRange]
                            )
                        )
                    }
                } else {
                    let trimmedText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedText.isEmpty {
                        let sourceRanges = [
                            TranscriptDocumentV1.SourceRange(
                                sourceKind: .audioChunk,
                                sourceID: chunk.id,
                                startSample: chunk.startSample,
                                endSample: chunk.endSample
                            )
                        ]
                        drafts.append(
                            TranscriptDocumentV1.SegmentDraft(
                                text: trimmedText,
                                startSample: chunk.startSample,
                                endSample: chunk.endSample,
                                sourceRanges: sourceRanges
                            )
                        )
                    }
                }
                if !drafts.isEmpty {
                    guard try await repository.validateExecutionLease(lease) else {
                        throw JobExecutionLeaseError.invalidated
                    }
                    let commitStartedAt = Date()
                    try SpeakerObservationStore.replaceBatch(
                        newObservations,
                        rootURL: repository.rootURL,
                        recordingID: recordingID,
                        batchID: chunk.id
                    )

                    let document = try await transcriptStore.document(recordingID: recordingID)
                    let updated = document?.appending(
                        recording: recording,
                        chunks: chunks,
                        drafts: drafts,
                        replacingSourceIDs: [chunk.id],
                        speakers: result.temporarySpeakers
                    ) ?? TranscriptDocumentV1(
                        recording: recording,
                        chunks: chunks,
                        segmentDrafts: drafts,
                        language: result.detectedLanguage,
                        state: .processing,
                        speakers: result.temporarySpeakers
                    )
                    guard try await repository.validateExecutionLease(lease) else {
                        throw JobExecutionLeaseError.invalidated
                    }
                    try await transcriptStore.write(updated)
                    let commitMilliseconds = Date().timeIntervalSince(commitStartedAt) * 1_000
                    try TranscriptionStageMetricsStore.save(
                        TranscriptionStageMetrics(
                            recordingID: recordingID,
                            batchID: chunk.id,
                            audioDurationMilliseconds: result.audioDuration * 1_000,
                            vadMilliseconds: result.vadMilliseconds,
                            asrLoadMilliseconds: Double(result.loadMilliseconds),
                            asrInferenceMilliseconds: Double(result.inferenceMilliseconds),
                            embeddingMilliseconds: result.embeddingMilliseconds,
                            commitMilliseconds: commitMilliseconds,
                            thermalState: result.thermalState,
                            completedAt: Date()
                        ),
                        rootURL: repository.rootURL
                    )
                }
            }

        )
        self.transcriptionScheduler = transcriptionScheduler
        backgroundTranscriptionContinuation = BackgroundTranscriptionContinuation(
            setBackgroundExecutionAllowed: { allowed in
                await transcriptionScheduler.setContinuedBackgroundExecutionAllowed(allowed)
            },
            expireCurrentExecution: { [inferenceService] reason in
                _ = await inferenceService.enteredBackground()
                await transcriptionScheduler.expireCurrentExecution(reason: reason)
            },
            progressProvider: {
                let snapshot = await transcriptionScheduler.queueSnapshot()
                return BackgroundTranscriptionQueueProgress(
                    pendingCount: snapshot.pending,
                    runningCount: snapshot.running,
                    completedCount: snapshot.completed,
                    failedCount: snapshot.failed
                )
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

        // Best-effort: local Documents always gets Skill/Templates for Codex.
        Task { [skillPackSeeder] in
            _ = try? await skillPackSeeder.seed()
        }

        if TrialQuotaLedger.isManualTrialEnabled {
            trialEntitlement.onUnlocked = { [weak self] in
                await self?.resumeTranscriptionAfterUnlock()
            }
            trialEntitlement.onTrialStateChanged = { [weak self] in
                await self?.resumeTranscriptionAfterTrialStateChanged()
            }
            trialEntitlement.start()
        }

        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let state = ProcessInfo.processInfo.thermalState
            if state == .nominal || state == .fair {
                self.transcriptionScheduler.requestDrain()
                Task { [weak self] in
                    await self?.refresh()
                }
            }
        }
    }

    /// Purchase / restore entry point used by Settings and locked-detail CTA.
    func resumeTranscriptionAfterUnlock() async {
        trialLedger.markUnlocked()
        await transcriptionScheduler.requestDrain()
        await refresh()
        if notice == nil || notice?.contains("解锁") == true || notice?.contains("锁定") == true {
            notice = "已解锁，正在继续处理待转写音频。"
        }
    }

    /// Refresh and drain queue when trial countdown is reset or simulated in testing.
    func resumeTranscriptionAfterTrialStateChanged() async {
        await transcriptionScheduler.requestDrain()
        await refresh()
    }

    /// Fallback for the error path of the UI: a tmp-backed model that keeps
    /// the screen renderable if the Documents-backed repository fails.
    static func makePlaceholder() -> RecordingCoreModel {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceContext-fallback", isDirectory: true)
        return try! RecordingCoreModel(rootURL: url)
    }

    func presentNotice(_ message: String) {
        notice = message
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

    /// Global bar / stop chrome for the live capture session only (including
    /// brief stop finalization). Distinct from `captureIsActive` and from
    /// durable processing on any Recording.
    var showsSessionChrome: Bool {
        switch presentation {
        case .recording, .paused, .interrupted, .stopping:
            true
        case .processing, .idle, .failed:
            // Processing after stop is not capture chrome; list/detail own it.
            false
        }
    }

    /// Per-Recording dual-status progress for detail / rows. Never borrows the
    /// live session identity of a different Recording.
    func presentationProgress(for recordingID: UUID) async throws -> RecordingPresentationProgress? {
        guard let recording = try await repository.recording(id: recordingID) else { return nil }
        let jobs = try await repository.jobs(recordingID: recordingID)
        let transcript = try await transcriptStore.document(recordingID: recordingID)
        let liveCapture = activeRecordingID == recordingID ? coordinator.captureState : nil
        let lastSample = RecordingPresentationProgress.lastFinalizedSample(
            segmentEndSamples: transcript?.segments.map(\.endSample) ?? []
        )
        return RecordingPresentationProgress.resolve(
            recording: recording,
            jobs: jobs,
            liveCaptureState: liveCapture,
            lastFinalizedTranscriptSample: lastSample,
            sampleRate: AACSegmentRecorder.targetSampleRate
        )
    }

    func start(title: String? = nil, isMeeting: Bool = false) async {
        notice = nil
        // Refuse capture without an explicit start; still request permission only
        // after that click. Denied permission must not create a failed Recording.
        let permission = await MicrophoneAccess.requestPermissionIfNeeded()
        guard permission == .granted else {
            notice = MicrophoneAccess.deniedStartMessage
            await refresh()
            return
        }
        do {
            let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let recordingID = try await coordinator.start(
                isMeeting: isMeeting,
                title: normalizedTitle?.isEmpty == false ? normalizedTitle : nil
            )
            activeRecordingID = recordingID

            if LocationAccess.isAutoRecordLocationEnabled {
                Task { [weak self, recordingID] in
                    if let locationName = await LocationAccess.fetchCurrentLocationAddress() {
                        await self?.updateRecordingLocation(recordingID: recordingID, locationName: locationName)
                    }
                }
            }
        } catch {
            if let recorderError = error as? AACSegmentRecorder.RecorderError,
               case .microphonePermissionDenied = recorderError {
                notice = MicrophoneAccess.deniedStartMessage
            } else {
                notice = "开始失败：\(error.localizedDescription)"
            }
        }
        await refresh()
    }

    func append(recordingID: UUID) async {
        notice = nil
        let permission = await MicrophoneAccess.requestPermissionIfNeeded()
        guard permission == .granted else {
            notice = MicrophoneAccess.deniedStartMessage
            await refresh()
            return
        }
        do {
            let resumedID = try await coordinator.startAppend(recordingID: recordingID)
            activeRecordingID = resumedID
        } catch {
            if let recorderError = error as? AACSegmentRecorder.RecorderError,
               case .microphonePermissionDenied = recorderError {
                notice = MicrophoneAccess.deniedStartMessage
            } else {
                notice = "追录失败：\(error.localizedDescription)"
            }
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
            await backgroundTranscriptionContinuation.beginUserInitiatedTask()
        } catch {
            notice = error.localizedDescription
        }
        await refresh()
    }

    func cancelRecording(id: UUID? = nil) async {
        let targetID = id ?? activeRecordingID ?? coordinator.activeRecordingID
        guard let targetID else { return }
        if targetID == activeRecordingID || targetID == coordinator.activeRecordingID {
            await coordinator.cancel(recordingID: targetID)
            activeRecordingID = nil
            sessionProgress = nil
        }
        await cancelProcessingTasks(recordingID: targetID)
        do {
            try await repository.deleteRecording(id: targetID)
            try await transcriptStore.delete(recordingID: targetID)
            try? await attachmentStore.removeAll(recordingID: targetID)
            _ = try? await folderCatalogStore.moveRecording(targetID, to: nil)
            notice = "已取消录音。"
        } catch {
            notice = "取消录音失败：\(error.localizedDescription)"
        }
        await refresh()
    }

    func audioDuration(for recordingID: UUID) -> TimeInterval {
        if activeRecordingID == recordingID && (captureIsActive || presentation == .recording || presentation == .paused || presentation == .stopping) {
            return Double(recorder.currentSample) / AACSegmentRecorder.targetSampleRate
        }
        if let duration = audioDurations[recordingID] {
            return duration
        }
        if let recording = recordings.first(where: { $0.id == recordingID }), let endedAt = recording.endedAt {
            return max(0, endedAt.timeIntervalSince(recording.startedAt))
        }
        return 0
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
            await transcriptionScheduler.prepareForRetranscription(recordingID: recordingID)
            try await coordinator.retryProcessing(recordingID: recordingID)
            try await prepareSpeakerFinalizationForRetranscription(
                recordingID: recordingID,
                resetTranscription: true,
                clearTranscript: true
            )
            let importedAsset = try? await repository.importedAudioAsset(recordingID: recordingID)
            if importedAsset != nil {
                let ranges = (try? await repository.processingRanges(recordingID: recordingID)) ?? []
                let date = Date()
                for var range in ranges {
                    range.state = .pending
                    range.requiresContinuation = false
                    range.updatedAt = date
                    _ = try? await repository.upsertProcessingRange(range, at: date)
                }
                for range in ranges {
                    try await transcriptionScheduler.enqueue(
                        recordingID: recordingID,
                        processingRangeID: range.id,
                        onOutcome: { [weak self] outcome in
                            await self?.applyTranscriptionOutcome(outcome)
                        }
                    )
                }
            } else {
                let chunks = (try? await repository.chunks(recordingID: recordingID)) ?? []
                let date = Date()
                for chunk in chunks {
                    _ = try? await repository.setChunkContinuation(id: chunk.id, requiresContinuation: false, at: date)
                }
                for chunk in chunks where chunk.state == .closed {
                    try await transcriptionScheduler.enqueue(
                        recordingID: recordingID,
                        chunkID: chunk.id,
                        onOutcome: { [weak self] outcome in
                            await self?.applyTranscriptionOutcome(outcome)
                        }
                    )
                }
            }
            await transcriptionScheduler.requestDrain()
            await backgroundTranscriptionContinuation.beginUserInitiatedTask()
            notice = "已重新开始转写录音分片。"
        } catch {
            await transcriptionScheduler.requestDrain()
            notice = "重试失败：\(error.localizedDescription)"
        }
        await refresh()
    }

    func retryTranscriptionJob(id: UUID) async {
        do {
            let allJobs = try await repository.jobs(
                kind: .transcription,
                states: [.failed, .pending, .running, .completed]
            )
            guard let target = allJobs.first(where: { $0.id == id }) else { return }
            try await coordinator.retryProcessing(recordingID: target.recordingID)
            try await prepareSpeakerFinalizationForRetranscription(recordingID: target.recordingID)
            try await transcriptionScheduler.retry(
                recordingID: target.recordingID,
                chunkID: target.chunkID,
                processingRangeID: target.processingRangeID,
                onOutcome: { [weak self] outcome in
                    await self?.applyTranscriptionOutcome(outcome)
                }
            )
            await backgroundTranscriptionContinuation.beginUserInitiatedTask()
            notice = "已重新提交转写任务。"
        } catch {
            notice = "重试任务失败：\(error.localizedDescription)"
        }
        await refresh()
    }

    func retryRecordingProcessing(recordingID: UUID) async {
        do {
            let jobs = try await repository.jobs(recordingID: recordingID)
            let failedTranscription = jobs.filter {
                $0.kind == .transcription && $0.state == .failed
            }
            if !failedTranscription.isEmpty {
                try await coordinator.retryProcessing(recordingID: recordingID)
                try await prepareSpeakerFinalizationForRetranscription(recordingID: recordingID)
                for job in failedTranscription {
                    try await transcriptionScheduler.retry(
                        recordingID: recordingID,
                        chunkID: job.chunkID,
                        processingRangeID: job.processingRangeID,
                        onOutcome: { [weak self] outcome in
                            await self?.applyTranscriptionOutcome(outcome)
                        }
                    )
                }
                await backgroundTranscriptionContinuation.beginUserInitiatedTask()
                notice = "已重新排队 \(failedTranscription.count) 个转写分段。"
            } else if try await resetFailedSpeakerJobs(recordingID: recordingID) {
                try await coordinator.retryProcessing(recordingID: recordingID)
                enqueueSpeakerFinalization(recordingIDs: [recordingID])
                notice = "已重新排队说话人识别。"
            } else {
                notice = "当前录音没有需要重试的任务。"
            }
        } catch {
            notice = "重试任务失败：\(error.localizedDescription)"
        }
        await refresh()
    }

    func retryAllFailedJobs() async {
        do {
            let failedJobs = try await repository.jobs(
                kind: .transcription,
                states: [.failed]
            )
            var preparedRecordingIDs: Set<UUID> = []
            for job in failedJobs {
                try await coordinator.retryProcessing(recordingID: job.recordingID)
                if preparedRecordingIDs.insert(job.recordingID).inserted {
                    try await prepareSpeakerFinalizationForRetranscription(
                        recordingID: job.recordingID
                    )
                }
                try await transcriptionScheduler.retry(
                    recordingID: job.recordingID,
                    chunkID: job.chunkID,
                    processingRangeID: job.processingRangeID,
                    onOutcome: { [weak self] outcome in
                        await self?.applyTranscriptionOutcome(outcome)
                    }
                )
            }
            if !failedJobs.isEmpty {
                await backgroundTranscriptionContinuation.beginUserInitiatedTask()
            }
            let failedEmbeddingJobs = try await repository.jobs(
                kind: .speakerEmbedding,
                states: [.failed]
            )
            let failedFinalizationJobs = try await repository.jobs(
                kind: .speakerFinalization,
                states: [.failed]
            )
            let speakerFailures = failedEmbeddingJobs + failedFinalizationJobs
            let speakerRecordingIDs = Set(speakerFailures.map(\.recordingID))
                .subtracting(preparedRecordingIDs)
            for recordingID in speakerRecordingIDs {
                if try await resetFailedSpeakerJobs(recordingID: recordingID) {
                    try await coordinator.retryProcessing(recordingID: recordingID)
                    enqueueSpeakerFinalization(recordingIDs: [recordingID])
                }
            }
            let retriedCount = failedJobs.count + speakerRecordingIDs.count
            notice = retriedCount == 0
                ? "当前没有失败的处理任务。"
                : "已重新排队 \(retriedCount) 个失败任务。"
        } catch {
            notice = "重试全部任务失败：\(error.localizedDescription)"
        }
        await refresh()
    }

    private func resetFailedSpeakerJobs(recordingID: UUID) async throws -> Bool {
        await speakerFinalizationCoordinator.invalidate(recordingID: recordingID)
        let now = Date()
        var changed = false
        for var job in try await repository.jobs(recordingID: recordingID) where
            (job.kind == .speakerEmbedding || job.kind == .speakerFinalization)
                && job.state == .failed {
            job.state = .pending
            job.lastError = nil
            job.executionToken = nil
            job.startedAt = nil
            job.terminationReason = "userRetry"
            job.updatedAt = now
            try await repository.upsertJob(job, at: now)
            changed = true
        }
        return changed
    }

    private func resetCancelledSpeakerJobs(recordingID: UUID) async throws -> Bool {
        await speakerFinalizationCoordinator.invalidate(recordingID: recordingID)
        let now = Date()
        var changed = false
        for var job in try await repository.jobs(recordingID: recordingID) where
            (job.kind == .speakerEmbedding || job.kind == .speakerFinalization)
                && job.state == .cancelled {
            job.state = .pending
            job.lastError = nil
            job.executionToken = nil
            job.startedAt = nil
            job.terminationReason = "userRestart"
            job.updatedAt = now
            try await repository.upsertJob(job, at: now)
            changed = true
        }
        return changed
    }

    private func prepareSpeakerFinalizationForRetranscription(
        recordingID: UUID,
        resetTranscription: Bool = false,
        clearTranscript: Bool = false
    ) async throws {
        pendingSpeakerFinalizationIDs.remove(recordingID)
        await speakerFinalizationCoordinator.invalidate(recordingID: recordingID)
        _ = try await repository.resetSpeakerFinalizationForRetranscription(
            recordingID: recordingID,
            at: Date()
        )
        if resetTranscription {
            try await repository.resetTranscriptionForRetranscription(
                recordingID: recordingID,
                at: Date()
            )
        }
        TranscriptionStageMetricsStore.removeSpeakerFinalization(
            rootURL: repository.rootURL,
            recordingID: recordingID
        )
        SpeakerObservationStore.remove(
            rootURL: repository.rootURL,
            recordingID: recordingID
        )
        try MeetingSpeakerBindingStore.save(
            [],
            rootURL: repository.rootURL,
            recordingID: recordingID
        )
        if let document = try await transcriptStore.document(recordingID: recordingID) {
            try await transcriptStore.write(document.preparingForRetranscription(
                clearSegments: clearTranscript
            ))
        }
    }

    func stopAllTranscriptionJobs() async {
        var stopFailed = false
        do {
            let activeTranscription = try await repository.jobs(
                kind: .transcription,
                states: [.pending, .running, .failed]
            )
            let activeEmbedding = try await repository.jobs(
                kind: .speakerEmbedding,
                states: [.pending, .running, .failed]
            )
            let activeFinalization = try await repository.jobs(
                kind: .speakerFinalization,
                states: [.pending, .running, .failed]
            )
            let speakerJobs = activeEmbedding + activeFinalization
            let activeJobs = activeTranscription + speakerJobs
            Self.transcriptionCenterLog.notice(
                "Stop all: transcription=\(activeTranscription.count), speaker=\(speakerJobs.count)"
            )
            var speakerRecordingIDs = Set(speakerJobs.map(\.recordingID))
            let recordings = try await repository.recordings()
            for recording in recordings where recording.speakerProcessingEnabled {
                let jobs = try await repository.jobs(recordingID: recording.id)
                guard jobs.contains(where: { $0.kind == .transcription }) else { continue }
                let finalization = jobs.first(where: { $0.kind == .speakerFinalization })
                if finalization?.state != .completed {
                    speakerRecordingIDs.insert(recording.id)
                }
            }
            for recordingID in speakerRecordingIDs {
                pendingSpeakerFinalizationIDs.remove(recordingID)
                await speakerFinalizationCoordinator.invalidate(recordingID: recordingID)
            }

            let now = Date()
            for var job in activeJobs {
                job.state = .cancelled
                job.lastError = nil
                job.executionToken = nil
                job.startedAt = nil
                job.terminationReason = "userCancelled"
                job.updatedAt = now
                try await repository.upsertJob(job, at: now)
            }
            var placeholderCount = 0
            for recordingID in speakerRecordingIDs {
                let jobs = try await repository.jobs(recordingID: recordingID)
                guard !jobs.contains(where: { $0.kind == .speakerFinalization }) else { continue }
                let placeholder = RecordingJob(
                    recordingID: recordingID,
                    kind: .speakerFinalization,
                    state: .cancelled,
                    attemptCount: 0,
                    lastError: nil,
                    terminationReason: "userCancelled",
                    createdAt: now,
                    updatedAt: now
                )
                try await repository.upsertJob(placeholder, at: now)
                placeholderCount += 1
            }
            Self.transcriptionCenterLog.notice(
                "Stop all persisted \(activeJobs.count) cancelled jobs and \(placeholderCount) downstream placeholders"
            )
        } catch {
            stopFailed = true
            Self.transcriptionCenterLog.error("Stop all failed: \(error.localizedDescription)")
            notice = "部分任务未能关停：\(error.localizedDescription)"
        }
        // Durable cancellation precedes the in-memory executor cancellation,
        // so a late inference result cannot revive a user-cancelled task.
        await transcriptionScheduler.stopAll()
        await backgroundTranscriptionContinuation.userStoppedAllTasks()
        if !stopFailed {
            notice = "已关停全部进行中的处理任务。"
        }
        await refresh()
    }

    private func cancelProcessingTasks(recordingID: UUID) async {
        do {
            let initialJobs = try await repository.jobs(recordingID: recordingID)
            Self.transcriptionCenterLog.notice(
                "Cancel recording \(recordingID.uuidString, privacy: .public): jobs=\(initialJobs.count)"
            )
            let speakerJobIDs = Set(initialJobs.compactMap { job in
                (job.kind == .speakerEmbedding || job.kind == .speakerFinalization)
                    && job.state != .completed ? job.recordingID : nil
            })
            for rID in speakerJobIDs {
                pendingSpeakerFinalizationIDs.remove(rID)
                await speakerFinalizationCoordinator.invalidate(recordingID: rID)
            }
            await transcriptionScheduler.cancel(recordingID: recordingID)

            let now = Date()
            for var job in try await repository.jobs(recordingID: recordingID) where
                (job.kind == .transcription || job.kind == .speakerEmbedding || job.kind == .speakerFinalization)
                    && job.state != .completed {
                job.state = .cancelled
                job.lastError = nil
                job.executionToken = nil
                job.startedAt = nil
                job.terminationReason = "userCancelled"
                job.updatedAt = now
                try await repository.upsertJob(job, at: now)
            }
            Self.transcriptionCenterLog.notice("Cancel recording persisted")
        } catch {
            Self.transcriptionCenterLog.error("Cancel recording failed: \(error.localizedDescription)")
        }
    }

    func cancelProcessing(recordingID: UUID) async {
        await cancelProcessingTasks(recordingID: recordingID)
        notice = "已取消该录音尚未完成的处理任务。"
        await refresh()
    }

    func markProcessingCompleted(recordingID: UUID) async {
        Self.transcriptionCenterLog.notice(
            "Manual completion: \(recordingID.uuidString, privacy: .public)"
        )
        await cancelProcessing(recordingID: recordingID)
        do {
            let now = Date()
            for _ in 0..<2 {
                for var job in try await repository.jobs(recordingID: recordingID) where
                    (job.kind == .transcription || job.kind == .speakerEmbedding || job.kind == .speakerFinalization)
                        && job.state != .completed {
                    job.state = .completed
                    job.lastError = nil
                    job.executionToken = nil
                    job.startedAt = nil
                    job.terminationReason = "userMarkedComplete"
                    job.updatedAt = now
                    try await repository.upsertJob(job, at: now)
                }
                _ = try await completionReconciler.reconcile(recordingID: recordingID, at: now)
            }
            notice = "已标记为完成；现有转写和声纹数据均已保留。"
        } catch {
            notice = "标记完成失败：\(error.localizedDescription)"
        }
        await refresh()
    }

    func restartCancelledProcessing(recordingID: UUID) async {
        do {
            let jobs = try await repository.jobs(recordingID: recordingID)
            let cancelledTranscription = jobs.filter {
                $0.kind == .transcription && $0.state == .cancelled
            }
            let cancelledSpeakerJobs = jobs.filter {
                ($0.kind == .speakerEmbedding || $0.kind == .speakerFinalization)
                    && $0.state == .cancelled
            }
            guard !cancelledTranscription.isEmpty || !cancelledSpeakerJobs.isEmpty else {
                notice = "当前录音没有已取消的任务。"
                await refresh()
                return
            }

            try await coordinator.retryProcessing(recordingID: recordingID)
            if !cancelledTranscription.isEmpty {
                _ = try await resetCancelledSpeakerJobs(recordingID: recordingID)
                try await prepareSpeakerFinalizationForRetranscription(recordingID: recordingID)
                for job in cancelledTranscription {
                    try await transcriptionScheduler.enqueue(
                        recordingID: recordingID,
                        chunkID: job.chunkID,
                        processingRangeID: job.processingRangeID,
                        onOutcome: { [weak self] outcome in
                            await self?.applyTranscriptionOutcome(outcome)
                        }
                    )
                }
                await backgroundTranscriptionContinuation.beginUserInitiatedTask()
                notice = "已重新开始 \(cancelledTranscription.count) 个已取消的转写任务。"
            } else if try await resetCancelledSpeakerJobs(recordingID: recordingID) {
                enqueueSpeakerFinalization(recordingIDs: [recordingID])
                notice = "已重新开始已取消的说话人识别。"
            }
        } catch {
            notice = "重新开始任务失败：\(error.localizedDescription)"
        }
        await refresh()
    }

    func retryProcessingTask(recordingID: UUID, stage: ProcessingTaskStage) async {
        do {
            let jobs = try await repository.jobs(recordingID: recordingID)
            switch stage {
            case .transcription:
                guard jobs.contains(where: {
                    $0.kind == .transcription && $0.state == .failed
                }) else {
                    notice = "该逐字稿任务没有需要重试的项目。"
                    await refresh()
                    return
                }
                await retryTranscription(recordingID: recordingID)
                return
            case .speakerProcessing:
                guard try await resetFailedSpeakerJobs(recordingID: recordingID) else {
                    notice = "该声文整理任务没有需要重试的项目。"
                    await refresh()
                    return
                }
                try await coordinator.retryProcessing(recordingID: recordingID)
                let updatedJobs = try await repository.jobs(recordingID: recordingID)
                let transcription = updatedJobs.filter { $0.kind == .transcription }
                if !transcription.isEmpty,
                   transcription.allSatisfy({ $0.state == .completed }) {
                    enqueueSpeakerFinalization(recordingIDs: [recordingID])
                    notice = "已重新排队声文整理。"
                } else {
                    notice = "声文整理已恢复为待办，将在逐字稿识别完成后开始。"
                }
            }
        } catch {
            notice = "重试任务失败：\(error.localizedDescription)"
        }
        await refresh()
    }

    func cancelProcessingTask(recordingID: UUID, stage: ProcessingTaskStage) async {
        do {
            let now = Date()
            switch stage {
            case .transcription:
                await transcriptionScheduler.cancel(recordingID: recordingID)
                for var job in try await repository.jobs(recordingID: recordingID) where
                    job.kind == .transcription && job.state != .completed
                {
                    job.state = .cancelled
                    job.lastError = nil
                    job.executionToken = nil
                    job.startedAt = nil
                    job.terminationReason = "userCancelled"
                    job.updatedAt = now
                    try await repository.upsertJob(job, at: now)
                }
                notice = "已取消该录音的逐字稿识别任务。"
            case .speakerProcessing:
                pendingSpeakerFinalizationIDs.remove(recordingID)
                await speakerFinalizationCoordinator.invalidate(recordingID: recordingID)
                let jobs = try await repository.jobs(recordingID: recordingID)
                var foundFinalization = false
                for var job in jobs where
                    job.kind == .speakerEmbedding || job.kind == .speakerFinalization
                {
                    if job.kind == .speakerFinalization { foundFinalization = true }
                    guard job.state != .completed else { continue }
                    job.state = .cancelled
                    job.lastError = nil
                    job.executionToken = nil
                    job.startedAt = nil
                    job.terminationReason = "userCancelled"
                    job.updatedAt = now
                    try await repository.upsertJob(job, at: now)
                }
                if !foundFinalization {
                    try await repository.upsertJob(RecordingJob(
                        recordingID: recordingID,
                        kind: .speakerFinalization,
                        state: .cancelled,
                        attemptCount: 0,
                        lastError: nil,
                        terminationReason: "userCancelled",
                        createdAt: now,
                        updatedAt: now
                    ), at: now)
                }
                notice = "已取消该录音的声文整理任务。"
            }
        } catch {
            notice = "取消任务失败：\(error.localizedDescription)"
        }
        await refresh()
    }

    func markProcessingTaskCompleted(recordingID: UUID, stage: ProcessingTaskStage) async {
        do {
            let now = Date()
            switch stage {
            case .transcription:
                await transcriptionScheduler.cancel(recordingID: recordingID)
                for var job in try await repository.jobs(recordingID: recordingID) where
                    job.kind == .transcription && job.state != .completed
                {
                    job.state = .completed
                    job.lastError = nil
                    job.executionToken = nil
                    job.startedAt = nil
                    job.terminationReason = "userMarkedComplete"
                    job.updatedAt = now
                    try await repository.upsertJob(job, at: now)
                }
                let reconciliation = try await completionReconciler.reconcile(
                    recordingID: recordingID,
                    at: now
                )
                if case .needsSpeakerFinalization = reconciliation {
                    enqueueSpeakerFinalization(recordingIDs: [recordingID])
                }
                notice = "已将逐字稿识别阶段标记为完成。"
            case .speakerProcessing:
                pendingSpeakerFinalizationIDs.remove(recordingID)
                await speakerFinalizationCoordinator.invalidate(recordingID: recordingID)
                var jobs = try await repository.jobs(recordingID: recordingID)
                for var job in jobs where
                    (job.kind == .speakerEmbedding || job.kind == .speakerFinalization)
                        && job.state != .completed
                {
                    job.state = .completed
                    job.lastError = nil
                    job.executionToken = nil
                    job.startedAt = nil
                    job.terminationReason = "userMarkedComplete"
                    if job.kind == .speakerFinalization {
                        job.pipelineVersion = SpeakerFinalizationJob.currentPipelineVersion
                    }
                    job.updatedAt = now
                    try await repository.upsertJob(job, at: now)
                }
                jobs = try await repository.jobs(recordingID: recordingID)
                if !jobs.contains(where: { $0.kind == .speakerFinalization }) {
                    try await repository.upsertJob(RecordingJob(
                        recordingID: recordingID,
                        kind: .speakerFinalization,
                        state: .completed,
                        attemptCount: 0,
                        lastError: nil,
                        pipelineVersion: SpeakerFinalizationJob.currentPipelineVersion,
                        terminationReason: "userMarkedComplete",
                        createdAt: now,
                        updatedAt: now
                    ), at: now)
                }
                _ = try await completionReconciler.reconcile(recordingID: recordingID, at: now)
                notice = "已将声文整理阶段标记为完成，现有逐字稿保持不变。"
            }
        } catch {
            notice = "标记完成失败：\(error.localizedDescription)"
        }
        await refresh()
    }

    func restartCancelledProcessingTask(
        recordingID: UUID,
        stage: ProcessingTaskStage
    ) async {
        do {
            let jobs = try await repository.jobs(recordingID: recordingID)
            switch stage {
            case .transcription:
                guard jobs.contains(where: {
                    $0.kind == .transcription && $0.state == .cancelled
                }) else {
                    notice = "该逐字稿任务没有已取消的项目。"
                    await refresh()
                    return
                }
                await retryTranscription(recordingID: recordingID)
                return
            case .speakerProcessing:
                guard try await resetCancelledSpeakerJobs(recordingID: recordingID) else {
                    notice = "该声文整理任务没有已取消的项目。"
                    await refresh()
                    return
                }
                try await coordinator.retryProcessing(recordingID: recordingID)
                let updatedJobs = try await repository.jobs(recordingID: recordingID)
                let transcription = updatedJobs.filter { $0.kind == .transcription }
                if !transcription.isEmpty,
                   transcription.allSatisfy({ $0.state == .completed }) {
                    enqueueSpeakerFinalization(recordingIDs: [recordingID])
                    notice = "已重新开始声文整理。"
                } else {
                    notice = "声文整理已回到待办，将在逐字稿识别完成后开始。"
                }
            }
        } catch {
            notice = "重新开始任务失败：\(error.localizedDescription)"
        }
        await refresh()
    }

    func backgroundTranscriptionPreferenceChanged() async {
        await backgroundTranscriptionContinuation.preferenceDidChange()
        await refresh()
    }

    func resumeAllTranscriptionJobs() async {
        await transcriptionScheduler.resumeAll { [weak self] outcome in
            await self?.applyTranscriptionOutcome(outcome)
        }
        await backgroundTranscriptionContinuation.beginUserInitiatedTask()
        notice = "已恢复全部转写任务。"
        await refresh()
    }

    func forceReconcileAndResume() async {
        await runRecovery()
        await transcriptionScheduler.requestDrain()
        notice = "已强制检查并触发转写调度恢复。"
        await refresh()
    }

    func fetchTranscriptionQueueStatus() async -> TranscriptionQueueStatus {
        var status = TranscriptionQueueStatus()
        status.isPurchaseLocked = TrialQuotaLedger.isManualTrialEnabled && trialLedger.isPurchaseLocked
        status.thermalState = {
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: "正常 (Nominal)"
            case .fair: "轻微发热 (Fair)"
            case .serious: "较热 (Serious)"
            case .critical: "过热降频 (Critical)"
            @unknown default: "未知"
            }
        }()

        do {
            let allRecordings = try await repository.recordings()
            var items: [RecordingProcessingTaskItem] = []
            for recording in allRecordings {
                let jobs = try await repository.jobs(recordingID: recording.id)
                let transcriptionJobs = jobs.filter { $0.kind == .transcription }
                guard !transcriptionJobs.isEmpty else { continue }
                let embeddingJobs = jobs.filter { $0.kind == .speakerEmbedding }
                let finalization = jobs
                    .filter { $0.kind == .speakerFinalization }
                    .max(by: { $0.updatedAt < $1.updatedAt })
                let transcription = Self.processingProgress(
                    jobs: transcriptionJobs,
                    total: transcriptionJobs.count
                )
                let title = recording.title?.isEmpty == false
                    ? recording.title!
                    : (recording.isMeeting ? "未命名会议" : "未命名录音")
                let transcriptionState = Self.processingTaskState(progress: transcription)
                let transcriptionUpdatedAt = transcriptionJobs.map(\.updatedAt).max()
                    ?? recording.updatedAt
                let transcriptionError = transcriptionJobs
                    .filter { $0.state == .failed }
                    .sorted { $0.updatedAt > $1.updatedAt }
                    .first?.lastError

                items.append(RecordingProcessingTaskItem(
                    id: "\(recording.id.uuidString)-transcription",
                    recordingID: recording.id,
                    recordingTitle: title,
                    stage: .transcription,
                    state: transcriptionState,
                    progress: transcription,
                    speakerFinalizationState: nil,
                    dependencyMessage: nil,
                    lastError: transcriptionError,
                    updatedAt: transcriptionUpdatedAt
                ))

                guard recording.speakerProcessingEnabled else { continue }
                let expectedEmbeddingCount = max(transcriptionJobs.count, embeddingJobs.count)
                let speakerProgress = Self.processingProgress(
                    jobs: embeddingJobs,
                    total: expectedEmbeddingCount
                )
                let speakerState = Self.speakerProcessingTaskState(
                    transcription: transcription,
                    embedding: speakerProgress,
                    finalization: finalization
                )
                let speakerJobs = embeddingJobs + [finalization].compactMap { $0 }
                let speakerError = speakerJobs
                    .filter { $0.state == .failed }
                    .sorted { $0.updatedAt > $1.updatedAt }
                    .first?.lastError
                let speakerUpdatedAt = speakerJobs.map(\.updatedAt).max() ?? recording.updatedAt
                let dependencyMessage = transcription.isComplete
                    ? nil
                    : "等待逐字稿识别完成"
                items.append(RecordingProcessingTaskItem(
                    id: "\(recording.id.uuidString)-speakerProcessing",
                    recordingID: recording.id,
                    recordingTitle: title,
                    stage: .speakerProcessing,
                    state: speakerState,
                    progress: speakerProgress,
                    speakerFinalizationState: finalization?.state,
                    dependencyMessage: dependencyMessage,
                    lastError: speakerError,
                    updatedAt: speakerUpdatedAt
                ))
            }

            let sorted = items.sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id < $1.id
            }
            status.todoTasks = sorted.filter { $0.state == .todo }
            status.runningTasks = sorted.filter { $0.state == .running }
            status.failedTasks = sorted.filter { $0.state == .failed }
            status.cancelledTasks = sorted.filter { $0.state == .cancelled }
            status.completedTasks = sorted.filter { $0.state == .completed }
        } catch {
            // fallback empty status
        }
        return status
    }

    private nonisolated static func processingTaskState(
        progress: ProcessingStageProgress
    ) -> ProcessingTaskState {
        if progress.failed > 0 { return .failed }
        if progress.running > 0 { return .running }
        if progress.pending > 0 { return .todo }
        if progress.isComplete { return .completed }
        if progress.cancelled > 0 { return .cancelled }
        return .todo
    }

    private nonisolated static func speakerProcessingTaskState(
        transcription: ProcessingStageProgress,
        embedding: ProcessingStageProgress,
        finalization: RecordingJob?
    ) -> ProcessingTaskState {
        if embedding.failed > 0 || finalization?.state == .failed { return .failed }
        if embedding.running > 0 || finalization?.state == .running { return .running }
        if finalization?.state == .completed { return .completed }
        if embedding.cancelled > 0 || finalization?.state == .cancelled { return .cancelled }
        guard transcription.isComplete else { return .todo }
        if embedding.pending > 0 || finalization?.state == .pending { return .todo }
        return .todo
    }

    private nonisolated static func processingProgress(
        jobs: [RecordingJob],
        total: Int
    ) -> ProcessingStageProgress {
        ProcessingStageProgress(
            completed: jobs.filter { $0.state == .completed }.count,
            total: total,
            running: jobs.filter { $0.state == .running }.count,
            pending: jobs.filter { $0.state == .pending }.count,
            failed: jobs.filter { $0.state == .failed }.count,
            cancelled: jobs.filter { $0.state == .cancelled }.count
        )
    }

    /// Files picker entry: privately copy audio, plan ProcessingRanges, enqueue
    /// offline transcription. Does not touch the microphone session.
    @discardableResult
    func importAudio(
        from sourceURL: URL,
        title: String? = nil,
        isMeeting: Bool = false
    ) async -> UUID? {
        guard beginImportActivity(sourceLabel: sourceURL.lastPathComponent, phase: .queued) else {
            return nil
        }
        defer { clearImportActivity() }
        return await performAudioImport(
            from: sourceURL,
            title: title,
            isMeeting: isMeeting,
            sourceFilenameOverride: nil,
            sourceUTTypeOverride: nil
        )
    }

    /// Photos/Videos entry: extract the audio track (no duration cap), then run
    /// the same ImportedAudioAsset / ProcessingRange pipeline as Files audio.
    /// Heavy extract/copy work runs off the main actor so mic capture can start.
    @discardableResult
    func importVideoAudio(
        from videoURL: URL,
        sourceFilename: String? = nil,
        title: String? = nil,
        isMeeting: Bool = false
    ) async -> UUID? {
        let label: String = {
            if let sourceFilename,
               !sourceFilename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return sourceFilename
            }
            return videoURL.lastPathComponent
        }()
        guard beginImportActivity(sourceLabel: label, phase: .queued) else {
            return nil
        }
        defer {
            clearImportActivity()
            // Temp movie copies from PhotosPicker live outside the private tree.
            if videoURL.path.contains("VoiceContext-PickedVideo-") {
                try? FileManager.default.removeItem(at: videoURL)
            }
        }

        notice = nil
        updateImportPhase(.preparing)
        let extractedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceContext-ExtractedAudio-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: extractedURL) }

        do {
            updateImportPhase(.extractingAudio(progress: 0))
            _ = try await Task.detached(priority: .userInitiated) {
                try await ImportVideoAudioExtractor.extractAudioTrack(
                    from: videoURL,
                    to: extractedURL,
                    progressHandler: { progress in
                        Task { @MainActor [weak self] in
                            self?.updateImportPhase(.extractingAudio(progress: progress))
                        }
                    }
                )
            }.value
        } catch {
            notice = "导入失败：\(error.localizedDescription)"
            await refresh()
            return nil
        }

        let displayName: String = {
            if let sourceFilename, !sourceFilename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let base = (sourceFilename as NSString).deletingPathExtension
                return base.isEmpty ? "\(sourceFilename).m4a" : "\(base).m4a"
            }
            let base = (videoURL.lastPathComponent as NSString).deletingPathExtension
            return base.isEmpty ? extractedURL.lastPathComponent : "\(base).m4a"
        }()

        return await performAudioImport(
            from: extractedURL,
            title: title,
            isMeeting: isMeeting,
            sourceFilenameOverride: displayName,
            sourceUTTypeOverride: UTType.mpeg4Audio.identifier
        )
    }

    private func performAudioImport(
        from sourceURL: URL,
        title: String?,
        isMeeting: Bool,
        sourceFilenameOverride: String?,
        sourceUTTypeOverride: String?
    ) async -> UUID? {
        notice = nil
        updateImportPhase(.importing)
        let rootURL = repository.rootURL
        do {
            let imported = try await Task.detached(priority: .userInitiated) {
                try ImportAudioImporter().importAudio(
                    from: sourceURL,
                    into: rootURL,
                    title: title,
                    isMeeting: isMeeting,
                    sourceFilenameOverride: sourceFilenameOverride,
                    sourceUTTypeOverride: sourceUTTypeOverride
                )
            }.value
            try await repository.commitImportedAudio(
                recording: imported.recording,
                asset: imported.asset,
                ranges: imported.ranges,
                at: imported.recording.startedAt
            )
            updateImportPhase(.enqueueing)
            for range in imported.ranges {
                try await transcriptionScheduler.enqueue(
                    recordingID: imported.recording.id,
                    processingRangeID: range.id,
                    onOutcome: { [weak self] outcome in
                        await self?.applyTranscriptionOutcome(outcome)
                    }
                )
            }
            await backgroundTranscriptionContinuation.beginUserInitiatedTask()
            notice = "已导入 \(imported.asset.sourceFilename)，共 \(imported.ranges.count) 个处理范围"
            await refresh()
            return imported.recording.id
        } catch {
            notice = "导入失败：\(error.localizedDescription)"
            await refresh()
            return nil
        }
    }

    /// Returns `false` when another import is already running; caller should abort.
    @discardableResult
    private func beginImportActivity(sourceLabel: String, phase: ImportActivity.Phase) -> Bool {
        if importTaskRunning {
            notice = "已有导入任务进行中（排队提示）。新的麦克风录音不受影响，可随时开始。"
            return false
        }
        importTaskRunning = true
        let activity = ImportActivity(phase: phase, sourceLabel: sourceLabel)
        importActivity = activity
        notice = activity.statusText
        return true
    }

    private func updateImportPhase(_ phase: ImportActivity.Phase) {
        guard var activity = importActivity else { return }
        activity.phase = phase
        importActivity = activity
        notice = activity.statusText
    }

    private func clearImportActivity() {
        importActivity = nil
        importTaskRunning = false
    }

    func importedAudioAsset(recordingID: UUID) async throws -> ImportedAudioAsset? {
        try await repository.importedAudioAsset(recordingID: recordingID)
    }

    func processingRanges(recordingID: UUID) async throws -> [ProcessingRange] {
        try await repository.processingRanges(recordingID: recordingID)
    }

    /// The details surface reads the canonical JSON document. A nil value is
    /// truthful for pending/failed processing and is not an empty transcript.
    func transcript(recordingID: UUID) async throws -> TranscriptDocumentV1? {
        try await transcriptStore.document(recordingID: recordingID)
    }

    /// Offline full-text search over titles + transcript plain text (FR-ADD-SRCH-*).
    /// Empty / whitespace queries return []; callers should show the normal list.
    func searchTranscripts(query: String) async throws -> [TranscriptSearchHit] {
        try await transcriptStore.search(query: query)
    }

    func exportPackage(
        recordingID: UUID,
        includeAudio: Bool = false
    ) async throws -> PublicExportPackage {
        guard let document = try await transcriptStore.document(recordingID: recordingID) else {
            throw PublicDocumentPublisher.PublishError.unresolvedRelativePath("Transcripts/" + recordingID.uuidString)
        }
        // Ensure Meetings/Daily mirrors exist before Share Sheet / Files handoff.
        let published = try await publishPublicDocuments(for: document)
        _ = try? await skillPackSeeder.seed()
        let jsonURL = try await publicDocumentPublisher.resolveURL(relativePath: published.jsonRelativePath)
        let markdownURL = try await publicDocumentPublisher.resolveURL(relativePath: published.markdownRelativePath)
        let consumer = await prepareConsumerExports(
            document: document,
            includeAudio: includeAudio
        )
        return PublicExportPackage(
            title: document.title ?? "",
            isMeeting: document.kind == "meeting",
            relativeJSONPath: published.jsonRelativePath,
            relativeMarkdownPath: published.markdownRelativePath,
            jsonURL: jsonURL,
            markdownURL: markdownURL,
            plainTextURL: consumer.plainTextURL,
            subtitlesURL: consumer.subtitlesURL,
            audioURL: consumer.audioURL,
            plainTextDisabledReason: consumer.plainTextDisabledReason,
            subtitlesDisabledReason: consumer.subtitlesDisabledReason,
            audioDisabledReason: consumer.audioDisabledReason
        )
    }

    func exportArchive(recordingID: UUID) async throws -> URL {
        let includesOriginalAudio = ExportPackagePreferences.includesOriginalAudio
        let package = try await exportPackage(
            recordingID: recordingID,
            includeAudio: includesOriginalAudio
        )
        let attachments = try await attachmentStore.attachments(recordingID: recordingID)
        var entries: [StreamingZipWriter.Entry] = []
        let candidates: [(URL?, String)] = [
            (package.plainTextURL, "transcript.txt"),
            (package.subtitlesURL, "transcript.srt"),
            (package.markdownURL, "transcript.md"),
            (package.jsonURL, "transcript.json"),
        ]
        for (url, name) in candidates where url.map({ FileManager.default.fileExists(atPath: $0.path) }) == true {
            entries.append(.init(sourceURL: url!, archivePath: name))
        }

        var usedAttachmentNames: Set<String> = []
        for attachment in attachments {
            let url = await attachmentStore.url(for: attachment)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let name = Self.uniqueArchiveFilename(
                attachment.originalFilename,
                used: &usedAttachmentNames
            )
            entries.append(.init(sourceURL: url, archivePath: "related/\(name)"))
        }

        if includesOriginalAudio,
           let audioURL = package.audioURL,
           FileManager.default.fileExists(atPath: audioURL.path) {
            let ext = audioURL.pathExtension.isEmpty ? "m4a" : audioURL.pathExtension
            entries.append(.init(sourceURL: audioURL, archivePath: "audio/original.\(ext)"))
        } else if includesOriginalAudio {
            notice = "原始录音当前不可用，资料包将包含其他可用内容。"
        }

        let sourceBytes = entries.reduce(Int64.zero) { partial, entry in
            let attributes = try? FileManager.default.attributesOfItem(atPath: entry.sourceURL.path)
            return partial + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }
        let available = try repository.rootURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage ?? Int64.max
        let reserve = max(Int64(10 * 1024 * 1024), sourceBytes / 10)
        guard available > sourceBytes + reserve else {
            throw NSError(
                domain: "VoiceContext.ExportArchive",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "可用空间不足，无法准备资料包。"]
            )
        }

        let exportID = UUID()
        let directory = repository.rootURL
            .appendingPathComponent("ExportStaging", isDirectory: true)
            .appendingPathComponent(recordingID.uuidString, isDirectory: true)
            .appendingPathComponent(exportID.uuidString, isDirectory: true)
        let baseTitle = package.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeTitle = RecordingAttachmentStore.safeDisplayFilename(
            baseTitle.isEmpty ? (package.isMeeting ? "未命名会议" : "未命名录音") : baseTitle
        )
        let outputURL = directory.appendingPathComponent("\(safeTitle).zip")
        do {
            try await Task.detached(priority: .userInitiated) {
                try StreamingZipWriter.write(entries: entries, to: outputURL)
            }.value
            return outputURL
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// Prepares an audio-only Share Sheet copy on demand. This deliberately
    /// stays out of the initial export screen load because multi-chunk audio
    /// may need a full local concatenation first.
    func exportShareableAudio(recordingID: UUID) async throws -> URL {
        guard let document = try await transcriptStore.document(recordingID: recordingID) else {
            throw PublicDocumentPublisher.PublishError.unresolvedRelativePath("Transcripts/" + recordingID.uuidString)
        }
        let chunks = try await repository.chunks(recordingID: recordingID)
        let imported = try await repository.importedAudioAsset(recordingID: recordingID)
        switch await ConsumerAudioExport.prepareShareableAudio(
            rootURL: repository.rootURL,
            title: document.title,
            recordingID: recordingID,
            chunks: chunks,
            importedAsset: imported
        ) {
        case let .available(url):
            return url
        case let .unavailable(reason):
            throw NSError(
                domain: "VoiceContext.ExportAudio",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: reason]
            )
        }
    }

    private nonisolated static func uniqueArchiveFilename(
        _ original: String,
        used: inout Set<String>
    ) -> String {
        let safe = RecordingAttachmentStore.safeDisplayFilename(original)
        let base = (safe as NSString).deletingPathExtension
        let ext = (safe as NSString).pathExtension
        var candidate = safe.isEmpty ? "相关文件" : safe
        var suffix = 2
        while used.contains(candidate.lowercased()) {
            let stem = base.isEmpty ? "相关文件" : base
            candidate = ext.isEmpty ? "\(stem) (\(suffix))" : "\(stem) (\(suffix)).\(ext)"
            suffix += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }

    private struct ConsumerExportArtifacts: Equatable, Sendable {
        var plainTextURL: URL?
        var subtitlesURL: URL?
        var audioURL: URL?
        var plainTextDisabledReason: String?
        var subtitlesDisabledReason: String?
        var audioDisabledReason: String?
    }

    /// Writes disposable txt/srt/audio copies for Share Sheet. Never mutates
    /// canonical Transcripts/ or private Recording audio paths (FR-ADD-EXP-006).
    private func prepareConsumerExports(
        document: TranscriptDocumentV1,
        includeAudio: Bool
    ) async -> ConsumerExportArtifacts {
        var artifacts = ConsumerExportArtifacts()
        let fileManager = FileManager.default
        let exportRoot = fileManager.temporaryDirectory
            .appendingPathComponent("VoiceContextConsumerExports", isDirectory: true)
            .appendingPathComponent(document.recordingID.uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        } catch {
            artifacts.plainTextDisabledReason = "无法准备导出目录。"
            artifacts.subtitlesDisabledReason = "无法准备导出目录。"
            artifacts.audioDisabledReason = "无法准备导出目录。"
            return artifacts
        }

        let baseName = ConsumerExportFileNaming.baseName(
            title: document.title,
            recordingID: document.recordingID
        )

        let plainText = TranscriptPlainTextRenderer.render(document)
        if plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            artifacts.plainTextDisabledReason = "尚无可导出的文本。"
        } else {
            let url = exportRoot.appendingPathComponent(baseName + ".txt")
            do {
                try Data(plainText.utf8).write(to: url, options: .atomic)
                artifacts.plainTextURL = url
            } catch {
                artifacts.plainTextDisabledReason = "无法写入文本导出。"
            }
        }

        if document.segments.isEmpty {
            artifacts.subtitlesDisabledReason = "尚无可用片段，无法生成字幕。"
        } else {
            let srt = TranscriptSRTRenderer.render(document)
            if srt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                artifacts.subtitlesDisabledReason = "尚无可用片段，无法生成字幕。"
            } else {
                let url = exportRoot.appendingPathComponent(baseName + ".srt")
                do {
                    try Data(srt.utf8).write(to: url, options: .atomic)
                    artifacts.subtitlesURL = url
                } catch {
                    artifacts.subtitlesDisabledReason = "无法写入字幕导出。"
                }
            }
        }

        if includeAudio {
            do {
                let chunks = try await repository.chunks(recordingID: document.recordingID)
                let imported = try await repository.importedAudioAsset(recordingID: document.recordingID)
                switch await ConsumerAudioExport.prepareShareableAudio(
                    rootURL: repository.rootURL,
                    title: document.title,
                    recordingID: document.recordingID,
                    chunks: chunks,
                    importedAsset: imported
                ) {
                case let .available(url):
                    artifacts.audioURL = url
                case let .unavailable(reason):
                    artifacts.audioDisabledReason = reason
                }
            } catch {
                artifacts.audioDisabledReason = "无法准备音频分享。"
            }
        }

        return artifacts
    }


    /// Persist user edits to the canonical transcript, rebuild Markdown, bump
    /// revision once, sync Recording title, and best-effort republish public docs.
    /// Never advances an incomplete job to `complete`.
    @discardableResult
    func saveTranscriptEdits(
        recordingID: UUID,
        title: String?,
        tags: [String],
        segmentTexts: [UUID: String]
    ) async throws -> TranscriptDocumentV1 {
        guard let document = try await transcriptStore.document(recordingID: recordingID) else {
            throw PublicDocumentPublisher.PublishError.unresolvedRelativePath("Transcripts/" + recordingID.uuidString)
        }
        let edited = document.applyingUserEdits(
            title: title,
            tags: tags,
            segmentTexts: segmentTexts
        )
        try await transcriptStore.write(edited)
        try? await repository.setRecordingTitle(
            recordingID: recordingID,
            title: edited.title,
            at: Date()
        )
        do {
            try await publishPublicDocuments(for: edited)
        } catch {
            notice = "文稿已保存，公开目录同步稍后可重试：" + error.localizedDescription
        }
        await refresh()
        return edited
    }

    func saveRecordingMetadata(
        recordingID: UUID,
        title: String?,
        tags: [String] = [],
        locationName: String? = nil
    ) async throws {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = (trimmedTitle?.isEmpty == false) ? trimmedTitle : nil
        try await repository.setRecordingTitle(
            recordingID: recordingID,
            title: finalTitle,
            at: Date()
        )
        if let locationName {
            let trimmedLocation = locationName.trimmingCharacters(in: .whitespacesAndNewlines)
            try await repository.setRecordingLocation(
                recordingID: recordingID,
                locationName: trimmedLocation.isEmpty ? nil : trimmedLocation,
                at: Date()
            )
        }
        if let document = try? await transcriptStore.document(recordingID: recordingID) {
            let updated = document.applyingUserEdits(
                title: finalTitle,
                tags: tags.isEmpty ? document.tags : tags,
                segmentTexts: [:]
            )
            try await transcriptStore.write(updated)
            _ = try? await publishPublicDocuments(for: updated)
        }
        await refresh()
    }

    func updateRecordingLocation(
        recordingID: UUID,
        locationName: String?
    ) async {
        let trimmed = locationName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalLocation = (trimmed?.isEmpty == false) ? trimmed : nil
        try? await repository.setRecordingLocation(
            recordingID: recordingID,
            locationName: finalLocation,
            at: Date()
        )
        await refresh()
    }

    func saveRecordingMemo(
        recordingID: UUID,
        memo: String?
    ) async throws {
        try await repository.setRecordingMemo(
            recordingID: recordingID,
            memo: memo,
            at: Date()
        )
        await refresh()
    }

    func recordingAttachments(recordingID: UUID) async throws -> [RecordingAttachment] {
        try await attachmentStore.attachments(recordingID: recordingID)
    }

    func addRecordingAttachments(
        from urls: [URL],
        recordingID: UUID
    ) async throws -> [RecordingAttachment] {
        let added = try await attachmentStore.add(urls, recordingID: recordingID)
        notice = "已添加 \(added.count) 个相关文件。"
        return added
    }

    func removeRecordingAttachment(_ attachment: RecordingAttachment) async throws {
        try await attachmentStore.remove(id: attachment.id, recordingID: attachment.recordingID)
        notice = "已移除相关文件，Files 中的原文件不受影响。"
    }

    func recordingAttachmentURL(_ attachment: RecordingAttachment) async -> URL {
        await attachmentStore.url(for: attachment)
    }

    func enableSpeakerRecognition(recordingID: UUID) async {
        do {
            guard let recording = try await repository.recording(id: recordingID) else { return }
            try await repository.setRecordingMeeting(
                recordingID: recordingID,
                isMeeting: true,
                at: Date()
            )
            try await prepareSpeakerFinalizationForRetranscription(recordingID: recordingID)
            try await coordinator.retryProcessing(recordingID: recordingID)

            let jobs = try await repository.jobs(recordingID: recordingID)
            let transcription = jobs.filter { $0.kind == .transcription }
            if transcription.allSatisfy({ $0.state == .completed }) && !transcription.isEmpty {
                enqueueSpeakerFinalization(recordingIDs: [recordingID])
                notice = "已启动说话人声纹识别任务。"
            } else {
                notice = "已启用说话人识别，将在转写完成后自动执行。"
            }
        } catch {
            notice = "启用说话人识别失败：\(error.localizedDescription)"
        }
        await refresh()
    }

    func deleteRecording(id: UUID) async {
        if id == activeRecordingID || id == coordinator.activeRecordingID {
            await coordinator.cancel(recordingID: id)
            activeRecordingID = nil
            sessionProgress = nil
        }
        await cancelProcessingTasks(recordingID: id)
        do {
            try await repository.deleteRecording(id: id)
            try await transcriptStore.delete(recordingID: id)
            try? await attachmentStore.removeAll(recordingID: id)
            _ = try? await folderCatalogStore.moveRecording(id, to: nil)
            notice = "已删除录音。"
        } catch {
            notice = "删除录音失败：\(error.localizedDescription)"
        }
        await refresh()
    }

    func deleteRecordings(ids: Set<UUID>) async {
        guard !ids.isEmpty else { return }
        if let activeID = activeRecordingID ?? coordinator.activeRecordingID, ids.contains(activeID) {
            await coordinator.cancel(recordingID: activeID)
            activeRecordingID = nil
            sessionProgress = nil
        }
        for id in ids {
            await cancelProcessingTasks(recordingID: id)
        }
        for id in ids {
            try? await repository.deleteRecording(id: id)
            try? await transcriptStore.delete(recordingID: id)
            try? await attachmentStore.removeAll(recordingID: id)
            _ = try? await folderCatalogStore.moveRecording(id, to: nil)
        }
        notice = "已批量删除 \(ids.count) 条录音。"
        await refresh()
    }

    @discardableResult
    func saveSingleSegmentText(
        recordingID: UUID,
        segmentID: UUID,
        text: String
    ) async throws -> TranscriptDocumentV1 {
        guard let document = try await transcriptStore.document(recordingID: recordingID) else {
            throw PublicDocumentPublisher.PublishError.unresolvedRelativePath("Transcripts/" + recordingID.uuidString)
        }
        let edited = document.applyingUserEdits(
            title: document.title,
            tags: document.tags,
            segmentTexts: [segmentID: text]
        )
        try await transcriptStore.write(edited)
        do {
            try await publishPublicDocuments(for: edited)
        } catch {
            // best effort
        }
        await refresh()
        return edited
    }

    @discardableResult
    func assignSpeaker(
        recordingID: UUID,
        segmentID: UUID,
        speaker: String
    ) async throws -> TranscriptDocumentV1 {
        guard let document = try await transcriptStore.document(recordingID: recordingID) else {
            throw PublicDocumentPublisher.PublishError.unresolvedRelativePath("Transcripts/" + recordingID.uuidString)
        }
        let edited = document.applyingSpeakerAssignment(segmentID: segmentID, speaker: speaker)
        guard edited != document else { return document }

        try await transcriptStore.write(edited)
        do {
            try await publishPublicDocuments(for: edited)
        } catch {
            notice = "说话人已更新，公开目录同步稍后可重试：" + error.localizedDescription
        }
        await refresh()
        return edited
    }

    func speakerBindings(recordingID: UUID) async throws -> [MeetingSpeakerBinding] {
        try MeetingSpeakerBindingStore.load(
            rootURL: repository.rootURL,
            recordingID: recordingID
        )
    }

    @discardableResult
    func addMeetingParticipant(
        recordingID: UUID,
        name: String
    ) async throws -> TranscriptDocumentV1 {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MeetingParticipantError.emptyName }
        return try await addMeetingParticipant(
            recordingID: recordingID,
            participant: TranscriptDocumentV1.Participant(name: trimmed)
        )
    }

    @discardableResult
    func addMeetingParticipant(
        recordingID: UUID,
        client: ClientProfile
    ) async throws -> TranscriptDocumentV1 {
        try await addMeetingParticipant(
            recordingID: recordingID,
            participant: TranscriptDocumentV1.Participant(
                clientID: client.id,
                name: client.name,
                organization: client.organization,
                roleOrTitle: client.roleOrTitle
            )
        )
    }

    private func addMeetingParticipant(
        recordingID: UUID,
        participant: TranscriptDocumentV1.Participant
    ) async throws -> TranscriptDocumentV1 {
        guard try await repository.recording(id: recordingID)?.isMeeting == true else {
            throw MeetingParticipantError.notMeeting
        }
        guard let document = try await transcriptStore.document(recordingID: recordingID) else {
            throw MeetingParticipantError.transcriptUnavailable
        }
        return try await saveMeetingParticipantDocument(document.addingParticipant(participant))
    }

    private func saveMeetingParticipantDocument(
        _ document: TranscriptDocumentV1
    ) async throws -> TranscriptDocumentV1 {
        try await transcriptStore.write(document)
        do {
            try await publishPublicDocuments(for: document)
        } catch {
            notice = "参会人已保存，公开目录同步稍后可重试：" + error.localizedDescription
        }
        await refresh()
        return document
    }

    @discardableResult
    func confirmSpeakerIdentity(
        recordingID: UUID,
        temporaryLabel: String,
        displayName: String
    ) async throws -> (TranscriptDocumentV1?, [MeetingSpeakerBinding]) {
        try await mutateSpeakerIdentity(recordingID: recordingID) { bindings, archive in
            try SpeakerIdentityConfirmation.confirm(
                temporaryLabel: temporaryLabel,
                displayName: displayName,
                bindings: &bindings,
                archive: &archive
            )
        }
    }

    /// A user created from a meeting speaker becomes a reusable global client
    /// and a fresh long-term voiceprint identity in the same confirmed action.
    @discardableResult
    func createClientAndConfirmSpeakerIdentity(
        recordingID: UUID,
        temporaryLabel: String,
        client: ClientProfile
    ) async throws -> (TranscriptDocumentV1?, [MeetingSpeakerBinding]) {
        var confirmedVoiceprintID: UUID?
        let result = try await mutateSpeakerIdentity(recordingID: recordingID) { bindings, archive in
            let identity = try SpeakerIdentityConfirmation.confirm(
                temporaryLabel: temporaryLabel,
                displayName: client.name,
                allowSuspectedIdentityReuse: false,
                bindings: &bindings,
                archive: &archive
            )
            confirmedVoiceprintID = identity.id
        }
        guard let confirmedVoiceprintID else {
            throw SpeakerIdentityConfirmation.ActionError.missingArchiveIdentity
        }
        var linkedClient = client
        linkedClient.voiceprintIdentityID = confirmedVoiceprintID
        clientCatalog = try await clientCatalogStore.upsertClient(linkedClient)
        await refresh()
        return result
    }

    @discardableResult
    func denySpeakerIdentity(
        recordingID: UUID,
        temporaryLabel: String
    ) async throws -> (TranscriptDocumentV1?, [MeetingSpeakerBinding]) {
        try await mutateSpeakerIdentity(recordingID: recordingID) { bindings, archive in
            try SpeakerIdentityConfirmation.deny(
                temporaryLabel: temporaryLabel,
                bindings: &bindings
            )
        }
    }

    @discardableResult
    func renameSpeakerIdentity(
        recordingID: UUID,
        temporaryLabel: String,
        displayName: String
    ) async throws -> (TranscriptDocumentV1?, [MeetingSpeakerBinding]) {
        try await mutateSpeakerIdentity(recordingID: recordingID) { bindings, archive in
            _ = try SpeakerIdentityConfirmation.rename(
                temporaryLabel: temporaryLabel,
                displayName: displayName,
                bindings: &bindings,
                archive: &archive
            )
        }
    }

    @discardableResult
    func assignMeetingSpeakerAlias(
        recordingID: UUID,
        temporaryLabel: String,
        displayName: String
    ) async throws -> (TranscriptDocumentV1?, [MeetingSpeakerBinding]) {
        try await mutateSpeakerIdentity(recordingID: recordingID) { bindings, _ in
            try SpeakerIdentityConfirmation.assignMeetingAlias(
                temporaryLabel: temporaryLabel,
                displayName: displayName,
                bindings: &bindings
            )
        }
    }

    private func mutateSpeakerIdentity(
        recordingID: UUID,
        _ body: (inout [MeetingSpeakerBinding], inout VoiceprintArchive) throws -> Void
    ) async throws -> (TranscriptDocumentV1?, [MeetingSpeakerBinding]) {
        var bindings = try MeetingSpeakerBindingStore.load(
            rootURL: repository.rootURL,
            recordingID: recordingID
        )
        if bindings.isEmpty, let document = try await transcriptStore.document(recordingID: recordingID) {
            bindings = document.speakers.map {
                MeetingSpeakerBinding(temporaryLabel: $0, state: .unknown)
            }
        }
        var archive = try VoiceprintArchiveStorage.load(
            from: voiceprintArchiveURL,
            keyProvider: voiceprintKeyProvider
        )
        try body(&bindings, &archive)
        let syncEnabled = OnboardingPreferences().encryptedVoiceprintSyncEnabled
        _ = try VoiceprintArchiveStorage.saveAndSync(
            archive,
            to: voiceprintArchiveURL,
            keyProvider: voiceprintKeyProvider,
            synchronizableKey: syncEnabled,
            syncConfiguration: voiceprintSyncConfiguration
        )
        try MeetingSpeakerBindingStore.save(
            bindings,
            rootURL: repository.rootURL,
            recordingID: recordingID
        )

        var updatedDocument: TranscriptDocumentV1?
        if let document = try await transcriptStore.document(recordingID: recordingID) {
            let mapping = TranscriptDocumentV1.speakerDisplayMapping(from: bindings)
            if !mapping.isEmpty {
                let edited = document.applyingSpeakerLabelMapping(mapping)
                try await transcriptStore.write(edited)
                do {
                    try await publishPublicDocuments(for: edited)
                } catch {
                    notice = "说话人已更新，公开目录同步稍后可重试：" + error.localizedDescription
                }
                updatedDocument = edited
            } else {
                updatedDocument = document
            }
        }
        await refresh()
        return (updatedDocument, bindings)
    }

    @discardableResult
    func publishPublicDocuments(for document: TranscriptDocumentV1) async throws -> PublicDocumentPublishResult {
        try await Self.publishPublicDocuments(
            document: document,
            repository: repository,
            transcriptStore: transcriptStore,
            publisher: publicDocumentPublisher
        )
    }

    /// Copies bundled Skill + Templates into the public VoiceContext layout
    /// (local Documents; iCloud only when ubiquity is available).
    @discardableResult
    func seedSkillPack() async throws -> PublicSkillPackSeedResult {
        try await skillPackSeeder.seed()
    }

    /// CPU-only CAM++ pass over closed chunks or an imported private asset.
    /// Does not submit SenseVoice/Metal.
    private static func offlineSpeakerRecluster(
        recordingID: UUID,
        repository: RecordingRepository
    ) async throws -> OfflineSpeakerReclusterPass.PassResult {
        let resourceRoot = try OfflineSpeakerReclusterPass.bundledResourceRoot()
        if var asset = try await repository.importedAudioAsset(recordingID: recordingID),
           asset.audioRemovedAt == nil {
            var url = repository.rootURL.appendingPathComponent(asset.relativePath)
            // Imports share the same offline recluster path as mic chunks. If the
            // private copy cannot window-decode, standardize once before CAM++.
            if !asset.isStandardized,
               !ImportAudioStandardizer.supportsRandomAccess(at: url) {
                asset = try ImportAudioStandardizer.replaceWithStandardized(
                    asset: asset,
                    rootURL: repository.rootURL
                )
                try await repository.updateImportedAudioAsset(asset, at: Date())
                url = repository.rootURL.appendingPathComponent(asset.relativePath)
            }
            return try await OfflineSpeakerReclusterPass.runImportedAsset(
                url: url,
                totalSamples: asset.totalSamples,
                resourceRoot: resourceRoot
            )
        }
        let chunks = try await repository.chunks(recordingID: recordingID)
            .filter { $0.state == .closed && $0.audioRemovedAt == nil }
            .sorted { $0.startSample < $1.startSample }
        let chunkURLs = chunks.map {
            (
                url: repository.rootURL.appendingPathComponent($0.relativePath),
                startSample: $0.startSample
            )
        }
        return try await OfflineSpeakerReclusterPass.run(
            chunkURLs: chunkURLs,
            resourceRoot: resourceRoot
        )
    }

    private static func publishPublicDocuments(
        document: TranscriptDocumentV1,
        repository: RecordingRepository,
        transcriptStore: TranscriptDocumentStore,
        publisher: PublicDocumentPublisher
    ) async throws -> PublicDocumentPublishResult {
        let recordings = try await repository.recordings()
        var dayDocuments: [TranscriptDocumentV1] = []
        for recording in recordings where PublicDocumentLayout.isSameLocalDay(
            recording.startedAt,
            document.startedAt,
            timezoneIdentifier: document.timezone
        ) {
            if let peer = try await transcriptStore.document(recordingID: recording.id) {
                dayDocuments.append(peer)
            }
        }
        return try await publisher.publish(document: document, dayDocuments: dayDocuments)
    }

    func scenePhaseChanged(to phase: ScenePhaseLike) {
        switch phase {
        case .background:
            coordinator.applicationEnteredBackground()
            isInBackground = true
            let continuedProcessingRequested = backgroundTranscriptionContinuation.isExecutionRequested
            Task { [inferenceService, transcriptionScheduler] in
                await transcriptionScheduler.enteredBackground()
                if !continuedProcessingRequested {
                    _ = await inferenceService.enteredBackground()
                }
            }
        case .active:
            coordinator.applicationBecameActive()
            isInBackground = false
            if TrialQuotaLedger.isManualTrialEnabled {
                trialEntitlement.noteAppBecameActive()
            }
            Task { [inferenceService, transcriptionScheduler] in
                await inferenceService.enteredForeground()
                await transcriptionScheduler.enteredForeground()
            }
        default:
            break
        }
    }


    // MARK: - Folders (FR-ADD-FLD-*)

    var folders: [RecordingFolder] { folderCatalog.folders }

    func folderName(for recordingID: UUID) -> String? {
        folderCatalog.folderName(for: recordingID)
    }

    func folderID(for recordingID: UUID) -> UUID? {
        folderCatalog.folderID(for: recordingID)
    }

    @discardableResult
    func createFolder(named name: String) async throws -> RecordingFolder {
        folderCatalog = try await folderCatalogStore.createFolder(name: name)
        await synchronizeFolders()
        return try requireFolder(named: name)
    }

    @discardableResult
    func renameFolder(id: UUID, to name: String) async throws -> FolderCatalogDocument {
        folderCatalog = try await folderCatalogStore.renameFolder(id: id, to: name)
        await synchronizeFolders()
        return folderCatalog
    }

    /// Deletes folder metadata only; recordings become uncategorized.
    @discardableResult
    func deleteFolder(id: UUID) async throws -> FolderCatalogDocument {
        folderCatalog = try await folderCatalogStore.deleteFolder(id: id)
        await synchronizeFolders()
        return folderCatalog
    }

    @discardableResult
    func moveRecording(_ recordingID: UUID, toFolder folderID: UUID?) async throws -> FolderCatalogDocument {
        folderCatalog = try await folderCatalogStore.moveRecording(recordingID, to: folderID)
        await synchronizeFolders()
        return folderCatalog
    }

    func synchronizeFolders() async {
        let result = await folderiCloudMirror.synchronize(store: folderCatalogStore)
        DocumentSyncStatusCenter.shared.record(folder: result)
        do {
            folderCatalog = try await folderCatalogStore.load()
            let valid = Set(recordings.map(\.id))
            if !valid.isEmpty {
                folderCatalog = try await folderCatalogStore.pruneMemberships(validRecordingIDs: valid)
            }
        } catch {
            // Local catalog read failures surface via notice only; never block capture.
            notice = "文件夹同步后读取失败：\(error.localizedDescription)"
        }
    }

    private func requireFolder(named name: String) throws -> RecordingFolder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let folder = folderCatalog.folders.first(where: {
            $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return folder
        }
        throw FolderCatalogError.emptyName
    }

    // MARK: - Client Profiles & Voiceprints

    var clients: [ClientProfile] { clientCatalog.clients }

    func client(id: UUID) -> ClientProfile? {
        clientCatalog.clients.first(where: { $0.id == id })
    }

    func client(forVoiceprintID voiceprintID: UUID) -> ClientProfile? {
        clientCatalog.clients.first(where: { $0.voiceprintIdentityID == voiceprintID })
    }

    @discardableResult
    func upsertClient(_ client: ClientProfile) async -> ClientCatalogDocument {
        do {
            clientCatalog = try await clientCatalogStore.upsertClient(client)
            await refresh()
            return clientCatalog
        } catch {
            notice = "保存客户档案失败：\(error.localizedDescription)"
            return clientCatalog
        }
    }

    @discardableResult
    func deleteClient(id: UUID) async -> ClientCatalogDocument {
        do {
            clientCatalog = try await clientCatalogStore.deleteClient(id: id)
            await refresh()
            return clientCatalog
        } catch {
            notice = "删除客户档案失败：\(error.localizedDescription)"
            return clientCatalog
        }
    }

    @discardableResult
    func linkClientVoiceprint(clientID: UUID, voiceprintID: UUID?) async -> ClientCatalogDocument {
        do {
            clientCatalog = try await clientCatalogStore.linkVoiceprint(clientID: clientID, voiceprintID: voiceprintID)
            await refresh()
            return clientCatalog
        } catch {
            notice = "关联声纹失败：\(error.localizedDescription)"
            return clientCatalog
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
            try await transcriptionScheduler.beginRecoveryBarrier()
            _ = try? await repository.reconcileAllRecordingsFromDisk()
            _ = try await repository.recoverRunningSpeakerFinalizations(at: Date())
            let result = try await repository.recoverUnfinished(at: Date())
            // Retention for mic chunks and imported private assets (local-first).
            _ = try? await repository.purgeExpiredAudio(at: Date())
            
            // Clean up any historical continuation flags and ensure processing recordings re-queue
            let allRecordings = (try? await repository.recordings()) ?? []
            for rec in allRecordings where rec.state == .processing || rec.state == .interrupted || rec.state == .failed {
                let chunks = (try? await repository.chunks(recordingID: rec.id)) ?? []
                for chunk in chunks {
                    _ = try? await repository.setChunkContinuation(id: chunk.id, requiresContinuation: false, at: Date())
                }
                let doc = try? await transcriptStore.document(recordingID: rec.id)
                let isFullyTranscribed = doc?.state == RecordingState.complete.rawValue
                if !isFullyTranscribed {
                    let jobs = (try? await repository.jobs(recordingID: rec.id)) ?? []
                    let now = Date()
                    for var job in jobs where job.kind == .transcription && (job.state == .failed || job.state == .running) {
                        job.state = .pending
                        job.lastError = nil
                        job.updatedAt = now
                        try? await repository.upsertJob(job, at: now)
                    }
                    if rec.state == .failed || rec.state == .interrupted {
                        try? await repository.changeState(recordingID: rec.id, to: .processing, endedAt: rec.endedAt, at: now)
                    }
                }
            }

            try await enqueueHistoricalChunkJobs()
            // Rebuild completion projections while admission is still closed.
            // This also resumes a final speaker pass whose ASR callback was
            // lost just before process termination.
            let reconciliations = try await completionReconciler.reconcileAll()
            try await transcriptionScheduler.resumePendingJobs(
                onOutcome: { [weak self] outcome in
                    await self?.applyTranscriptionOutcome(outcome)
                }
            )
            enqueueSpeakerFinalization(
                recordingIDs: reconciliations.compactMap { recordingID, reconciliation in
                    guard case .needsSpeakerFinalization = reconciliation else { return nil }
                    return recordingID
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
            try await transcriptStore.reconcileSearchIndex(
                recordings: try await repository.recordings()
            )
        } catch {
            // Never leave admission permanently closed after a partial repair.
            try? await transcriptionScheduler.resumePendingJobs(
                onOutcome: { [weak self] outcome in
                    await self?.applyTranscriptionOutcome(outcome)
                }
            )
            if let reconciliations = try? await completionReconciler.reconcileAll() {
                enqueueSpeakerFinalization(
                    recordingIDs: reconciliations.compactMap { recordingID, reconciliation in
                        guard case .needsSpeakerFinalization = reconciliation else { return nil }
                        return recordingID
                    }
                )
            }
            notice = "恢复失败：\(error.localizedDescription)"
        }
        await synchronizeFolders()
        await refresh()
    }

    /// Backfills old recordings into the same durable per-chunk queue used by
    /// new captures. Complete recordings with an existing successful
    /// transcript are left untouched; failed or never-processed recordings
    /// are split into independently retryable closed-chunk jobs.
    private func enqueueHistoricalChunkJobs() async throws {
        let records = try await repository.recordings()
        for recording in records {
            if recording.origin == .importedAudio {
                guard recording.endedAt != nil else { continue }
                try await enqueueImportedRangeJobs(for: recording.id)
                continue
            }
            let chunks = try await repository.chunks(recordingID: recording.id)
                .filter { $0.state == .closed }
                .sorted { $0.startSample < $1.startSample }
            guard !chunks.isEmpty else { continue }
            if recording.endedAt == nil, let last = chunks.last {
                try? await repository.changeState(recordingID: recording.id, to: .processing, endedAt: last.endedAt, at: Date())
            }

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

            // A durable per-chunk queue exists or is partially formed.
            // Enqueue any newly reconciled or missing chunks without duplicating existing jobs.
            for chunk in chunks where !chunkJobIDs.contains(chunk.id) {
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

    private func enqueueImportedRangeJobs(for recordingID: UUID) async throws {
        let ranges = try await repository.processingRanges(recordingID: recordingID)
            .sorted { $0.sequence < $1.sequence }
        guard !ranges.isEmpty else { return }
        let jobs = try await repository.jobs(recordingID: recordingID)
        let existingRangeIDs = Set(jobs.compactMap { job in
            job.kind == .transcription ? job.processingRangeID : nil
        })
        let existingTranscript = try await transcriptStore.document(recordingID: recordingID)
        if existingTranscript?.state == RecordingState.complete.rawValue {
            let reconciledAt = Date()
            for var job in jobs where job.kind == .transcription && job.state != .completed {
                job.state = .completed
                job.lastError = "supersededByCompletedTranscript"
                job.updatedAt = reconciledAt
                try await repository.upsertJob(job, at: reconciledAt)
            }
            if let recording = try await repository.recording(id: recordingID),
               recording.state != .complete {
                try await repository.changeState(
                    recordingID: recordingID,
                    to: .complete,
                    endedAt: recording.endedAt,
                    at: reconciledAt
                )
            }
            return
        }
        for range in ranges {
            guard !existingRangeIDs.contains(range.id) else { continue }
            try await transcriptionScheduler.enqueue(
                recordingID: recordingID,
                processingRangeID: range.id,
                onOutcome: { [weak self] outcome in
                    await self?.applyTranscriptionOutcome(outcome)
                }
            )
        }
    }

    /// Returns billable ASR utterance seconds for the successful submission.
    private static func executeImportedRangeJob(
        recording: Recording,
        rangeID: UUID,
        lease: JobExecutionLease,
        repository: RecordingRepository,
        inferenceService: SenseVoiceInferenceService,
        transcriptStore: TranscriptDocumentStore,
        publicDocumentPublisher: PublicDocumentPublisher
    ) async throws -> TimeInterval {
        let ranges = try await repository.processingRanges(recordingID: recording.id)
            .sorted { $0.sequence < $1.sequence }
        guard let range = ranges.first(where: { $0.id == rangeID }) else {
            throw SenseVoiceInferenceService.InferenceError.runtime("找不到待转写的处理范围")
        }
        guard let asset = try await repository.importedAudioAsset(recordingID: recording.id) else {
            throw SenseVoiceInferenceService.InferenceError.runtime("找不到导入音频资产")
        }
        var workingAsset = asset
        var assetURL = repository.rootURL.appendingPathComponent(workingAsset.relativePath)
        let leading = SampleWindowContinuation.leadingProcessingRanges(
            endingAt: range,
            among: ranges
        )
        let covered = leading + [range]
        let decodeStart = covered.first?.startSample ?? range.startSample
        let decodeEnd = range.endSample
        let samples: [Float]
        do {
            samples = try ImportAudioRangeDecoder.samples(
                from: assetURL,
                startSample: decodeStart,
                endSample: decodeEnd
            )
        } catch {
            // Random-access / decode failure → one standardized private asset, then retry.
            guard !workingAsset.isStandardized else { throw error }
            workingAsset = try ImportAudioStandardizer.replaceWithStandardized(
                asset: workingAsset,
                rootURL: repository.rootURL
            )
            guard try await repository.validateExecutionLease(lease) else {
                throw JobExecutionLeaseError.invalidated
            }
            try await repository.updateImportedAudioAsset(workingAsset, at: Date())
            assetURL = repository.rootURL.appendingPathComponent(workingAsset.relativePath)
            samples = try ImportAudioRangeDecoder.samples(
                from: assetURL,
                startSample: decodeStart,
                endSample: decodeEnd
            )
        }
        let result: SenseVoiceInferenceService.Result
        do {
            result = try await inferenceService.transcribe(
                samples: samples,
                startingAt: decodeStart,
                languageMode: recording.languageMode
            )
        } catch let error as SpeechAnalysisService.AnalysisError {
            guard case .noSpeechDetected = error else { throw error }
            // Silent window: close the whole open-speech chain so later ranges
            // do not inherit a stuck continuation and the recording can complete.
            guard try await repository.validateExecutionLease(lease) else {
                throw JobExecutionLeaseError.invalidated
            }
            try SpeakerObservationStore.replaceBatch(
                [],
                rootURL: repository.rootURL,
                recordingID: recording.id,
                batchID: range.id
            )
            try await markImportedRangesCompleted(covered, repository: repository)
            return 0
        } catch let error as SenseVoiceInferenceService.InferenceError {
            // Empty ASR on a voiced window must not fail the whole import.
            // Keep earlier transcript segments and allow remaining jobs / complete.
            guard case .emptyTranscript = error else { throw error }
            guard try await repository.validateExecutionLease(lease) else {
                throw JobExecutionLeaseError.invalidated
            }
            try SpeakerObservationStore.replaceBatch(
                [],
                rootURL: repository.rootURL,
                recordingID: recording.id,
                batchID: range.id
            )
            try await markImportedRangesCompleted(covered, repository: repository)
            return 0
        }
        guard try await repository.validateExecutionLease(lease) else {
            throw JobExecutionLeaseError.invalidated
        }
        try await markImportedRangesCompleted(covered, repository: repository)

        var drafts: [TranscriptDocumentV1.SegmentDraft] = []
        let newObservations = result.speakerObservations
        if !result.sentenceResults.isEmpty {
            for u in result.sentenceResults {
                let sourceRange = TranscriptDocumentV1.SourceRange(
                    sourceKind: .importedAsset,
                    sourceID: workingAsset.id,
                    startSample: u.startSample,
                    endSample: u.endSample
                )
                drafts.append(
                    TranscriptDocumentV1.SegmentDraft(
                        text: u.text,
                        startSample: u.startSample,
                        endSample: u.endSample,
                        sourceRanges: [sourceRange]
                    )
                )
            }
        } else {
            let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let sourceRanges = [
                    TranscriptDocumentV1.SourceRange(
                        sourceKind: .importedAsset,
                        sourceID: workingAsset.id,
                        startSample: decodeStart,
                        endSample: decodeEnd
                    )
                ]
                drafts.append(
                    TranscriptDocumentV1.SegmentDraft(
                        text: trimmed,
                        startSample: decodeStart,
                        endSample: decodeEnd,
                        sourceRanges: sourceRanges
                    )
                )
            }
        }
        if !drafts.isEmpty {
            guard try await repository.validateExecutionLease(lease) else {
                throw JobExecutionLeaseError.invalidated
            }
            let commitStartedAt = Date()
            let audioAvailable = FileManager.default.fileExists(atPath: assetURL.path)
                && workingAsset.audioRemovedAt == nil
            try SpeakerObservationStore.replaceBatch(
                newObservations,
                rootURL: repository.rootURL,
                recordingID: recording.id,
                batchID: range.id
            )

            let document = try await transcriptStore.document(recordingID: recording.id)
            let updated = document?.appendingImported(
                recording: recording,
                audioAvailableOnThisDevice: audioAvailable,
                drafts: drafts,
                speakers: result.temporarySpeakers
            ) ?? TranscriptDocumentV1(
                recording: recording,
                audioAvailableOnThisDevice: audioAvailable,
                segmentDrafts: drafts,
                language: result.detectedLanguage,
                state: .processing,
                speakers: result.temporarySpeakers
            )
            guard try await repository.validateExecutionLease(lease) else {
                throw JobExecutionLeaseError.invalidated
            }
            try await transcriptStore.write(updated)
            let commitMilliseconds = Date().timeIntervalSince(commitStartedAt) * 1_000
            try TranscriptionStageMetricsStore.save(
                TranscriptionStageMetrics(
                    recordingID: recording.id,
                    batchID: range.id,
                    audioDurationMilliseconds: result.audioDuration * 1_000,
                    vadMilliseconds: result.vadMilliseconds,
                    asrLoadMilliseconds: Double(result.loadMilliseconds),
                    asrInferenceMilliseconds: Double(result.inferenceMilliseconds),
                    embeddingMilliseconds: result.embeddingMilliseconds,
                    commitMilliseconds: commitMilliseconds,
                    thermalState: result.thermalState,
                    completedAt: Date()
                ),
                rootURL: repository.rootURL
            )
        }
        return result.utteranceDuration
    }

    /// Marks every range in a closed open-speech / silent chain completed and
    /// clears continuation so partial imports do not strand early windows.
    private static func markImportedRangesCompleted(
        _ ranges: [ProcessingRange],
        repository: RecordingRepository
    ) async throws {
        let now = Date()
        for range in ranges {
            var finished = range
            finished.state = .completed
            finished.requiresContinuation = false
            finished.updatedAt = now
            _ = try await repository.upsertProcessingRange(finished, at: now)
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
                let reconciliation = try await completionReconciler.reconcile(
                    recordingID: outcome.recordingID
                )
                guard case .needsSpeakerFinalization = reconciliation else {
                    break
                }
                enqueueSpeakerFinalization(recordingIDs: [outcome.recordingID])
            }
        } catch {
            // A scheduler failure must remain visible rather than being
            // converted into a completed Recording by a UI fallback.
            notice = "转写状态更新失败：\(error.localizedDescription)"
        }
        await refresh()
    }

    /// Speaker work is intentionally a second, serial phase. The transcript is
    /// already readable while this queue runs, and historical finalizers can no
    /// longer block recovery of pending ASR jobs at launch.
    private func enqueueSpeakerFinalization(recordingIDs: [UUID]) {
        pendingSpeakerFinalizationIDs.formUnion(recordingIDs)
        guard speakerFinalizationDrainTask == nil else { return }
        speakerFinalizationDrainTask = Task { @MainActor [weak self] in
            await self?.drainSpeakerFinalizationQueue()
        }
    }

    private func drainSpeakerFinalizationQueue() async {
        defer { speakerFinalizationDrainTask = nil }
        while let recordingID = await nextSpeakerFinalizationRecordingID() {
            pendingSpeakerFinalizationIDs.remove(recordingID)
            do {
                _ = try await speakerFinalizationCoordinator.runPersisted(
                    recordingID: recordingID,
                    repository: repository,
                    transcriptStore: transcriptStore,
                    publisher: publicDocumentPublisher
                )
                _ = try await completionReconciler.reconcile(recordingID: recordingID)
            } catch is CancellationError {
                // Retranscription invalidates this pass and will enqueue a new
                // finalization after its transcription jobs complete.
            } catch SpeakerFinalizationCoordinator.FinalizationError.invalidated {
                // Same expected invalidation, expressed by the durable token.
            } catch {
                notice = "说话人整理失败：\(error.localizedDescription)"
            }
            await refresh()
        }
    }

    private func nextSpeakerFinalizationRecordingID() async -> UUID? {
        guard !pendingSpeakerFinalizationIDs.isEmpty else { return nil }
        let recordings = (try? await repository.recordings()) ?? []
        let recordingUpdatedAt = Dictionary(uniqueKeysWithValues: recordings.map { ($0.id, $0.updatedAt) })
        var priorityAt: [UUID: Date] = [:]
        for recordingID in pendingSpeakerFinalizationIDs {
            let jobs = (try? await repository.jobs(recordingID: recordingID)) ?? []
            priorityAt[recordingID] = jobs
                .filter { $0.kind == .transcription }
                .map(\.updatedAt)
                .max() ?? recordingUpdatedAt[recordingID] ?? .distantPast
        }
        return pendingSpeakerFinalizationIDs.sorted { lhs, rhs in
            let left = priorityAt[lhs] ?? .distantPast
            let right = priorityAt[rhs] ?? .distantPast
            if left != right { return left > right }
            return lhs.uuidString < rhs.uuidString
        }.first
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
        case .recording, .stopping, .paused:
            startPolling()
        case .interrupted:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            startPolling()
        case .processing:
            // Legacy presentation value; capture is already released.
            stopPolling()
            inputLevel = nil
        case .failed:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            stopPolling()
            inputLevel = nil
            sessionProgress = nil
        case .idle:
            stopPolling()
            inputLevel = nil
            sessionProgress = nil
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
            audioDurations = try await repository.allAudioDurations()
        } catch {
            notice = "读取记录列表失败：\(error.localizedDescription)"
        }

        do {
            folderCatalog = try await folderCatalogStore.load()
        } catch {
            notice = "读取文件夹失败：\(error.localizedDescription)"
        }

        do {
            clientCatalog = try await clientCatalogStore.load()
        } catch {
            // Client catalog load failure does not block session
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
            let recording = try await repository.recording(id: recordingID)
            snapshot = Snapshot(
                recording: recording,
                chunks: try await repository.chunks(recordingID: recordingID)
                    .sorted { $0.startSample < $1.startSample },
                gaps: try await repository.gaps(recordingID: recordingID)
                    .sorted { $0.startedAt < $1.startedAt },
                appliedEventCount: await repository.appliedEventCount,
                schemaVersion: await repository.schemaVersion
            )
            if let recording, activeRecordingID == recordingID {
                let jobs = try await repository.jobs(recordingID: recordingID)
                let transcript = try await transcriptStore.document(recordingID: recordingID)
                let lastSample = RecordingPresentationProgress.lastFinalizedSample(
                    segmentEndSamples: transcript?.segments.map(\.endSample) ?? []
                )
                sessionProgress = RecordingPresentationProgress.resolve(
                    recording: recording,
                    jobs: jobs,
                    liveCaptureState: coordinator.captureState,
                    lastFinalizedTranscriptSample: lastSample,
                    sampleRate: AACSegmentRecorder.targetSampleRate
                )
            } else if activeRecordingID == nil {
                sessionProgress = nil
            }
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

    private static func audioURL(for chunk: AudioChunk, rootURL: URL) -> URL {
        if chunk.relativePath.hasPrefix("Recordings/") {
            return rootURL.appendingPathComponent(chunk.relativePath)
        }
        let direct = rootURL.appendingPathComponent(chunk.relativePath)
        if FileManager.default.fileExists(atPath: direct.path) {
            return direct
        }
        let folderCandidate = rootURL.appendingPathComponent("Recordings/\(chunk.recordingID.uuidString.lowercased())/audio")
        if let enumerator = FileManager.default.enumerator(at: folderCandidate, includingPropertiesForKeys: nil) {
            while let file = enumerator.nextObject() as? URL {
                if file.lastPathComponent == chunk.relativePath || file.lastPathComponent.contains(chunk.id.uuidString.lowercased()) {
                    return file
                }
            }
        }
        return direct
    }
}

/// Mirrors SwiftUI.ScenePhase without importing SwiftUI into the model.
enum ScenePhaseLike {
    case active
    case inactive
    case background
}
