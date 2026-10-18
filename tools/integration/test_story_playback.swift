import Combine
import Foundation

struct StoryAudio: Equatable {
    let id: UUID
    let title: String
    let fileName: String
    let duration: TimeInterval
}
@MainActor final class StoryLibraryStore {
    static let shared = StoryLibraryStore()
    var stories: [StoryAudio] = []
    func audioURL(for story: StoryAudio) throws -> URL {
        guard stories.contains(story) else { throw NSError(domain: "missing", code: 1) }
        return URL(fileURLWithPath: "/test/" + story.fileName)
    }
}
let AVAudioSessionInterruptionTypeKey = "interruption"
enum AVAudioSession {
    enum InterruptionType: UInt { case began = 1, ended = 0 }
    static let interruptionNotification = Notification.Name("test.interruption")
}
@MainActor final class AVAudioPlayer {
    static var latest: AVAudioPlayer?
    static var totalPlays = 0
    static var canPlay = true
    var duration: TimeInterval = 180
    var currentTime: TimeInterval = 0
    var isPlaying = false
    weak var delegate: (any AVAudioPlayerDelegate)?
    init(contentsOf url: URL) throws {
        if url.lastPathComponent == "bad.wav" { throw NSError(domain: "decode", code: 1) }
        Self.latest = self
    }
    func prepareToPlay() -> Bool { true }
    func play() -> Bool {
        Self.totalPlays += 1
        isPlaying = Self.canPlay
        return isPlaying
    }
    func pause() { isPlaying = false }
    func stop() { isPlaying = false; currentTime = 0 }
}
protocol AVAudioPlayerDelegate: AnyObject {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool)
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?)
}
@MainActor final class AudioSessionCoordinator {
    static let shared = AudioSessionCoordinator()
    static let storyPlaybackPreempted = Notification.Name("test.preempt")
    enum Intent { case storyPlayback }
    var isRecording = false
    var isIndependentVoiceEnabled = false
    var reject = false
    var leased = false
    func beginAndWait(_ intent: Intent) -> Bool { leased = !reject; return leased }
    func end(_ intent: Intent) { leased = false }
}
@MainActor final class BackgroundKeepAliveManager {
    static let shared = BackgroundKeepAliveManager()
    var leases = 0
    func suspendSilentAudioForMedia(caller: String) { leases += 1 }
    func resumeSilentAudioForMedia(caller: String) { leases -= 1; precondition(leases >= 0) }
}
@MainActor enum FusionAudio { static func suspendWebAudio(_ suspended: Bool) {} }

#if !STORY_NOTICE_FLOW
@MainActor final class AsyncTaskNoticeManager {
    static let shared = AsyncTaskNoticeManager()
    struct Notice {
        let sourceSessionId: String, taskType: String, taskId: String, title: String?, status: String, result: String
    }
    var notices: [Notice] = []
    func postNotice(sourceSessionId: String, taskType: String, taskId: String,
                    title: String?, status: String, result: String) async {
        notices.append(.init(sourceSessionId: sourceSessionId, taskType: taskType,
                             taskId: taskId, title: title, status: status, result: result))
    }
}
#endif

