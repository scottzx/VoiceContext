import Foundation

nonisolated enum RecordingState: String, Codable, CaseIterable, Sendable {
    case recording
    case paused
    case interrupted
    case stopping
    case processing
    case complete
    case failed
}

/// Microphone ownership for a Recording. This is deliberately independent of
/// durable processing work: an idle capture can still have queued or running
/// jobs, and a new Recording can capture while an older one is processing.
nonisolated enum RecordingCaptureState: String, Codable, CaseIterable, Sendable {
    case idle
    case preparing
    case recording
    case paused
    case interrupted
    case stopping
}

nonisolated enum RecordingProcessingState: String, Codable, CaseIterable, Sendable {
    case idle
    case queued
    case processing
    case speakerFinalization
    case deferredUntilForeground
    case lockedPendingPurchase
    case needsAttention
    case complete
}

nonisolated struct RecordingLifecycleState: Equatable, Sendable {
    let recordingID: UUID
    let capture: RecordingCaptureState
    let processing: RecordingProcessingState
}

nonisolated enum RecordingJobKind: String, Codable, Sendable {
    case voiceActivityDetection
    case transcription
    case speakerEmbedding
    case speakerFinalization
    case documentGeneration
}

nonisolated enum RecordingJobState: String, Codable, Sendable {
    case pending
    case running
    case completed
    case failed
    case cancelled
}

/// Immutable source identity captured when a transcription job is claimed.
/// Executors must use this target instead of re-querying an arbitrary running
/// job for the Recording.
nonisolated enum JobExecutionSourceTarget: Equatable, Sendable {
    case audioChunk(UUID)
    case processingRange(UUID)
    case legacyWholeRecording
}

nonisolated struct JobExecutionLease: Equatable, Sendable {
    static let currentPipelineVersion = 2

    let jobID: UUID
    let recordingID: UUID
    let sourceTarget: JobExecutionSourceTarget
    let executionToken: UUID
    let pipelineVersion: Int
    let startedAt: Date
}

nonisolated enum JobExecutionLeaseError: LocalizedError, Equatable, Sendable {
    case invalidated

    var errorDescription: String? {
        switch self {
        case .invalidated:
            "转写任务已过期，未提交迟到结果"
        }
    }
}

nonisolated enum AudioChunkState: String, Codable, Sendable {
    case writing
    case closed
    case corrupt
    case audioRemoved
}

nonisolated enum RecordingGapReason: String, Codable, Sendable {
    case userPause
    case systemInterruption
    case routeChange
    case writeFailure
    case recoveredAfterTermination
}

nonisolated struct AudioRetention: Codable, Equatable, Sendable {
    static let defaultLifetime: TimeInterval = 7 * 24 * 60 * 60

    var expiresAt: Date
    var isPinned: Bool

    static func standard(startedAt: Date) -> AudioRetention {
        AudioRetention(
            expiresAt: startedAt.addingTimeInterval(defaultLifetime),
            isPinned: false
        )
    }
}

