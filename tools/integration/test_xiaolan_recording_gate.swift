import Foundation

nonisolated final class Gate: @unchecked Sendable {
    let lock = NSLock()
    private var enabled = false
    var voiceEnabled: Bool { get { lock.withLock { enabled } } set { lock.withLock { enabled = newValue } } }
}
enum MicrophoneAccess {
    enum Permission { case granted, denied }
    static let deniedStartMessage = "denied"
    static var requests = 0
    static var permission: () async -> Permission = { .granted }
    static func requestPermissionIfNeeded() async -> Permission { requests += 1; return await permission() }
}
enum AACSegmentRecorder { enum RecorderError: Error { case microphonePermissionDenied } }
enum LocationAccess {
    static let isAutoRecordLocationEnabled = false
    static func fetchCurrentLocationAddress() async -> String? { nil }
}
@MainActor final class Coordinator {
    var starts = 0, appends = 0, resumes = 0, pauses = 0
    func start(isMeeting: Bool, title: String?) async throws -> UUID { starts += 1; return UUID() }
    func startAppend(recordingID: UUID) async throws -> UUID { appends += 1; return recordingID }
    func resume() async throws { resumes += 1 }
    func pause() async throws { pauses += 1 }
}
@MainActor final class RecordingCoreModel {
    enum Presentation { case idle, recording, paused, interrupted }
    let coordinator = Coordinator()
    var presentation = Presentation.idle
    var isStartingRecording = false
    var showsSessionChrome: Bool { presentation != .idle }
    var notice: String?
    var activeRecordingID: UUID?
    func refresh() async {}
    func updateRecordingLocation(recordingID: UUID, locationName: String) async {}
}
@main struct RecordingVoiceGateChecks {
    @MainActor static func main() async {
        let gate = Gate()
        RecordingAudioBridge.install(.init(capture: { _ in }, release: { _ in }, playback: { true }, releasePlayback: {},
                                           recordingStartBlockReason: { gate.voiceEnabled ? "请先关闭语音模式，再开始录音。" : nil }))
        for startKind in 0..<3 {
            let model = RecordingCoreModel()
            gate.voiceEnabled = true // Mode stays reserved while its microphone is paused.
            let requests = MicrophoneAccess.requests
            switch startKind {
            case 0: await model.start(title: "会议", isMeeting: true)
            case 1: await model.append(recordingID: UUID())
            default: model.presentation = .paused; await model.pauseOrResume()
            }
            precondition(model.coordinator.starts + model.coordinator.appends + model.coordinator.resumes == 0,
                         "Blocked voice/paused-voice must never create a phantom recording or acquire microphone")
            precondition(MicrophoneAccess.requests == requests && model.notice?.contains("先关闭语音模式") == true)
        }
        for append in [false, true] {
            gate.voiceEnabled = false
            let model = RecordingCoreModel()
            MicrophoneAccess.permission = { gate.voiceEnabled = true; return .granted }
            if append { await model.append(recordingID: UUID()) } else { await model.start() }
            precondition(model.coordinator.starts + model.coordinator.appends == 0 && !model.isStartingRecording,
                         "Voice activation during the permission await must be rechecked before persistence")
        }
        gate.voiceEnabled = false
        MicrophoneAccess.permission = { .granted }
        let normal = RecordingCoreModel()
        await normal.start()
        await normal.append(recordingID: UUID())
        normal.presentation = .interrupted
        await normal.pauseOrResume()
        precondition(normal.coordinator.starts == 1 && normal.coordinator.appends == 1 && normal.coordinator.resumes == 1)
        print("PASS: recording start/append/resume refuse active and paused voice before persistence; permission races recheck; ordinary recording controls remain available")
    }
}
