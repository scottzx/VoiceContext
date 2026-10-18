import AVFoundation
import Combine
import Foundation

/// The library and voice tool share one player. A voice interaction suspends
/// sound while preserving the user's playback intent until its reply ends.
@MainActor
final class StoryPlaybackController: ObservableObject {
    static let shared = StoryPlaybackController()

    @Published private(set) var currentStoryID: UUID?
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var error: String?

    private let library: StoryLibraryStore
    private var player: AVAudioPlayer?
    private var playerDelegate: StoryPlaybackDelegate?
    private var playbackID: UUID?
    private var completionGeneration: UUID?
    private var sourceSessionID: String?
    private var finished = false
    private var title = ""
    private var playRequested = false
    private var voiceInteraction = false
    private var audioLease = false
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    var isWaitingForVoice: Bool { voiceInteraction && playRequested }

    init(library: StoryLibraryStore? = nil) {
        self.library = library ?? .shared
        observers.append(NotificationCenter.default.addObserver(
            forName: AudioSessionCoordinator.storyPlaybackPreempted, object: nil, queue: .main
        ) { [weak self] _ in
            // The coordinator posts on the main actor before changing profiles.
            MainActor.assumeIsolated { self?.pause() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notice in
            guard let raw = notice.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            MainActor.assumeIsolated { self?.pause() }
        })
    }

    func play(_ story: StoryAudio, sourceSessionID: String? = nil) throws {
        try ensurePlaybackAllowed()
        do {
            let nextPlayer = try AVAudioPlayer(contentsOf: library.audioURL(for: story))
            guard nextPlayer.duration.isFinite, nextPlayer.duration > 0, nextPlayer.prepareToPlay() else {
                throw failure("无法读取这篇故事的音频，请重新导入。")
            }
            stopPlayer()
            player = nextPlayer
            playbackID = UUID()
            self.sourceSessionID = sourceSessionID
            currentStoryID = story.id
            title = story.title
            currentTime = 0
            duration = nextPlayer.duration
            playRequested = true
            finished = false
            error = nil
            try startIfReady()
        } catch {
            self.error = error.localizedDescription
            throw error
        }
    }

    func pause() {
        playRequested = false
        suspendPlayer()
        error = nil
    }

    func resume(sourceSessionID: String? = nil) throws {
        try ensurePlaybackAllowed()
        guard let player else { throw failure("请先选择一篇故事。") }
        // A removed file must not be resumed through an old player instance.
        guard let story = library.stories.first(where: { $0.id == currentStoryID }) else {
            stop()
            throw failure("这篇故事已从故事库移除，请重新选择。")
        }
        _ = try library.audioURL(for: story)
        if finished || currentTime >= duration {
            player.currentTime = 0; currentTime = 0; finished = false
            playbackID = UUID()
            self.sourceSessionID = sourceSessionID
        } else if sourceSessionID != self.sourceSessionID {
            // Explicit resume belongs to the currently supplied conversation,
            // including nil when manual playback has no active voice session.
            playbackID = UUID()
            self.sourceSessionID = sourceSessionID
        }
        playRequested = true
        error = nil
        try startIfReady()
    }

    func bindCompletionSessionIfUnowned(_ sessionID: String) {
        guard !sessionID.isEmpty, sourceSessionID == nil,
              currentStoryID != nil, !finished else { return }
        sourceSessionID = sessionID
    }

    func next(sourceSessionID: String? = nil) throws {
        guard !library.stories.isEmpty else { throw failure("故事库还是空的，请先导入音频。") }
        let index = library.stories.firstIndex(where: { $0.id == currentStoryID })
        guard index == nil || library.stories.count > 1 else {
            throw failure("故事库里只有这一篇，请先导入其他故事。")
        }
        try play(library.stories[index.map { ($0 + 1) % library.stories.count } ?? 0], sourceSessionID: sourceSessionID)
    }

    func seek(to seconds: TimeInterval) throws {
        guard let player else { throw failure("请先选择一篇故事。") }
        guard seconds.isFinite, seconds >= 0, seconds <= duration else {
            throw failure("播放位置必须在这篇故事的时长范围内。")
        }
        if finished && seconds < duration { playbackID = UUID() }
        player.currentTime = seconds
        currentTime = seconds
        finished = seconds >= duration
        if finished {
            playRequested = false
            suspendPlayer()
        } else if isPlaying {
            installCompletionHandler()
        }
        refreshProgress()
    }

    func stop() {
        playRequested = false
        stopPlayer()
        currentStoryID = nil
        title = ""
        currentTime = 0
        duration = 0
        finished = false
        error = nil
    }

    func beginVoiceInteraction() {
        voiceInteraction = true
        suspendPlayer()
    }

    func finishVoiceInteraction() {
        voiceInteraction = false
        guard playRequested else { return }
        do { try startIfReady() } catch { self.error = error.localizedDescription }
    }

    func cancelVoiceInteraction() {
        guard voiceInteraction else { return }
        voiceInteraction = false
        // A cancelled or stale turn must never start a queued story afterwards.
        pause()
    }

    func snapshot() -> [String: Any] {
        refreshProgress()
        let status: String
        if currentStoryID == nil { status = "stopped" }
        else if isPlaying { status = "playing" }
        else if voiceInteraction && playRequested { status = "waiting_for_voice" }
        else if duration > 0 && currentTime >= duration { status = "finished" }
        else { status = "paused" }
        return [
            "status": status,
            "playback_id": playbackID?.uuidString as Any? ?? NSNull(),
            "current_story_id": currentStoryID?.uuidString as Any? ?? NSNull(),
            "title": title,
            "position_seconds": currentTime,
            "duration_seconds": duration,
            "play_requested": playRequested,
            "error": error as Any? ?? NSNull()
        ]
    }

    private func ensurePlaybackAllowed() throws {
        guard !AudioSessionCoordinator.shared.isRecording else {
            throw failure("当前有一条未结束的录音，请先结束录音再播放故事。")
        }
    }

    private func startIfReady() throws {
        guard playRequested, !voiceInteraction, let player else { return }
        guard !isPlaying || !player.isPlaying else { return }
        do {
            try ensurePlaybackAllowed()
            guard AudioSessionCoordinator.shared.beginAndWait(.storyPlayback) else {
                AudioSessionCoordinator.shared.end(.storyPlayback)
                throw failure("当前音频正被占用，请稍后继续播放。")
            }
            if !audioLease {
                audioLease = true
                BackgroundKeepAliveManager.shared.suspendSilentAudioForMedia(caller: "VoiceContext.story")
                FusionAudio.suspendWebAudio(true)
            }
            installCompletionHandler()
            guard player.play() else { throw failure("音频未能开始播放，请重新选择故事。") }
            isPlaying = player.isPlaying
            guard isPlaying else { throw failure("音频未能开始播放，请重新选择故事。") }
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshProgress() }
            }
        } catch {
            playRequested = false
            suspendPlayer()
            self.error = error.localizedDescription
            throw error
        }
    }

    private func refreshProgress() {
        guard let player else { return }
        if finished { currentTime = duration; return }
        currentTime = min(duration, max(0, player.currentTime))
        guard isPlaying, !player.isPlaying else { return }
        playRequested = false
        suspendPlayer(keepingCompletion: true)
        // The completion delegate is authoritative: AVAudioPlayer may reset its
        // currentTime on completion, so a time threshold cannot detect the end.
        error = "故事播放已中断，点击继续可从当前位置播放。"
    }

    private func playbackFinished(successfully: Bool) {
        let completedID = playbackID
        let completedStoryID = currentStoryID
        let completedSessionID = sourceSessionID
        let completedTitle = title
        let completedDuration = duration
        playRequested = false
        suspendPlayer()
        finished = successfully
        if successfully {
            currentTime = duration; error = nil
            if let completedID, let completedStoryID, let completedSessionID {
                let result: [String: Any] = [
                    "playback_id": completedID.uuidString,
                    "story_id": completedStoryID.uuidString,
                    "title": completedTitle,
                    "status": "finished",
                    "position_seconds": completedDuration,
                    "duration_seconds": completedDuration
                ]
                let data = (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])) ?? Data()
                let output = String(decoding: data, as: UTF8.self)
                Task {
                    await AsyncTaskNoticeManager.shared.postNotice(
                        sourceSessionId: completedSessionID,
                        taskType: "story_playback", taskId: completedID.uuidString,
                        title: completedTitle, status: "done", result: output
                    )
                }
            }
        }
        else { error = "故事音频解码失败，请重新导入。" }
    }

    private func installCompletionHandler() {
        let id = UUID()
        completionGeneration = id
        let delegate = StoryPlaybackDelegate { [weak self] success in
            guard let self, self.completionGeneration == id else { return }
            self.playbackFinished(successfully: success)
        }
        playerDelegate = delegate
        player?.delegate = delegate
    }

    private func suspendPlayer(keepingCompletion: Bool = false) {
        if let player {
            if !finished { currentTime = min(duration, max(0, player.currentTime)) }
            player.pause()
        }
        isPlaying = false
        timer?.invalidate()
        timer = nil
        if !keepingCompletion {
            completionGeneration = nil
            player?.delegate = nil
            playerDelegate = nil
        }
        AudioSessionCoordinator.shared.end(.storyPlayback)
        if audioLease {
            audioLease = false
            BackgroundKeepAliveManager.shared.resumeSilentAudioForMedia(caller: "VoiceContext.story")
            if !AudioSessionCoordinator.shared.isRecording && !AudioSessionCoordinator.shared.isIndependentVoiceEnabled {
                FusionAudio.suspendWebAudio(false)
            }
        }
    }

    private func stopPlayer() {
        suspendPlayer()
        player?.stop()
        player = nil
        playerDelegate = nil
        playbackID = nil
        sourceSessionID = nil
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "Yima.StoryPlayer", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private final class StoryPlaybackDelegate: NSObject, AVAudioPlayerDelegate {
    private let completion: @MainActor (Bool) -> Void
    init(completion: @escaping @MainActor (Bool) -> Void) { self.completion = completion }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.completion(flag) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in self?.completion(false) }
    }
}
