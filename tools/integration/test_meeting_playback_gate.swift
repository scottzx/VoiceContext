import Foundation

func AppLocalized(_ value: String) -> String { value }

@MainActor enum PlaybackLog {
    static var events: [String] = []
}

@MainActor enum VoiceOutputPreferences {
    static var isMuted = false
    static let speedMultiplier = 1.0
}

struct VoiceSynthesisRequest {
    let input: String
    let model: String?
    let voice: String?
    let speed: Double
}

@MainActor protocol VoiceProvider {
    func synthesize(_ request: VoiceSynthesisRequest) async throws -> Data
}

/// Deliberately ignores cancellation, like a provider with an uncancellable
/// continuation. The production token checks must reject its late response.
@MainActor final class RemoteVoiceProvider: VoiceProvider {
    var requests = 0
    var returned = 0
    private var pending: CheckedContinuation<Data, Error>?
    var isPending: Bool { pending != nil }
    func synthesize(_ request: VoiceSynthesisRequest) async throws -> Data {
        requests += 1
        PlaybackLog.events.append("synthesis")
        let result = try await withCheckedThrowingContinuation { pending = $0 }
        returned += 1
        PlaybackLog.events.append("synthesis-return")
        return result
    }
    func complete() {
        let continuation = pending
        pending = nil
        continuation?.resume(returning: Data([1, 2, 3]))
    }
}

@MainActor final class SystemVoiceProvider: VoiceProvider {
    func synthesize(_ request: VoiceSynthesisRequest) async throws -> Data { Data() }
}

@MainActor enum VoiceProviderResolver {
    struct Entry { struct Model { let id: String }; let model: Model }
    static var provider: any VoiceProvider = RemoteVoiceProvider()
    static func outputProvider() -> any VoiceProvider { provider }
    static func resolvedSystemOutputVoiceId() -> String { "system" }
    static func resolvedOutputEntry() -> Entry? { .init(model: .init(id: "remote-tts")) }
}

enum VoiceProviderError: Error { case noAudioData }

@MainActor final class AVAudioPlayer {
    var isPlaying = false
    var isMeteringEnabled = false
    init(data: Data) throws { PlaybackLog.events.append("player-created") }
    func prepareToPlay() { PlaybackLog.events.append("prepare") }
    func updateMeters() { precondition(isMeteringEnabled) }
    func averagePower(forChannel channel: Int) -> Float { -20 }
    func play() -> Bool {
        isPlaying = true
        PlaybackLog.events.append("play")
        return true
    }
    func stop() {
        isPlaying = false
        PlaybackLog.events.append("stop")
    }
}

@MainActor final class AudioSessionCoordinator {
    static let shared = AudioSessionCoordinator()
    var starts = 0
    var ends = 0
    var isLeased = false
    func reset() { starts = 0; ends = 0; isLeased = false }
    func beginMeetingAssistantSpeech() -> Bool {
        precondition(!isLeased, "A playback lease must never overlap another lease")
        starts += 1
        isLeased = true
        PlaybackLog.events.append("lease-begin")
        return true
    }
    func endMeetingAssistantSpeech() {
        precondition(isLeased, "A playback lease must not be released twice")
        ends += 1
        isLeased = false
        PlaybackLog.events.append("lease-end")
    }
}

@MainActor final class MeetingAssistantBridge {
    var currentID: UUID?
    var actualSpeechID: UUID?
    var starts = 0
    var ends = 0
    var speechOutputLevel: Float = 0
    var notices: [String] = []
    func canSpeak(to id: UUID) -> Bool { currentID == id }
    var canWake: Bool { currentID != nil && actualSpeechID == nil }
    func beginSpeech(requestID: UUID) -> Bool {
        guard canSpeak(to: requestID), actualSpeechID == nil else { return false }
        actualSpeechID = requestID
        starts += 1
        PlaybackLog.events.append("speech-begin")
        return true
    }
    func endSpeech(requestID: UUID) {
        guard actualSpeechID == requestID else { return }
        actualSpeechID = nil
        speechOutputLevel = 0
        ends += 1
        PlaybackLog.events.append("speech-end")
    }
    func updateSpeechOutputLevel(_ level: Float, requestID: UUID) {
        guard actualSpeechID == requestID else { return }
        speechOutputLevel = level
    }
    func showSpeechNotice(requestID: UUID, text: String) { notices.append(text) }
}

@MainActor final class MeetingAssistantController {
    let bridge = MeetingAssistantBridge()
    var speechTask: Task<Void, Never>?
    var speechToken: UUID?
    var speakingRequestID: UUID?
    var leasedRequestID: UUID?
    var player: AVAudioPlayer?
    func stopWakeCue() {}
}

