// Only state/storage dependencies are fakes. The actual getter and loadSession
// source restoration are extracted by test_meeting_speech_gate.sh.
struct StoredSession {
    let source: String?
}
enum ChatMode { case normal, lite }
enum AgentRunRole { case main, executor }
enum AgentToolPolicy { case standalone, orchestrator }
@MainActor final class VoiceOutputState {
    static let shared = VoiceOutputState()
    var isEnabled = false
    var isMuted = false
    var canPlay: Bool { isEnabled && !isMuted }
}
@MainActor final class VoiceModePreference {
    static let shared = VoiceModePreference()
    var isCapturing = false
}
@MainActor final class AudioSessionCoordinator {
    static let shared = AudioSessionCoordinator()
    var isRecording = false
}
@MainActor final class AIChatViewModel {
    var sessionSource: String?
    var chatMode: ChatMode = .normal
    var agentRole: AgentRunRole = .main
    var groupId: String?
    var resolvedToolPolicy = AgentToolPolicy.orchestrator
}

@main struct MeetingSpeechGateChecks {
    @MainActor static func main() {
        let vm = AIChatViewModel()
        let output = VoiceOutputState.shared
        let capture = VoiceModePreference.shared
        let audio = AudioSessionCoordinator.shared
        let configuredSources: Set<String> = ["meeting_assistant", "xiaolan_voice", "arbitrary_adapter"]
        for source in configuredSources {
            AgentRuntimePolicies.register(source: source, policy: .init(allowsLiteMode: false, allowsAutomaticSpeech: false, restoresSourceOnLoad: true))
        }
        let silentSources = configuredSources.union(["subagent"])
        let childPreset = AgentRuntimePolicies.policy(for: "subagent")
        precondition(!childPreset.allowsAutomaticSpeech && !childPreset.allowsLiteMode
                     && childPreset.restoresSourceOnLoad && childPreset.headless,
                     "The production default subagent preset must remain silent and restorable without test registration")
        let sources: [String?] = [nil, "chat", "shortcut", "hardware", "group", "subagent", "meeting_assistant", "xiaolan_voice", "arbitrary_adapter"]
        for source in sources {
            vm.sessionSource = source
            for state in 0..<16 {
                output.isEnabled = state & 1 != 0
                output.isMuted = state & 2 != 0
                capture.isCapturing = state & 4 != 0
                audio.isRecording = state & 8 != 0
                let oldBehavior = output.canPlay && !capture.isCapturing && !audio.isRecording
                let expected = source.map(silentSources.contains) == true ? false : oldBehavior
                precondition(vm.testCanSpeakNow == expected,
                             "Unexpected speech gate for source=\(source ?? "nil"), state=\(state)")
            }
        }

        for source in sources {
            vm.sessionSource = source
            for mode in [ChatMode.normal, .lite] {
                vm.chatMode = mode
                for role in [AgentRunRole.main, .executor] {
                    vm.agentRole = role
                    for groupID in [nil, "meeting-group"] as [String?] {
                        vm.groupId = groupID
                        let oldBehavior = mode == .lite && role == .main
                            && groupID == nil && source != "hardware"
                        let expected = source.map(silentSources.contains) == true ? false : oldBehavior
                        precondition(vm.liteModeActive == expected,
                                     "Unexpected lite gate for source=\(source ?? "nil"), mode=\(mode), role=\(role), group=\(groupID ?? "nil")")
                    }
                }
            }
        }

        output.isEnabled = true
        output.isMuted = false
        capture.isCapturing = false
        audio.isRecording = true
        vm.sessionSource = "meeting_assistant"
        precondition(!vm.testCanSpeakNow)
        audio.isRecording = false
        precondition(!vm.testCanSpeakNow,
                     "Meeting plain text must stay silent after recording ends with read-replies enabled")
        vm.sessionSource = nil
        precondition(vm.testCanSpeakNow, "Ordinary chat must retain its enabled playback behavior")
        vm.sessionSource = "meeting_assistant"
        precondition(!vm.testCanSpeakNow, "Changing session source must immediately close the gate")
        vm.sessionSource = "subagent"
        vm.agentRole = .executor
        vm.chatMode = .lite
        vm.groupId = nil
        precondition(output.canPlay && !capture.isCapturing && !audio.isRecording && !vm.testCanSpeakNow,
                     "A background executor must not speak even when read-replies is enabled and audio is idle")
        precondition(!vm.liteModeActive && vm.effectiveToolPolicy == .standalone,
                     "The speech fence must retain an executor's full operator policy")

        // Independent policy flags also work for a source the engine does not know.
        vm.sessionSource = "arbitrary_adapter"; vm.chatMode = .lite; vm.agentRole = .main; vm.groupId = nil
        AgentRuntimePolicies.register(source: "arbitrary_adapter", policy: .init(allowsLiteMode: true, allowsAutomaticSpeech: false, restoresSourceOnLoad: true))
        precondition(!vm.testCanSpeakNow && vm.liteModeActive)
        AgentRuntimePolicies.register(source: "arbitrary_adapter", policy: .init(allowsLiteMode: false, allowsAutomaticSpeech: true, restoresSourceOnLoad: true))
        precondition(vm.testCanSpeakNow && !vm.liteModeActive)
        AgentRuntimePolicies.register(source: "arbitrary_adapter", policy: .init(allowsLiteMode: false, allowsAutomaticSpeech: false, restoresSourceOnLoad: true))

        // Cache eviction creates a fresh VM; loadSession must restore the
        // meeting source before a resumed or manually continued turn can speak.
        let reloaded = AIChatViewModel()
        reloaded.chatMode = .lite
        precondition(reloaded.sessionSource == nil && reloaded.testCanSpeakNow)
        precondition(reloaded.liteModeActive, "Ordinary chat retains the configured lite mode")
        reloaded.testRestoreSessionSource(from: .init(source: "meeting_assistant"))
        precondition(reloaded.sessionSource == "meeting_assistant" && !reloaded.testCanSpeakNow,
                     "Reloaded meeting sessions must retain their automatic speech prohibition")
        precondition(!reloaded.liteModeActive,
                     "Reloaded meeting sessions must retain their complete prompt and tools in global lite mode")
        let voiceReloaded = AIChatViewModel()
        voiceReloaded.chatMode = .lite
        voiceReloaded.testRestoreSessionSource(from: .init(source: "xiaolan_voice"))
        precondition(voiceReloaded.sessionSource == "xiaolan_voice" && !voiceReloaded.testCanSpeakNow && !voiceReloaded.liteModeActive,
                     "Cache-evicted independent voice must retain its full source policy and public-tool-only speech")
        let arbitraryReloaded = AIChatViewModel()
        arbitraryReloaded.testRestoreSessionSource(from: .init(source: "arbitrary_adapter"))
        precondition(arbitraryReloaded.sessionSource == "arbitrary_adapter" && !arbitraryReloaded.testCanSpeakNow)
        let childReloaded = AIChatViewModel()
        childReloaded.agentRole = .executor
        childReloaded.chatMode = .lite
        precondition(childReloaded.testCanSpeakNow, "A fresh fixture begins with the ordinary source policy")
        childReloaded.testRestoreSessionSource(from: .init(source: "subagent"))
        precondition(childReloaded.sessionSource == "subagent" && !childReloaded.testCanSpeakNow
                     && !childReloaded.liteModeActive && childReloaded.effectiveToolPolicy == .standalone,
                     "A cache-evicted child restores the actual default silent source policy while retaining full executor tools")
        for source in sources where source.map(silentSources.contains) != true {
            let ordinary = AIChatViewModel()
            ordinary.testRestoreSessionSource(from: .init(source: source))
            precondition(ordinary.sessionSource == nil && ordinary.testCanSpeakNow,
                         "Loading other persisted sources must retain existing behavior")
            ordinary.sessionSource = "hardware"
            ordinary.testRestoreSessionSource(from: .init(source: source))
            precondition(ordinary.sessionSource == "hardware",
                         "Non-meeting reload must not overwrite a caller-assigned source")
        }
        print("PASS: registered voice/third-source policies and default subagent silence survive cache reload; executor full tools, dynamic flags, capture states and ordinary speech/lite behavior remain intact")
    }
}
