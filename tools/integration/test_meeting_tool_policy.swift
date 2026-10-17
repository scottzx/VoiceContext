import Foundation

func AppLocalized(_ text: String) -> String { text }
enum AgentToolPolicy { case standalone, orchestrator }
enum ChatMode { case full, lite }
enum BrowserAction: String, CaseIterable { case navigate }
enum Modality { case imageInput }
struct Capabilities { var supportedModalities: Set<Modality> = [] }
struct Model { var capabilities = Capabilities() }
struct Entry { var model = Model() }
enum VisionGroupResolver { static let isConfigured = false }
func hostDefinition(_ name: String) -> AgentToolDefinition {
    .init(name: name, description: name, parameters: [:], required: [])
}
enum MeetingAnswerUserTool {
    static var definition: AgentToolDefinition { hostDefinition("answer_user") }
    static func canRequestDelivery(sessionID: String?) -> Bool { true }
    static let deliveryReminder = "Reply through answer_user"
}
enum MeetingAppleTool { static var definition: AgentToolDefinition { hostDefinition("apple_native") } }
enum YimaItemsAgentTool { static var definition: AgentToolDefinition { hostDefinition("yima_items") } }
enum AppNavigationTool { static var definition: AgentToolDefinition { hostDefinition("app_navigation") } }
enum AppPresentationTool { static var definition: AgentToolDefinition { hostDefinition("app_present") } }
enum ChatHistorySearchTool { static var definition: AgentToolDefinition { hostDefinition("chat_history_search") } }
enum AgentDirectoryTools {
    static var definitions: [AgentToolDefinition] { [hostDefinition("create_agent"), hostDefinition("list_agents"), hostDefinition("send_agent_message")] }
    static func promptSection(canDispatch: Bool) -> String { "Agent directory: list_agents / send_agent_message / create_agent" }
}
enum XiaolanAgent { static let id = "fixture-xiaolan" }
enum SystemPromptBuilder {
    struct IdentityPolicy {
        var fallbackName: String
        var identityTemplate: String
        var usesDefaultPersona: Bool
        var includesPersonaEditHint: Bool
    }
    static func identitySection(for id: String?, policy: IdentityPolicy? = nil) -> String {
        guard let policy else { return "You are Yima.\n\n" }
        return policy.identityTemplate.replacingOccurrences(of: "{name}", with: policy.fallbackName) + "\n\n"
    }
}
enum LiteModePrompt {
    static var toolDefinitions: [AgentToolDefinition] { [hostDefinition("shell_execute")] }
    static func render(agentId: String?, timeString: String) -> String { "Lite prompt" }
}

enum StreamResult {
    struct ToolEntry {
        let id = UUID().uuidString
        let name: String
        var args: [String: Any] = [:]
        let blockIdx = 0
    }
}
enum OutcomePart {
    case toolResult(String, String, String, Bool, Data?, String?, String?, String?)
}
@MainActor final class Hooks {
    struct Gate { let index = 0; var blockReason: String? = nil }
    var willRunCount = 0
    var didRunCount = 0
    func willRunTool(name: String, argsJSON: String?) -> Gate? { willRunCount += 1; return Gate() }
    func didRunTool(name: String, index: Int, succeeded: Bool) { didRunCount += 1 }
}
@MainActor final class AIChatViewModel {
    enum Role { case main, executor }
    struct BatchImageBudget {}
    struct ToolExecOutcome { let cancelled: Bool; let resultPart: OutcomePart }
    var agentRole: Role = .main
    var resolvedToolPolicy: AgentToolPolicy = .standalone
    var sessionSource: String? = "meeting_assistant"
    var groupId: String?
    var agentId: String?
    var sessionId: String? = "meeting-session"
    var groupPromptBlock: String?
    var approximateTimeString = "2026-10-12 10:00"
    var executorAndStandalonePrompt = "Standalone operator"
    var memoryEnabled = true
    var isNoticeDriven = false
    var chatMode: ChatMode = .lite
    var selectedModel = Model()
    var hooks: Hooks? = Hooks()
    var executed: [String] = []
    var refused: [String] = []
    func resolveCurrentEntry() -> Entry? { nil }
    func executeSingleToolUseInner(tu: StreamResult.ToolEntry, msgIdx: Int, tools: [AgentToolDefinition], batchBudget: BatchImageBudget) async -> ToolExecOutcome {
        executed.append(tu.name)
        return .init(cancelled: false, resultPart: .toolResult(tu.id, tu.name, "executed", false, nil, nil, nil, nil))
    }
    func hookBlockedOutcome(tu: StreamResult.ToolEntry, msgIdx: Int, reason: String, isPolicyBlock: Bool = false) async -> ToolExecOutcome {
        precondition(isPolicyBlock)
        refused.append(tu.name)
        return .init(cancelled: false, resultPart: .toolResult(tu.id, tu.name, reason, true, nil, nil, nil, nil))
    }
}