nonisolated struct Recording: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let startedAt: Date
    var endedAt: Date?
    var title: String?
    var isMeeting: Bool
    /// Processing policy is independent from presentation type. Legacy rows
    /// without this field decode as enabled to preserve prior behavior.
    var speakerProcessingEnabled: Bool
    var state: RecordingState
    var retention: AudioRetention
    var updatedAt: Date
    /// Capture vs Files import. Absent in older journal rows → microphone.
    var origin: RecordingOrigin
    var sourceFilename: String?
    var sourceUTType: String?
    /// SenseVoice language mode snapshotted when this Recording was created.
    /// Settings changes must not rewrite completed / in-flight transcripts.
    var languageMode: TranscriptionLanguageMode
    var locationName: String?
    /// Lightweight private note attached to this Recording. It is independent
    /// from transcript edits and processing state.
    var memo: String?

    init(
        id: UUID = UUID(),
        startedAt: Date,
        endedAt: Date? = nil,
        title: String? = nil,
        isMeeting: Bool = false,
        speakerProcessingEnabled: Bool? = nil,
        state: RecordingState = .recording,
        retention: AudioRetention? = nil,
        updatedAt: Date? = nil,
        origin: RecordingOrigin = .microphone,
        sourceFilename: String? = nil,
        sourceUTType: String? = nil,
        languageMode: TranscriptionLanguageMode = .default,
        locationName: String? = nil,
        memo: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.title = title
        self.isMeeting = isMeeting
        self.speakerProcessingEnabled = speakerProcessingEnabled ?? isMeeting
        self.state = state
        self.retention = retention ?? .standard(startedAt: startedAt)
        self.updatedAt = updatedAt ?? startedAt
        self.origin = origin
        self.sourceFilename = sourceFilename
        self.sourceUTType = sourceUTType
        self.languageMode = languageMode
        self.locationName = locationName
        self.memo = memo
    }

    private enum CodingKeys: String, CodingKey {
        case id, startedAt, endedAt, title, isMeeting, speakerProcessingEnabled, state, retention, updatedAt
        case origin, sourceFilename, sourceUTType, languageMode, locationName, memo
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        isMeeting = try container.decode(Bool.self, forKey: .isMeeting)
        speakerProcessingEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .speakerProcessingEnabled
        ) ?? true
        state = try container.decode(RecordingState.self, forKey: .state)
        retention = try container.decode(AudioRetention.self, forKey: .retention)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        origin = try container.decodeIfPresent(RecordingOrigin.self, forKey: .origin) ?? .microphone
        sourceFilename = try container.decodeIfPresent(String.self, forKey: .sourceFilename)
        sourceUTType = try container.decodeIfPresent(String.self, forKey: .sourceUTType)
        languageMode = try container.decodeIfPresent(TranscriptionLanguageMode.self, forKey: .languageMode)
            ?? .zhEnBilingual
        locationName = try container.decodeIfPresent(String.self, forKey: .locationName)
        memo = try container.decodeIfPresent(String.self, forKey: .memo)
    }
}

nonisolated struct AudioChunk: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let recordingID: UUID
    let relativePath: String
    let startSample: Int64
    let endSample: Int64
    let startedAt: Date
    let endedAt: Date
    var state: AudioChunkState
    var isPinned: Bool
    var audioRemovedAt: Date?
    /// VAD ended at the file boundary. The next contiguous chunk must be
    /// included before this utterance is committed.
    var requiresContinuation: Bool

    init(
        id: UUID = UUID(),
        recordingID: UUID,
        relativePath: String,
        startSample: Int64,
        endSample: Int64,
        startedAt: Date,
        endedAt: Date,
        state: AudioChunkState = .closed,
        isPinned: Bool = false,
        audioRemovedAt: Date? = nil,
        requiresContinuation: Bool = false
    ) {
        self.id = id
        self.recordingID = recordingID
        self.relativePath = relativePath
        self.startSample = startSample
        self.endSample = endSample
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.state = state
        self.isPinned = isPinned
        self.audioRemovedAt = audioRemovedAt
        self.requiresContinuation = requiresContinuation
    }

    private enum CodingKeys: String, CodingKey {
        case id, recordingID, relativePath, startSample, endSample, startedAt, endedAt
        case state, isPinned, audioRemovedAt, requiresContinuation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        recordingID = try container.decode(UUID.self, forKey: .recordingID)
        relativePath = try container.decode(String.self, forKey: .relativePath)
        startSample = try container.decode(Int64.self, forKey: .startSample)
        endSample = try container.decode(Int64.self, forKey: .endSample)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decode(Date.self, forKey: .endedAt)
        state = try container.decode(AudioChunkState.self, forKey: .state)
        isPinned = try container.decode(Bool.self, forKey: .isPinned)
        audioRemovedAt = try container.decodeIfPresent(Date.self, forKey: .audioRemovedAt)
        requiresContinuation = try container.decodeIfPresent(Bool.self, forKey: .requiresContinuation) ?? false
    }
}

