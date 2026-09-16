import AVFAudio
import Foundation

/// Shared AVAudioSession handoff between capture and timeline playback.
/// Playback must not leave the session in `.playback` while a recording
/// session still owns the microphone.
enum RecordingAudioSession {
    static let playbackDidRelease = Notification.Name(
        "YiJie.speech_note.playbackDidReleaseAudioSession"
    )

    static func activatePlayback() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }

    static func notifyPlaybackReleased() {
        NotificationCenter.default.post(name: playbackDidRelease, object: nil)
    }
}