@main struct MeetingPlaybackGateChecks {
    @MainActor static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<2_000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        preconditionFailure("Playback test did not reach its expected state")
    }

    @MainActor static func setup() -> (MeetingAssistantController, RemoteVoiceProvider, UUID) {
        PlaybackLog.events = []
        VoiceOutputPreferences.isMuted = false
        AudioSessionCoordinator.shared.reset()
        let controller = MeetingAssistantController()
        let provider = RemoteVoiceProvider()
        VoiceProviderResolver.provider = provider
        let id = UUID()
        controller.bridge.currentID = id
        return (controller, provider, id)
    }

    @MainActor static func main() async {
        let audio = AudioSessionCoordinator.shared
        do {
            let (controller, provider, id) = setup()
            let speaking = Task { await controller.speakForCheck(id) }
            await waitUntil { provider.isPending }
            precondition(controller.bridge.canWake && controller.bridge.starts == 0,
                         "Remote synthesis must leave acoustic wake enabled")
            precondition(audio.starts == 0 && controller.player == nil)
            precondition(controller.bridge.speechOutputLevel == 0)
            provider.complete()
            await waitUntil { controller.player?.isPlaying == true }
            precondition(!controller.bridge.canWake && controller.bridge.starts == 1)
            precondition(controller.bridge.speechOutputLevel == 0.6,
                         "Assistant animation follows the actual output player's level")
            precondition(Array(PlaybackLog.events.prefix(6)) == [
                "synthesis", "synthesis-return", "speech-begin", "lease-begin", "player-created", "prepare"
            ], "Only completed synthesis may acquire the speech gate and playback lease")
            controller.player?.isPlaying = false
            await speaking.value
            precondition(audio.starts == 1 && audio.ends == 1 && !audio.isLeased)
            precondition(controller.bridge.ends == 1 && controller.bridge.canWake)
            precondition(controller.bridge.speechOutputLevel == 0)
            precondition(Array(PlaybackLog.events.suffix(3)) == ["stop", "lease-end", "speech-end"])
            precondition(controller.speechToken == nil && controller.speechTask == nil && controller.player == nil)
            controller.stopForCheck()
            precondition(audio.ends == 1 && controller.bridge.ends == 1,
                         "Repeated cleanup must not release the lease or speech gate twice")
        }

        for action in ["stop", "close", "cancel"] {
            let (controller, provider, id) = setup()
            let speaking = Task { await controller.speakForCheck(id) }
            await waitUntil { provider.isPending }
            switch action {
            case "close": controller.bridge.currentID = nil
            case "cancel": speaking.cancel()
            default: controller.stopForCheck()
            }
            await speaking.value
            provider.complete()
            await waitUntil { provider.returned == 1 }
            for _ in 0..<10 { await Task.yield() }
            precondition(audio.starts == 0 && audio.ends == 0 && controller.bridge.starts == 0,
                         "Cancelled or closed synthesis must never acquire playback permission")
            precondition(!PlaybackLog.events.contains("play") && controller.player == nil)
        }

        do {
            let (controller, lateProvider, id) = setup()
            let oldSpeech = Task { await controller.speakForCheck(id) }
            await waitUntil { lateProvider.isPending }
            controller.stopForCheck()
            await oldSpeech.value
            let nextProvider = RemoteVoiceProvider()
            VoiceProviderResolver.provider = nextProvider
            let nextSpeech = Task { await controller.speakForCheck(id) }
            await waitUntil { nextProvider.isPending }
            let nextToken = controller.speechToken
            lateProvider.complete()
            await waitUntil { lateProvider.returned == 1 }
            for _ in 0..<10 { await Task.yield() }
            precondition(controller.speechToken == nextToken && nextProvider.isPending && audio.starts == 0,
                         "A stale synthesis defer must not clear a newer speech token")
            nextProvider.complete()
            await waitUntil { controller.player?.isPlaying == true }
            controller.player?.isPlaying = false
            await nextSpeech.value
            precondition(nextProvider.requests == 1 && audio.starts == 1 && audio.ends == 1)
        }

        do {
            let (controller, provider, id) = setup()
            VoiceOutputPreferences.isMuted = true
            await controller.speakForCheck(id)
            precondition(provider.requests == 0 && audio.starts == 0 && controller.bridge.starts == 0,
                         "Muted replies must not issue synthesis or acquire playback permission")
            precondition(controller.bridge.notices.contains(where: { $0.contains("静音") }))
        }
        print("PASS: actual meeting playback allows wake during synthesis, gates only playback, rejects late audio, releases once and respects mute")
    }
}