nonisolated struct RecordingJob: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let recordingID: UUID
    /// Nil is retained for the pre-incremental, whole-recording job format.
    let chunkID: UUID?
    /// Files-import logical range job. Mutually exclusive with `chunkID`.
    let processingRangeID: UUID?
    let kind: RecordingJobKind
    var state: RecordingJobState
    var attemptCount: Int
    var lastError: String?
    /// Pipeline and attempt identity. A token exists only while this exact
    /// attempt owns the running lease.
    var pipelineVersion: Int
    var executionToken: UUID?
    var startedAt: Date?
    var terminationReason: String?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        recordingID: UUID,
        chunkID: UUID? = nil,
        processingRangeID: UUID? = nil,
        kind: RecordingJobKind,
        state: RecordingJobState,
        attemptCount: Int,
        lastError: String?,
        pipelineVersion: Int = JobExecutionLease.currentPipelineVersion,
        executionToken: UUID? = nil,
        startedAt: Date? = nil,
        terminationReason: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        precondition(chunkID == nil || processingRangeID == nil, "chunkID and processingRangeID are mutually exclusive")
        self.id = id
        self.recordingID = recordingID
        self.chunkID = chunkID
        self.processingRangeID = processingRangeID
        self.kind = kind
        self.state = state
        self.attemptCount = attemptCount
        self.lastError = lastError
        self.pipelineVersion = pipelineVersion
        self.executionToken = executionToken
        self.startedAt = startedAt
        self.terminationReason = terminationReason
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, recordingID, chunkID, processingRangeID, kind, state, attemptCount, lastError
        case pipelineVersion, executionToken, startedAt, terminationReason, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        recordingID = try container.decode(UUID.self, forKey: .recordingID)
        chunkID = try container.decodeIfPresent(UUID.self, forKey: .chunkID)
        processingRangeID = try container.decodeIfPresent(UUID.self, forKey: .processingRangeID)
        kind = try container.decode(RecordingJobKind.self, forKey: .kind)
        state = try container.decode(RecordingJobState.self, forKey: .state)
        attemptCount = try container.decode(Int.self, forKey: .attemptCount)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        pipelineVersion = try container.decodeIfPresent(Int.self, forKey: .pipelineVersion)
            ?? JobExecutionLease.currentPipelineVersion
        executionToken = try container.decodeIfPresent(UUID.self, forKey: .executionToken)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        terminationReason = try container.decodeIfPresent(String.self, forKey: .terminationReason)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

nonisolated struct ProcessingStageProgress: Sendable, Equatable {
    let completed: Int
    let total: Int
    let running: Int
    let pending: Int
    let failed: Int
    let cancelled: Int

    var isComplete: Bool { total > 0 && completed == total }
    var fractionCompleted: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }
}

nonisolated enum ProcessingTaskStage: String, Sendable, Equatable {
    case transcription
    case speakerProcessing
}

nonisolated enum ProcessingTaskState: String, Sendable, Equatable {
    case todo
    case running
    case failed
    case cancelled
    case completed
}

nonisolated struct RecordingProcessingTaskItem: Identifiable, Sendable, Equatable {
    let id: String
    let recordingID: UUID
    let recordingTitle: String
    let stage: ProcessingTaskStage
    let state: ProcessingTaskState
    let progress: ProcessingStageProgress
    let speakerFinalizationState: RecordingJobState?
    let dependencyMessage: String?
    let lastError: String?
    let updatedAt: Date
}

nonisolated struct CompletedRecordingProcessingGroup: Identifiable, Sendable, Equatable {
    var id: UUID { recordingID }
    let recordingID: UUID
    let recordingTitle: String
    let tasks: [RecordingProcessingTaskItem]
}

nonisolated struct TranscriptionQueueStatus: Sendable, Equatable {
    var todoTasks: [RecordingProcessingTaskItem] = []
    var runningTasks: [RecordingProcessingTaskItem] = []
    var failedTasks: [RecordingProcessingTaskItem] = []
    var cancelledTasks: [RecordingProcessingTaskItem] = []
    var completedTasks: [RecordingProcessingTaskItem] = []
    var metalSubmissions: Int = 0
    var thermalState: String = "正常"
    var isPurchaseLocked: Bool = false

    var completedRecordingGroups: [CompletedRecordingProcessingGroup] {
        var recordingOrder: [UUID] = []
        var tasksByRecording: [UUID: [RecordingProcessingTaskItem]] = [:]
        var titlesByRecording: [UUID: String] = [:]

        for task in completedTasks {
            if tasksByRecording[task.recordingID] == nil {
                recordingOrder.append(task.recordingID)
                titlesByRecording[task.recordingID] = task.recordingTitle
            }
            tasksByRecording[task.recordingID, default: []].append(task)
        }

        return recordingOrder.compactMap { recordingID in
            guard let tasks = tasksByRecording[recordingID],
                  let title = titlesByRecording[recordingID] else { return nil }
            return CompletedRecordingProcessingGroup(
                recordingID: recordingID,
                recordingTitle: title,
                tasks: tasks.sorted { lhs, rhs in
                    completedStageOrder(lhs.stage) < completedStageOrder(rhs.stage)
                }
            )
        }
    }

    private func completedStageOrder(_ stage: ProcessingTaskStage) -> Int {
        switch stage {
        case .transcription: 0
        case .speakerProcessing: 1
        }
    }
}