@main struct StoryPlaybackChecks {
    @MainActor static func main() async throws {
        let library = StoryLibraryStore()
        let first = StoryAudio(id: UUID(), title: "西游记", fileName: "first.wav", duration: 180)
        let second = StoryAudio(id: UUID(), title: "小王子", fileName: "second.wav", duration: 180)
        let bad = StoryAudio(id: UUID(), title: "损坏音频", fileName: "bad.wav", duration: 180)
        library.stories = [first, second, bad]
        let player = StoryPlaybackController(library: library)
        let audio = AudioSessionCoordinator.shared
        let keepAlive = BackgroundKeepAliveManager.shared
        func status() -> String { player.snapshot()["status"] as! String }
        func rejects(_ operation: () throws -> Void) {
            do { try operation(); preconditionFailure("Expected refusal") } catch {}
        }

        try player.play(first)
        precondition(player.isPlaying && status() == "playing" && audio.leased && keepAlive.leases == 1)
        AVAudioPlayer.latest!.currentTime = 31
        player.pause()
        precondition(player.currentTime == 31 && status() == "paused" && !audio.leased && keepAlive.leases == 0)
        try player.resume()
        precondition(player.currentTime == 31 && player.isPlaying && keepAlive.leases == 1)

        player.beginVoiceInteraction()
        precondition(!player.isPlaying && status() == "waiting_for_voice" && keepAlive.leases == 0)
        let playsBeforeReply = AVAudioPlayer.totalPlays
        try player.play(second)
        precondition(player.currentStoryID == second.id && status() == "waiting_for_voice")
        precondition(AVAudioPlayer.totalPlays == playsBeforeReply, "Preparing a story must not speak over a reply")
        player.finishVoiceInteraction()
        precondition(player.isPlaying && AVAudioPlayer.totalPlays == playsBeforeReply + 1)

        player.beginVoiceInteraction()
        player.pause()
        let playsAfterPause = AVAudioPlayer.totalPlays
        player.finishVoiceInteraction()
        precondition(status() == "paused" && AVAudioPlayer.totalPlays == playsAfterPause, "Explicit pause cancels auto-resume")
        player.beginVoiceInteraction()
        try player.resume()
        player.cancelVoiceInteraction()
        player.finishVoiceInteraction()
        precondition(!player.isPlaying && AVAudioPlayer.totalPlays == playsAfterPause, "Cancelled voice cannot start queued audio")
        player.beginVoiceInteraction()
        try player.play(first)
        player.stop()
        player.finishVoiceInteraction()
        precondition(status() == "stopped" && keepAlive.leases == 0)

        try player.play(first)
        let oldAudio = AVAudioPlayer.latest!
        rejects { try player.play(bad) }
        precondition(player.currentStoryID == first.id && oldAudio.isPlaying, "Decode failure preserves the current story")
        rejects { try player.seek(to: .nan) }
        rejects { try player.seek(to: -1) }
        rejects { try player.seek(to: 181) }
        try player.seek(to: 75)
        precondition(player.currentTime == 75)

        NotificationCenter.default.post(name: AudioSessionCoordinator.storyPlaybackPreempted, object: nil)
        precondition(!player.isPlaying && player.currentTime == 75 && keepAlive.leases == 0)
        player.finishVoiceInteraction()
        precondition(!player.isPlaying, "Other audio preemption requires explicit resume")
        audio.isRecording = true
        rejects { try player.play(second) }
        rejects { try player.resume() }
        rejects { try player.next() }
        precondition(player.currentStoryID == first.id && !player.isPlaying)
        audio.isRecording = false
        audio.reject = true
        rejects { try player.resume() }
        precondition(!player.isPlaying && !audio.leased && keepAlive.leases == 0)
        audio.reject = false

        AVAudioPlayer.canPlay = false
        rejects { try player.resume() }
        precondition(!player.isPlaying && keepAlive.leases == 0 && player.error != nil)
        AVAudioPlayer.canPlay = true
        try player.resume()
        oldAudio.currentTime = 0 // Native playback may reset position on completion.
        oldAudio.isPlaying = false
        oldAudio.delegate?.audioPlayerDidFinishPlaying(oldAudio, successfully: true)
        for _ in 0..<5 { await Task.yield() }
        precondition(status() == "finished" && player.currentTime == 180 && keepAlive.leases == 0)
        try player.resume()
        precondition(player.currentTime == 0 && oldAudio.isPlaying)
        let staleDelegate = oldAudio.delegate!
        oldAudio.isPlaying = false
        staleDelegate.audioPlayerDidFinishPlaying(oldAudio, successfully: true)
        try player.seek(to: 15)
        try player.resume()
        for _ in 0..<5 { await Task.yield() }
        precondition(player.isPlaying && player.currentTime == 15, "An old completion cannot pause a newer seek/resume")
        player.beginVoiceInteraction()
        try player.seek(to: 180)
        let playsAtEnd = AVAudioPlayer.totalPlays
        precondition(status() == "finished" && keepAlive.leases == 0)
        player.finishVoiceInteraction()
        precondition(!player.isPlaying && AVAudioPlayer.totalPlays == playsAtEnd, "Seeking to the end cancels queued playback")
        try player.seek(to: 15)
        try player.resume()
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
                                        userInfo: [AVAudioSessionInterruptionTypeKey: UInt(1)])
        precondition(!player.isPlaying && keepAlive.leases == 0)
        try player.next()
        precondition(player.currentStoryID == second.id && player.isPlaying)
        library.stories = [second]
        let singleStoryAudio = AVAudioPlayer.latest!
        singleStoryAudio.currentTime = 45
        rejects { try player.next() }
        precondition(singleStoryAudio.currentTime == 45 && player.isPlaying, "换一篇 must not restart the sole story")
        player.pause()
        library.stories = []
        rejects { try player.resume() }
        precondition(status() == "stopped" && keepAlive.leases == 0)
        print("PASS: story playback, truthful failures, progress, voice holds, cancellation, recording priority, interruptions and balanced audio leases")
    }
}
