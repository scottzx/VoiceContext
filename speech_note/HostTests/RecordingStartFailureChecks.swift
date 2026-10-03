import Foundation

struct Recording {
    let id = UUID()
    let startedAt: Date
    let title: String?
    let isMeeting: Bool
    let languageMode: String
}
enum TranscriptionLanguageMode { static let current = "automatic" }
struct RecordingStateMachine {
    enum State { case recording }
    let state: State
}
struct LowStorageGuard { func validateCanStartRecording(at url: URL) throws {} }

@MainActor final class RecordingLiveActivityManager {
    static let shared = RecordingLiveActivityManager()
    func startActivity(recordingID: UUID, startedAt: Date) {}
    func endActivity() {}
}

@MainActor final class EntryCapture {
    var starts = 0
    func start(in url: URL, segmentDuration: Double, initialSampleOffset: Int64 = 0) async throws {
        starts += 1
    }
}

@MainActor final class EntryRepository {
    struct Chunk { let id: UUID; let endSample: Int64 }
    enum State { case recording, failed }
    let rootURL = URL(fileURLWithPath: "/host-fixture-unused")
    var failCreate = false
    var failTransition = false
    var holdChunks = false
    var chunksContinuation: CheckedContinuation<[Chunk], Never>?
    func createRecording(_ recording: Recording, at date: Date) async throws {
        if failCreate { throw AACSegmentRecorder.RecorderError.testFailure }
    }
    func recording(id: UUID) async throws -> Recording? {
        Recording(startedAt: Date(), title: nil, isMeeting: false, languageMode: "automatic")
    }
    func chunks(recordingID: UUID) async throws -> [Chunk] {
        if holdChunks {
            return await withCheckedContinuation { chunksContinuation = $0 }
        }
        return []
    }
    func changeState(recordingID: UUID, to state: State, endedAt: Date? = nil, at date: Date) async throws {
        if failTransition { throw AACSegmentRecorder.RecorderError.testFailure }
    }
}

@MainActor func verifyRecordingStartFailures() async {
    // Actual coordinator methods, with storage/capture/Live Activity host fakes.
    let fresh = EntrySession()
    fresh.repository.failCreate = true
    do {
        _ = try await fresh.start()
        preconditionFailure("Expected failed recording persistence")
    } catch {}
    precondition(fresh.activeRecordingID == nil && fresh.stateMachine == nil)
    precondition(fresh.captureState == .idle && fresh.capture.starts == 0)
    fresh.repository.failCreate = false
    let newID = try! await fresh.start()
    precondition(fresh.activeRecordingID == newID && fresh.capture.starts == 1)

    let append = EntrySession()
    let id = UUID()
    append.repository.failTransition = true
    do {
        _ = try await append.startAppend(recordingID: id)
        preconditionFailure("Expected failed append persistence")
    } catch {}
    precondition(append.activeRecordingID == nil && append.stateMachine == nil)
    precondition(append.captureState == .idle && append.capture.starts == 0)
    append.repository.failTransition = false
    let resumedID = try! await append.startAppend(recordingID: id)
    precondition(resumedID == id)
    print("PASS: persistence failures release start/append state before capture")

    let race = EntrySession()
    race.repository.holdChunks = true
    let pendingAppend = Task { try await race.startAppend(recordingID: UUID()) }
    while race.repository.chunksContinuation == nil { await Task.yield() }
    let activeID = try! await race.start()
    race.repository.chunksContinuation?.resume(returning: [])
    do {
        _ = try await pendingAppend.value
        preconditionFailure("Append must not take over another start")
    } catch EntrySession.CoordinatorError.sessionAlreadyActive {
    } catch { preconditionFailure("Unexpected race failure: \(error)") }
    precondition(race.activeRecordingID == activeID && race.capture.starts == 1)
    print("PASS: append rechecks active capture after storage await")
}
