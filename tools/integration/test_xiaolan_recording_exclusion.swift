import Foundation

@MainActor struct AVAudioSession {
    enum Category { case playAndRecord }
    static func sharedInstance() -> Self { Self() }
    var category: Category { .playAndRecord }
    private init() {}
}
@MainActor enum BackupKeepAlive { static func end() {} }
@MainActor final class SpeechRecognitionManager {
    static let shared = SpeechRecognitionManager()
    func stopRecording() {}
}
@MainActor final class GlobalAudioPlayer {
    static let shared = GlobalAudioPlayer()
    func stop() {}
}
@MainActor enum PlayerOffloadBridge { static func pauseForRecording() {} }
@MainActor final class VoiceOutputPlayer {
    static let shared = VoiceOutputPlayer()
    func stopAll() {}
}
@MainActor final class BackgroundKeepAliveManager {
    static let shared = BackgroundKeepAliveManager()
    var reservations = 0
    func suspendSilentAudioForMedia(caller: String) { reservations += 1 }
    func resumeSilentAudioForMedia(caller: String) { reservations -= 1; precondition(reservations >= 0) }
}
@MainActor enum FusionAudio { static func suspendWebAudio(_ suspended: Bool) {} }
@MainActor final class InputBoundary {
    var isRunning = true
    func stop() { isRunning = false }
}
@MainActor final class StoryPlaybackController {
    static let shared = StoryPlaybackController()
    func cancelVoiceInteraction() {}
}

@main struct XiaolanRecordingExclusionChecks {
    @MainActor static func main() throws {
        let audio = AudioSessionCoordinator.shared
        let keepAlive = BackgroundKeepAliveManager.shared
        func rejectsRecording(_ owner: UUID, line: UInt = #line) {
            let before = audio.hardwareBegins
            do { try audio.beginRecording(owner: owner); preconditionFailure("Voice exclusion failed at line \(line)") }
            catch {
                precondition(error.localizedDescription.contains("关闭语音模式"))
                precondition(audio.hardwareBegins == before && !audio.isRecording,
                             "A rejected recording must never reach hardware or acquire an owner")
            }
        }

        let firstOwner = UUID()
        try audio.beginRecording(owner: firstOwner)
        precondition(audio.isRecording && !audio.isIndependentVoiceEnabled && keepAlive.reservations == 1)
        precondition(!audio.reserveIndependentVoice(), "An unfinished recording must reject voice reservation")
        // A paused recorder keeps the same owner; resuming does not duplicate
        // it or its media suspension lease.
        try audio.beginRecording(owner: firstOwner)
        precondition(audio.isRecording && !audio.reserveIndependentVoice() && keepAlive.reservations == 1)
        audio.endRecording(owner: firstOwner)
        precondition(!audio.isRecording && keepAlive.reservations == 0)

        precondition(audio.reserveIndependentVoice())
        precondition(audio.reserveIndependentVoice() && keepAlive.reservations == 1,
                     "Repeated voice reservation must not leak a keep-alive suspension")
        audio.active.insert(.xiaolanCapture)
        rejectsRecording(UUID())
        let voice = VoiceHost()
        let microphone = voice.input!
        voice.pause() // The actual controller pause/invalidate methods.
        precondition(voice.isEnabled && voice.isPaused && !microphone.isRunning)
        precondition(!audio.active.contains(.xiaolanCapture) && audio.isIndependentVoiceEnabled)
        rejectsRecording(UUID())
        precondition(keepAlive.reservations == 1,
                     "Pause or the system-interruption pause must retain recording exclusion")

        voice.disable() // The actual controller disable and coordinator release.
        precondition(!voice.isEnabled && !audio.isIndependentVoiceEnabled && keepAlive.reservations == 0)
        let afterDisable = UUID()
        try audio.beginRecording(owner: afterDisable)
        precondition(audio.isRecording && !audio.reserveIndependentVoice(),
                     "Disabling voice permits recording, which then excludes voice again")
        audio.endRecording(owner: afterDisable)
        precondition(!audio.isRecording && keepAlive.reservations == 0)
        print("PASS: production ownership methods exclude voice and recording in both directions, retain reservation through actual pause, and release on actual disable")
    }
}
