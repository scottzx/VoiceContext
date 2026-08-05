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

nonisolated enum RecordingJobKind: String, Codable, Sendable {
    case voiceActivityDetection
    case transcription
    case speakerEmbedding
    case documentGeneration
}

nonisolated enum RecordingJobState: String, Codable, Sendable {
    case pending
    case running
    case completed
    case failed
}

nonisolated enum AudioChunkState: String, Codable, Sendable {
    case writing
    case closed
    case corrupt
    case audioRemoved
}

nonisolated enum RecordingGapReason: String, Codable, Sendable {
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
    var state: RecordingState
    var retention: AudioRetention
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        startedAt: Date,
        endedAt: Date? = nil,
        title: String? = nil,
        isMeeting: Bool = false,
        state: RecordingState = .recording,
        retention: AudioRetention? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.title = title
        self.isMeeting = isMeeting
        self.state = state
        self.retention = retention ?? .standard(startedAt: startedAt)
        self.updatedAt = updatedAt ?? startedAt
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
        audioRemovedAt: Date? = nil
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
    }
}

nonisolated struct RecordingJob: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let recordingID: UUID
    let kind: RecordingJobKind
    var state: RecordingJobState
    var attemptCount: Int
    var lastError: String?
    let createdAt: Date
    var updatedAt: Date
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

nonisolated enum RecordingJournalPayload: Codable, Equatable, Sendable {
    case recordingCreated(Recording)
    case recordingStateChanged(recordingID: UUID, state: RecordingState, endedAt: Date?)
    case chunkClosed(AudioChunk)
    case jobUpserted(RecordingJob)
    case gapOpened(RecordingGap)
    case gapClosed(gapID: UUID, endSample: Int64, endedAt: Date)
    case retentionChanged(recordingID: UUID, retention: AudioRetention)
    case chunkPinChanged(chunkID: UUID, isPinned: Bool)
    case chunkAudioRemoved(chunkID: UUID, removedAt: Date)
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
        case (.recording, .interruptionBegan), (.paused, .interruptionBegan): .interrupted
        case (.interrupted, .interruptionEnded(shouldResume: true)): .recording
        case (.interrupted, .interruptionEnded(shouldResume: false)): .interrupted
        case (.recording, .stopRequested),
             (.paused, .stopRequested),
             (.interrupted, .stopRequested): .stopping
        case (.stopping, .captureStopped): .processing
        case (.processing, .processingCompleted): .complete
        case (.processing, .processingFailed): .failed
        case (.failed, .retryProcessing): .processing
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
