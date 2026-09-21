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
        // `.spokenAudio` + `.playback` keeps recorded voice playing after the
        // user leaves the app, which is the audible background mode App Review
        // checks under guideline 2.5.4. Fall back to `.default` if the session
        // is still tearing down a just-ended `.record` capture.
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
        } catch {
            try? session.setCategory(.playback, mode: .default, options: [])
            try? session.setActive(true)
        }
    }

    static func notifyPlaybackReleased() {
        NotificationCenter.default.post(name: playbackDidRelease, object: nil)
    }
}