@main struct MeetingToolPolicyChecks {
    @MainActor static func main() async {
        VoiceAgentConfiguration.install()
        let shared: Set<String> = ["answer_user", "apple_native", "yima_items", "memory_get", "memory_write"]
        let meetingTools = shared.union(SubagentTools.names)
        let voiceTools = meetingTools.union(["app_navigation", "app_present"])
        var third = AgentRuntimePolicies.policy(for: "xiaolan_voice")
        third.prompt = { _, _, notice in notice ? "Third delivery answer_user" : "Third interactive tools" }
        AgentRuntimePolicies.register(source: "fixture_interaction", policy: third)

        for (source, expected) in [("meeting_assistant", meetingTools), ("xiaolan_voice", voiceTools), ("fixture_interaction", voiceTools)] {
            let vm = AIChatViewModel()
            vm.sessionSource = source
            precondition(vm.effectiveToolPolicy == .orchestrator && !vm.liteModeActive,
                         "Configuration applies without source-specific engine branches")
            let live = vm.makeAgentTools()
            precondition(Set(live.map(\.name)) == expected)
            for name in expected {
                _ = await vm.executeSingleToolUse(tu: .init(name: name), msgIdx: 0, tools: live, batchBudget: .init())
            }
            precondition(Set(vm.executed) == expected)
            for name in ["shell_execute", "browser_use", "file_read", "file_write", "file_edit", "read_image", "chat_history_search", "create_agent", "list_agents", "send_agent_message", "delegate_to_yima", "deliver_to_xiaolan", "unknown_tool"] {
                _ = await vm.executeSingleToolUse(tu: .init(name: name), msgIdx: 0,
                                                tools: live + [hostDefinition(name)], batchBudget: .init())
            }
            precondition(Set(vm.executed) == expected && vm.refused.count == 13,
                         "A forged registration cannot exceed the configured ceiling")
            precondition(vm.hooks!.willRunCount == expected.count && vm.hooks!.didRunCount == expected.count)
            let livePrompt = vm.promptForCheck()
            precondition(!livePrompt.contains("You are Yima") && !livePrompt.contains("delegate_to_yima"))
            if source != "fixture_interaction" {
                precondition(livePrompt.contains("小蓝同学") && livePrompt.contains("spawn_subagent") && livePrompt.contains("message_subagent") && livePrompt.contains("stop_subagent"))
            }
            vm.memoryEnabled = false
            precondition(!vm.makeAgentTools().contains { ["memory_get", "memory_write"].contains($0.name) })
            precondition(vm.runtimeToolRefusal(name: "memory_get", tools: vm.makeAgentTools()) != nil)

            let notice = AIChatViewModel()
            notice.sessionSource = source
            notice.isNoticeDriven = true
            notice.groupPromptBlock = "FULL_CONTROLLER_MARKER " + expected.sorted().joined(separator: " ")
            let noticeTools = notice.makeAgentTools()
            precondition(noticeTools.map(\.name) == ["answer_user"])
            let noticePrompt = notice.promptForCheck()
            precondition(noticePrompt.contains("answer_user") && !noticePrompt.contains("FULL_CONTROLLER_MARKER"))
            precondition(noticePrompt.contains("Memory tools are unavailable") && !noticePrompt.contains("memory_get") && !noticePrompt.contains("memory_write"),
                         "The assembled notice prompt cannot re-advertise memory tools through its footer")
            notice.memoryEnabled = false
            precondition(!notice.promptForCheck().contains("memory_get") && !notice.promptForCheck().contains("memory_write"),
                         "A disabled-memory footer also respects the notice ceiling")
            notice.memoryEnabled = true
            for forbidden in expected.subtracting(["answer_user"]).union(["delegate_to_yima", "deliver_to_xiaolan"]) {
                precondition(!noticePrompt.contains(forbidden), "Notice prompt cannot advertise unavailable \(forbidden)")
            }
            let deniedCalls: [StreamResult.ToolEntry] = expected.subtracting(["answer_user"]).sorted().map { .init(name: $0) } + [
                .init(name: "apple_native", args: ["command": "apple-calendar", "action": "list"]),
                .init(name: "apple_native", args: ["command": "apple-reminders", "action": "create"]),
                .init(name: "yima_items", args: ["action": "open"]),
                .init(name: "yima_items", args: ["action": "create"]),
                .init(name: "shell_execute"), .init(name: "unknown_tool")
            ]
            let forgedTools = noticeTools + deniedCalls.map { hostDefinition($0.name) }
            for call in deniedCalls {
                _ = await notice.executeSingleToolUse(tu: call, msgIdx: 0, tools: forgedTools, batchBudget: .init())
            }
            _ = await notice.executeSingleToolUse(tu: .init(name: "answer_user"), msgIdx: 0, tools: [], batchBudget: .init())
            precondition(notice.executed.isEmpty && notice.refused.count == deniedCalls.count + 1)
            precondition(notice.hooks!.willRunCount == 0 && notice.hooks!.didRunCount == 0,
                         "Notice refusals precede hooks and native side effects")
            _ = await notice.executeSingleToolUse(tu: .init(name: "answer_user"), msgIdx: 0, tools: noticeTools, batchBudget: .init())
            precondition(notice.executed == ["answer_user"])
            notice.isNoticeDriven = false
            precondition(Set(notice.makeAgentTools().map(\.name)) == expected)
        }

        for policy in [AgentToolPolicy.standalone, .orchestrator] {
            let ordinary = AIChatViewModel()
            ordinary.sessionSource = "chat"
            ordinary.chatMode = .full
            ordinary.resolvedToolPolicy = policy
            let liveTools = ordinary.makeAgentTools()
            let liveNames = Set(liveTools.map(\.name))
            let livePrompt = ordinary.promptForCheck()
            precondition(liveNames.isSuperset(of: ["yima_items", "app_navigation", "app_present", "list_agents"]))
            precondition(!liveNames.contains("answer_user") && !liveNames.contains("apple_native"))
            if policy == .standalone {
                precondition(liveNames.isSuperset(of: ["shell_execute", "browser_use", "file_read", "file_write", "file_edit"]))
            } else {
                precondition(liveNames.isSuperset(of: SubagentTools.names))
            }
            ordinary.isNoticeDriven = true
            let noticeTools = ordinary.makeAgentTools()
            precondition(liveTools.map(\.name) == noticeTools.map(\.name) && ordinary.promptForCheck() == livePrompt,
                         "Ordinary Yima notice tools, order and prompt remain unchanged")
            for tool in noticeTools {
                _ = await ordinary.executeSingleToolUse(tu: .init(name: tool.name), msgIdx: 0, tools: noticeTools, batchBudget: .init())
            }
            precondition(ordinary.refused.isEmpty && ordinary.executed.count == noticeTools.count)
            for name in ["answer_user", "apple_native"] {
                _ = await ordinary.executeSingleToolUse(tu: .init(name: name), msgIdx: 0,
                                                       tools: noticeTools + [hostDefinition(name)], batchBudget: .init())
            }
            precondition(ordinary.refused.count == 2, "Managed host capabilities cannot be forged into an ordinary session")
        }
        let lite = AIChatViewModel()
        lite.sessionSource = "chat"
        precondition(lite.makeAgentTools().map(\.name) == ["shell_execute"] && lite.promptForCheck() == "Lite prompt")
        let child = AIChatViewModel()
        child.sessionSource = "fixture_interaction"
        child.agentRole = .executor
        child.resolvedToolPolicy = .orchestrator
        precondition(child.effectiveToolPolicy == .standalone && !child.liteModeActive)
        let childTools = child.makeAgentTools()
        precondition(Set(childTools.map(\.name)).isSuperset(of: ["shell_execute", "browser_use", "file_read", "file_write", "file_edit"]))
        precondition(Set(childTools.map(\.name)).isDisjoint(with: AgentRuntimePolicies.managedToolNames))
        for name in AgentRuntimePolicies.managedToolNames {
            _ = await child.executeSingleToolUse(tu: .init(name: name), msgIdx: 0,
                                                tools: childTools + [hostDefinition(name)], batchBudget: .init())
        }
        precondition(child.executed.isEmpty && child.hooks!.willRunCount == 0)
        precondition(child.promptForCheck().contains("background subagent") && child.promptForCheck().contains("Standalone operator"))
        let ordinaryMemory = AIChatViewModel()
        ordinaryMemory.sessionSource = "chat"
        ordinaryMemory.chatMode = .full
        let enabledFooter = "\n\nMemory status: ENABLED for this session. GLOBAL.md and recent daily logs have been injected above (if non-empty), and memory_get / memory_write are available in the tool list."
        precondition(ordinaryMemory.memoryStatusFragment(tools: ordinaryMemory.makeAgentTools()) == enabledFooter,
                     "Ordinary enabled-memory footer remains byte-identical")
        let readOnlyFooter = "\n\nMemory status: READ-ONLY for this task. GLOBAL.md and recent daily logs have been injected above (if non-empty) and memory_get is available, but memory_write is NOT registered — do not attempt to call it. Anything worth remembering goes in your final answer; the assistant that dispatched you decides what to save."
        precondition(child.memoryStatusFragment(tools: child.makeAgentTools()) == readOnlyFooter,
                     "Ordinary executor memory footer remains byte-identical")
        ordinaryMemory.memoryEnabled = false
        let disabledFooter = "\n\nMemory status: DISABLED for this session. "
            + "The user has turned off memory for this conversation. "
            + "Despite any earlier mentions in this prompt:\n"
            + "- GLOBAL.md and daily logs have NOT been injected — you do not have access to past memories.\n"
            + "- The memory_get and memory_write tools are NOT registered — do not attempt to call them; they will not appear in your tool list.\n"
            + "- If the user asks you to recall memories, save a memory, or wonders why earlier memories aren't visible, tell them memory is currently disabled for this session and they can re-enable it via the /memory slash command or in Settings.\n"
            + "- This toggle is per-session. Other sessions may still have memory enabled.\n"
            + "- SOUL.md (your persona / identity) is unaffected and remains active above."
        precondition(ordinaryMemory.memoryStatusFragment(tools: ordinaryMemory.makeAgentTools()) == disabledFooter,
                     "Ordinary disabled-memory footer remains byte-identical")
        ordinaryMemory.memoryEnabled = true
        let repairFooter = ordinaryMemory.memoryStatusFragment(tools: [MeetingAnswerUserTool.definition])
        precondition(repairFooter.contains("unavailable") && !repairFooter.contains("memory_get") && !repairFooter.contains("memory_write"),
                     "A delivery-only repair or hook-narrowed round uses actual tools rather than the full session registry")
        let readOnlyRound = ordinaryMemory.memoryStatusFragment(tools: [hostDefinition("memory_get")])
        precondition(readOnlyRound.contains("memory_get") && !readOnlyRound.contains("memory_write"),
                     "Partial memory access advertises only the actual available operation")
        AgentRuntimePolicies.register(source: "read_only_fixture", policy: .init(allowedTools: ["memory_get"], allowsLiteMode: false))
        ordinaryMemory.sessionSource = "read_only_fixture"
        let filteredFooter = ordinaryMemory.memoryStatusFragment(tools: [hostDefinition("memory_get"), hostDefinition("memory_write")])
        precondition(filteredFooter.contains("memory_get") && !filteredFooter.contains("memory_write"),
                     "A visibility hook cannot advertise a memory operation forbidden by configuration")
        print("PASS: two voice presets and an arbitrary third source share configured tool ceilings, generic prompts, all existing subagent tools and notice-only delivery")
        print("PASS: real dispatch rejects forged policy/host capabilities before hooks; executor and ordinary Yima/lite tools and prompts retain their boundaries")
        print("PASS: assembled notice/repair memory footers match actual round tools; ordinary enabled/disabled/executor footers remain byte-identical")
    }
}
