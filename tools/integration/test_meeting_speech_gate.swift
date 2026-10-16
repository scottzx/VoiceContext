// Only state/storage dependencies are fakes. The actual getter and loadSession
// source restoration are extracted by test_meeting_speech_gate.sh.
struct StoredSession {
    let source: String?
}
enum ChatMode { case normal, lite }
enum AgentRunRole { case main, executor }
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
}

@main struct MeetingSpeechGateChecks {
    @MainActor static func main() {
        let vm = AIChatViewModel()
        let output = VoiceOutputState.shared
        let capture = VoiceModePreference.shared
        let audio = AudioSessionCoordinator.shared
        let sources: [String?] = [nil, "chat", "shortcut", "hardware", "group", "meeting_assistant"]
        for source in sources {
            vm.sessionSource = source
            for state in 0..<16 {
                output.isEnabled = state & 1 != 0
                output.isMuted = state & 2 != 0
                capture.isCapturing = state & 4 != 0
                audio.isRecording = state & 8 != 0
                let oldBehavior = output.canPlay && !capture.isCapturing && !audio.isRecording
                let expected = source == "meeting_assistant" ? false : oldBehavior
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
                        let expected = source == "meeting_assistant" ? false : oldBehavior
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
        for source in sources where source != "meeting_assistant" {
            let ordinary = AIChatViewModel()
            ordinary.testRestoreSessionSource(from: .init(source: source))
            precondition(ordinary.sessionSource == nil && ordinary.testCanSpeakNow,
                         "Loading other persisted sources must retain existing behavior")
            ordinary.sessionSource = "hardware"
            ordinary.testRestoreSessionSource(from: .init(source: source))
            precondition(ordinary.sessionSource == "hardware",
                         "Non-meeting reload must not overwrite a caller-assigned source")
        }
        print("PASS: actual speech/lite gates and meeting source restoration; voice states, lite inheritance, cache reload and other sources")
    }
}