nonisolated struct RecordingGap: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let recordingID: UUID
    let reason: RecordingGapReason
    let startSample: Int64
    var endSample: Int64?
    let startedAt: Date
    var endedAt: Date?
}

extension Recording {
    /// Compatibility projection for the v1 single `recordings.state` column.
    /// Processing jobs remain the durable source of processing truth, so no
    /// database migration is required merely to express the orthogonal model.
    nonisolated var persistedCaptureState: RecordingCaptureState {
        switch state {
        case .recording: .recording
        case .paused: .paused
        case .interrupted: .interrupted
        case .stopping: .stopping
        case .processing, .complete, .failed: .idle
        }
    }

    nonisolated func lifecycleState(
        jobs: [RecordingJob],
        liveCaptureState: RecordingCaptureState? = nil
    ) -> RecordingLifecycleState {
        RecordingLifecycleState(
            recordingID: id,
            capture: liveCaptureState ?? persistedCaptureState,
            processing: RecordingProcessingState.resolve(
                legacyRecordingState: state,
                jobs: jobs
            )
        )
    }
}


/// User-facing progress derived from durable jobs + transcript, never from
/// chunk file boundaries or local animation timers.
nonisolated struct RecordingPresentationProgress: Equatable, Sendable {
    let capture: RecordingCaptureState
    let processing: RecordingProcessingState
    /// Absolute timeline position of the latest finalized transcript sample.
    let transcribedUpTo: TimeInterval?
    /// Outstanding durable work units (pending + running). UI must not label
    /// these as chunks or 60-second file boundaries.
    let outstandingItemCount: Int

    var canRetry: Bool { processing == .needsAttention }

    var hasTranscriptProgress: Bool { transcribedUpTo != nil }

    nonisolated static func resolve(
        recording: Recording,
        jobs: [RecordingJob],
        liveCaptureState: RecordingCaptureState? = nil,
        lastFinalizedTranscriptSample: Int64? = nil,
        sampleRate: Double = 16_000
    ) -> RecordingPresentationProgress {
        let lifecycle = recording.lifecycleState(jobs: jobs, liveCaptureState: liveCaptureState)
        let outstanding = jobs.filter { $0.state == .pending || $0.state == .running }.count
        let transcribedUpTo: TimeInterval?
        if let sample = lastFinalizedTranscriptSample, sample > 0, sampleRate > 0 {
            transcribedUpTo = TimeInterval(sample) / sampleRate
        } else {
            transcribedUpTo = nil
        }
        return RecordingPresentationProgress(
            capture: lifecycle.capture,
            processing: lifecycle.processing,
            transcribedUpTo: transcribedUpTo,
            outstandingItemCount: outstanding
        )
    }

    nonisolated static func lastFinalizedSample(
        segmentEndSamples: [Int64]
    ) -> Int64? {
        segmentEndSamples.max().flatMap { $0 > 0 ? $0 : nil }
    }
}

extension RecordingProcessingState {
    nonisolated static func resolve(
        legacyRecordingState: RecordingState,
        jobs: [RecordingJob]
    ) -> RecordingProcessingState {
        if jobs.contains(where: { $0.state == .failed }) {
            return .needsAttention
        }
        let transcriptionJobs = jobs.filter { $0.kind == .transcription }
        let finalizationJobs = jobs.filter { $0.kind == .speakerFinalization }
        let transcriptionIsComplete = !transcriptionJobs.isEmpty
            && transcriptionJobs.allSatisfy { $0.state == .completed }
        if transcriptionIsComplete,
           finalizationJobs.contains(where: { $0.state == .pending || $0.state == .running }) {
            return .speakerFinalization
        }
        if jobs.contains(where: { $0.state == .running }) {
            return .processing
        }
        let pendingJobs = jobs.filter { $0.state == .pending }
        if pendingJobs.contains(where: { $0.lastError == "lockedPendingPurchase" }) {
            return .lockedPendingPurchase
        }
        if pendingJobs.contains(where: { $0.lastError == "deferredUntilForeground" }) {
            return .deferredUntilForeground
        }
        if !pendingJobs.isEmpty {
            return .queued
        }
        if !jobs.isEmpty, jobs.allSatisfy({ $0.state == .completed }) {
            return .complete
        }

        return switch legacyRecordingState {
        case .processing: .processing
        case .complete: .complete
        case .failed: .needsAttention
        case .recording, .paused, .interrupted, .stopping: .idle
        }
    }
}

