import AVFAudio
import Foundation
import Observation
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
    /// Capture-session progress for the live recording chrome. Independent of
    /// any older Recording that may still be processing in the background.
    private(set) var sessionProgress: RecordingPresentationProgress?
    private(set) var snapshot = Snapshot()
    private(set) var recordings: [Recording] = []
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
    private let skillPackSeeder: PublicSkillPackSeeder
    let folderCatalogStore: FolderCatalogStore
    private let folderiCloudMirror: FolderiCloudMirror
    private(set) var folderCatalog: FolderCatalogDocument = .empty()
    private let transcriptionScheduler: ForegroundTranscriptionScheduler
    let trialEntitlement: TrialEntitlementController
    private let trialLedger: TrialQuotaLedger
    private let diagnostics = RecordingDiagnostics()
    private var refreshTask: Task<Void, Never>?

    convenience init() throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try self.init(rootURL: documents.appendingPathComponent("VoiceContext", isDirectory: true))
    }

    init(
        rootURL: URL,
        trialLedger: TrialQuotaLedger? = nil,
        purchaseClient: (any PurchaseUnlockClient)? = nil
    ) throws {
        repository = try RecordingRepository(rootURL: rootURL)
        let transcriptStore = try TranscriptDocumentStore(rootURL: rootURL)
        self.transcriptStore = transcriptStore
        publicDocumentPublisher = PublicDocumentPublisher(rootURL: rootURL, enableDefaultiCloudMirror: true)
        skillPackSeeder = PublicSkillPackSeeder(rootURL: rootURL)
        folderCatalogStore = FolderCatalogStore(rootURL: rootURL)
        folderiCloudMirror = FolderiCloudMirror(localRootURL: rootURL)
        coordinator = RecordingSessionCoordinator(repository: repository, capture: recorder)
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
        transcriptionScheduler = ForegroundTranscriptionScheduler(
            repository: repository,
            lifecycleGate: lifecycleGate,
            admissionPolicy: TranscriptionAdmissionPolicy(
                isPurchaseLocked: {
                    TrialQuotaLedger.isManualTrialEnabled && ledger.isPurchaseLocked
                }
            ),
            execute: { [repository, inferenceService, transcriptStore, publicDocumentPublisher] recordingID in
                guard let recording = try await repository.recording(id: recordingID) else {
                    throw SenseVoiceInferenceService.InferenceError.runtime("找不到待写入文稿的录音")
                }
                let jobs = try await repository.jobs(recordingID: recordingID)
                let runningJob = jobs.last {
                    $0.kind == .transcription && $0.state == .running
                }

                if let rangeID = runningJob?.processingRangeID {
                    _ = try await Self.executeImportedRangeJob(
                        recording: recording,
                        rangeID: rangeID,
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
                guard let chunkID = runningJob?.chunkID else {
                    var transcriptionResults: [(chunkID: UUID, text: String)] = []
                    var detectedLanguage = ""
                    var temporarySpeakers: [String] = []
                    for chunk in chunks {
                        let result = try await inferenceService.transcribe(
                            recordingURL: repository.rootURL.appendingPathComponent(chunk.relativePath),
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
                    let document = TranscriptDocumentV1(
                        recording: recording,
                        chunks: chunks,
                        segmentTexts: transcriptionResults,
                        language: detectedLanguage,
                        speakers: temporarySpeakers
                    )
                    try document.requireContent()
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
                let leading = SampleWindowContinuation.leadingAudioChunks(
                    endingAt: chunk,
                    among: chunks
                )
                let sourceChunks = leading + [chunk]
                let result = try await inferenceService.transcribe(
                    recordingURLs: sourceChunks.map {
                        repository.rootURL.appendingPathComponent($0.relativePath)
                    },
                    startingAt: sourceChunks[0].startSample,
                    languageMode: recording.languageMode
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

                // Clear the full multi-hop open-speech chain, not only the
                // immediate predecessor.
                for source in sourceChunks {
                    _ = try await repository.setChunkContinuation(
                        id: source.id,
                        requiresContinuation: false,
                        at: Date()
                    )
                }

                // Prefer ordered exact source_ranges over a single source_chunk_id
                // so cross-chunk carry commits remain addressable for seek/export
                // and idempotent retries.
                let sourceRanges = sourceChunks.map {
                    TranscriptDocumentV1.SourceRange(
                        sourceKind: .audioChunk,
                        sourceID: $0.id,
                        startSample: $0.startSample,
                        endSample: $0.endSample
                    )
                }
                let draft = TranscriptDocumentV1.SegmentDraft(
                    text: result.text,
                    sourceRanges: sourceRanges
                )
                let document = try await transcriptStore.document(recordingID: recordingID)
                let updated = document?.appending(
                    recording: recording,
                    chunks: chunks,
                    draft: draft,
                    replacingSourceIDs: sourceChunks.map(\.id),
                    speakers: result.temporarySpeakers
                ) ?? TranscriptDocumentV1(
                    recording: recording,
                    chunks: sourceChunks,
                    segmentDrafts: [draft],
                    language: result.detectedLanguage,
                    state: .processing,
                    speakers: result.temporarySpeakers
                )
                try updated.requireContent()
                try await transcriptStore.write(updated)
                try? await Self.publishPublicDocuments(
                    document: updated,
                    repository: repository,
                    transcriptStore: transcriptStore,
                    publisher: publicDocumentPublisher
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
            trialEntitlement.start()
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

    /// Files picker entry: privately copy audio, plan ProcessingRanges, enqueue
    /// offline transcription. Does not touch the microphone session.
    @discardableResult
    func importAudio(from sourceURL: URL, title: String? = nil) async -> UUID? {
        guard beginImportActivity(sourceLabel: sourceURL.lastPathComponent, phase: .queued) else {
            return nil
        }
        defer { clearImportActivity() }
        return await performAudioImport(
            from: sourceURL,
            title: title,
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
        title: String? = nil
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
            sourceFilenameOverride: displayName,
            sourceUTTypeOverride: UTType.mpeg4Audio.identifier
        )
    }

    private func performAudioImport(
        from sourceURL: URL,
        title: String?,
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

    func exportPackage(recordingID: UUID) async throws -> PublicExportPackage {
        guard let document = try await transcriptStore.document(recordingID: recordingID) else {
            throw PublicDocumentPublisher.PublishError.unresolvedRelativePath("Transcripts/" + recordingID.uuidString)
        }
        // Ensure Meetings/Daily mirrors exist before Share Sheet / Files handoff.
        let published = try await publishPublicDocuments(for: document)
        _ = try? await skillPackSeeder.seed()
        let jsonURL = try await publicDocumentPublisher.resolveURL(relativePath: published.jsonRelativePath)
        let markdownURL = try await publicDocumentPublisher.resolveURL(relativePath: published.markdownRelativePath)
        let consumer = await prepareConsumerExports(document: document)
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
        document: TranscriptDocumentV1
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

    func speakerBindings(recordingID: UUID) async throws -> [MeetingSpeakerBinding] {
        try MeetingSpeakerBindingStore.load(
            rootURL: repository.rootURL,
            recordingID: recordingID
        )
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
        let archiveURL = try VoiceprintArchiveStorage.defaultURL()
        var archive = try VoiceprintArchiveStorage.load(from: archiveURL)
        try body(&bindings, &archive)
        let syncEnabled = OnboardingPreferences().encryptedVoiceprintSyncEnabled
        _ = try VoiceprintArchiveStorage.saveAndSync(
            archive,
            to: archiveURL,
            synchronizableKey: syncEnabled
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
            Task { [inferenceService, transcriptionScheduler] in
                await transcriptionScheduler.enteredBackground()
                _ = await inferenceService.enteredBackground()
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
            // Retention for mic chunks and imported private assets (local-first).
            _ = try await repository.purgeExpiredAudio(at: Date())
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
            try await transcriptStore.reconcileSearchIndex(
                recordings: try await repository.recordings()
            )
        } catch {
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
            guard recording.endedAt != nil else { continue }
            if recording.origin == .importedAudio {
                try await enqueueImportedRangeJobs(for: recording.id)
                continue
            }
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
            try await markImportedRangesCompleted(covered, repository: repository)
            return 0
        } catch let error as SenseVoiceInferenceService.InferenceError {
            // Empty ASR on a voiced window must not fail the whole import.
            // Keep earlier transcript segments and allow remaining jobs / complete.
            guard case .emptyTranscript = error else { throw error }
            try await markImportedRangesCompleted(covered, repository: repository)
            return 0
        }
        let isFinalRange = ranges.last?.id == range.id
        if result.endsWithOpenSpeech && !isFinalRange {
            _ = try await repository.setProcessingRangeContinuation(
                id: range.id,
                requiresContinuation: true,
                at: Date()
            )
            return result.utteranceDuration
        }

        try await markImportedRangesCompleted(covered, repository: repository)

        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return result.utteranceDuration }

        let sourceRanges = [
            TranscriptDocumentV1.SourceRange(
                sourceKind: .importedAsset,
                sourceID: workingAsset.id,
                startSample: decodeStart,
                endSample: decodeEnd
            )
        ]
        let draft = TranscriptDocumentV1.SegmentDraft(
            text: trimmed,
            sourceRanges: sourceRanges
        )
        let audioAvailable = FileManager.default.fileExists(atPath: assetURL.path)
            && workingAsset.audioRemovedAt == nil
        let document = try await transcriptStore.document(recordingID: recording.id)
        let updated = document?.appendingImported(
            recording: recording,
            audioAvailableOnThisDevice: audioAvailable,
            draft: draft,
            speakers: result.temporarySpeakers
        ) ?? TranscriptDocumentV1(
            recording: recording,
            audioAvailableOnThisDevice: audioAvailable,
            segmentDrafts: [draft],
            language: result.detectedLanguage,
            state: .processing,
            speakers: result.temporarySpeakers
        )
        try updated.requireContent()
        try await transcriptStore.write(updated)
        try? await Self.publishPublicDocuments(
            document: updated,
            repository: repository,
            transcriptStore: transcriptStore,
            publisher: publicDocumentPublisher
        )
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
                    // FR-SPK-004: offline recluster for mic chunks and imported
                    // assets. Failure keeps any online roster and must not block
                    // Recording completion.
                    let pass = try? await Self.offlineSpeakerRecluster(
                        recordingID: outcome.recordingID,
                        repository: repository
                    )
                    if let pass,
                       let archiveURL = try? VoiceprintArchiveStorage.defaultURL(),
                       let archive = try? VoiceprintArchiveStorage.load(from: archiveURL) {
                        let bindings = SpeakerIdentityConfirmation.makeBindings(
                            speakers: pass.recluster.speakers,
                            labels: pass.recluster.labels,
                            observations: pass.observations,
                            archive: archive
                        )
                        try? MeetingSpeakerBindingStore.save(
                            bindings,
                            rootURL: repository.rootURL,
                            recordingID: outcome.recordingID
                        )
                    }
                    if let document = try await transcriptStore.document(recordingID: outcome.recordingID) {
                        var completed = document.updatingState(.complete)
                        if let pass {
                            completed = completed.applyingOfflineRecluster(
                                speakers: pass.recluster.speakers,
                                speakerTurns: pass.recluster.turns
                            )
                        }
                        try await transcriptStore.write(completed)
                        do {
                            try await publishPublicDocuments(for: completed)
                        } catch {
                            notice = "本地文稿已保存，公开目录同步稍后可重试：" + error.localizedDescription
                        }
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
        } catch {
            notice = "读取记录列表失败：\(error.localizedDescription)"
        }

        do {
            folderCatalog = try await folderCatalogStore.load()
        } catch {
            notice = "读取文件夹失败：\(error.localizedDescription)"
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
}

/// Mirrors SwiftUI.ScenePhase without importing SwiftUI into the model.
enum ScenePhaseLike {
    case active
    case inactive
    case background
}