nonisolated enum RecordingJournalPayload: Codable, Equatable, Sendable {
    case recordingCreated(Recording)
    case recordingStateChanged(recordingID: UUID, state: RecordingState, endedAt: Date?)
    case chunkClosed(AudioChunk)
    case chunkContinuationChanged(chunkID: UUID, requiresContinuation: Bool)
    case jobUpserted(RecordingJob)
    case gapOpened(RecordingGap)
    case gapClosed(gapID: UUID, endSample: Int64, endedAt: Date)
    case retentionChanged(recordingID: UUID, retention: AudioRetention)
    case chunkPinChanged(chunkID: UUID, isPinned: Bool)
    case chunkAudioRemoved(chunkID: UUID, removedAt: Date)
    case recordingTitleChanged(recordingID: UUID, title: String?)
    case recordingLocationChanged(recordingID: UUID, locationName: String?)
    case recordingMemoChanged(recordingID: UUID, memo: String?)
    case recordingMeetingChanged(recordingID: UUID, isMeeting: Bool)
    case importedAudioAssetCreated(ImportedAudioAsset)
    case importedAudioAssetUpdated(ImportedAudioAsset)
    case importedAudioAssetRemoved(assetID: UUID, removedAt: Date)
    case processingRangeUpserted(ProcessingRange)
    case processingRangeContinuationChanged(rangeID: UUID, requiresContinuation: Bool)
}

nonisolated struct RecordingJournalEvent: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let occurredAt: Date
    let payload: RecordingJournalPayload

    init(id: UUID = UUID(), occurredAt: Date, payload: RecordingJournalPayload) {
        self.id = id
        self.occurredAt = occurredAt
        self.payload = payload
    }
}

nonisolated struct RecordingStateMachine: Sendable {
    nonisolated enum Event: Equatable, Sendable {
        case pause
        case resume
        case interruptionBegan
        case interruptionEnded(shouldResume: Bool)
        case stopRequested
        case captureStopped
        case processingCompleted
        case processingFailed
        case retryProcessing
        case recoveredAfterTermination
    }

    nonisolated enum TransitionError: LocalizedError, Equatable {
        case illegalTransition(from: RecordingState, event: Event)

        var errorDescription: String? {
            switch self {
            case let .illegalTransition(state, event):
                "不能从 \(state.rawValue) 执行 \(String(describing: event))。"
            }
        }
    }

    private(set) var state: RecordingState

    init(state: RecordingState) {
        self.state = state
    }

    @discardableResult
    mutating func apply(_ event: Event) throws -> RecordingState {
        let next: RecordingState = switch (state, event) {
        case (.recording, .pause): .paused
        case (.paused, .resume): .recording
        case (.interrupted, .resume): .recording
        case (.interrupted, .pause): .paused
        case (.recording, .interruptionBegan), (.paused, .interruptionBegan): .interrupted
        case (.interrupted, .interruptionEnded(shouldResume: true)): .recording
        case (.interrupted, .interruptionEnded(shouldResume: false)): .interrupted
        case (.recording, .stopRequested),
             (.paused, .stopRequested),
             (.interrupted, .stopRequested): .stopping
        case (.stopping, .captureStopped): .processing
        case (.processing, .processingCompleted): .complete
        case (.processing, .processingFailed): .failed
        case (.failed, .retryProcessing),
             (.complete, .retryProcessing): .processing
        case (.recording, .recoveredAfterTermination),
             (.paused, .recoveredAfterTermination),
             (.stopping, .recoveredAfterTermination): .interrupted
        default:
            throw TransitionError.illegalTransition(from: state, event: event)
        }
        state = next
        return next
    }
}
