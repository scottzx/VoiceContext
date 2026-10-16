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
enum MeetingAnswerUserTool { static var definition: AgentToolDefinition { hostDefinition("answer_user") } }
enum MeetingAppleTool { static var definition: AgentToolDefinition { hostDefinition("apple_native") } }
enum YimaItemsAgentTool { static var definition: AgentToolDefinition { hostDefinition("yima_items") } }
enum ChatHistorySearchTool { static var definition: AgentToolDefinition { hostDefinition("chat_history_search") } }
enum AgentDirectoryTools {
    static var definitions: [AgentToolDefinition] { [hostDefinition("create_agent"), hostDefinition("list_agents"), hostDefinition("send_agent_message")] }
    static func promptSection(canDispatch: Bool) -> String { "Agent directory: list_agents / send_agent_message / create_agent" }
}
enum SystemPromptBuilder { static func identitySection(for id: String?) -> String { "You are Yima.\n\n" } }
enum LiteModePrompt {
    static var toolDefinitions: [AgentToolDefinition] { [hostDefinition("shell_execute")] }
    static func render(agentId: String?, timeString: String) -> String { "Lite prompt" }
}

enum StreamResult {
    struct ToolEntry { let id = UUID().uuidString; let name: String; let args: [String: Any] = [:]; let blockIdx = 0 }
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
        let vm = AIChatViewModel()
        func names() -> Set<String> { Set(vm.makeAgentTools().map(\.name)) }
        let native: Set<String> = ["answer_user", "apple_native", "yima_items", "memory_get", "memory_write"]
        let expected = SubagentTools.names.union(native)
        precondition(vm.effectiveToolPolicy == .orchestrator, "Meeting policy survives a standalone default after reload")
        precondition(!vm.liteModeActive, "A global lite preference cannot bypass the meeting tool filter")
        precondition(names() == expected)
        let meetingPrompt = vm.promptForCheck()
        for forbidden in ["shell_execute", "browser_use", "file_read", "file_write", "file_edit", "read_image", "list_agents", "send_agent_message", "create_agent", "search_chat_history"] {
            precondition(!meetingPrompt.contains(forbidden), "Meeting prompt must not describe unavailable tool \(forbidden)")
        }
        for allowed in expected { precondition(meetingPrompt.contains(allowed)) }
        precondition(meetingPrompt.contains("ONLY way to deliver user-visible or spoken text"))
        precondition(meetingPrompt.contains("A task-start receipt means only that work began"))
        precondition(meetingPrompt.contains("Use native tools only"))
        precondition(meetingPrompt.contains("async_task_notice") && meetingPrompt.contains("Children report"))
        let mainTools = vm.makeAgentTools()
        for forbidden in ["shell_execute", "browser_use", "file_read", "file_write", "file_edit", "read_image", "chat_history_search", "create_agent", "mcp_unknown"] {
            _ = await vm.executeSingleToolUse(tu: .init(name: forbidden), msgIdx: 0, tools: mainTools, batchBudget: .init())
        }
        precondition(vm.executed.isEmpty && vm.refused.count == 9)
        precondition(vm.hooks!.willRunCount == 0 && vm.hooks!.didRunCount == 0,
                     "A forged forbidden call is refused before hooks or execution can run")
        // Even a forged registration cannot widen the coordinator's ceiling.
        _ = await vm.executeSingleToolUse(tu: .init(name: "shell_execute"), msgIdx: 0,
                                         tools: mainTools + [hostDefinition("shell_execute")], batchBudget: .init())
        precondition(vm.executed.isEmpty)
        for allowed in expected {
            _ = await vm.executeSingleToolUse(tu: .init(name: allowed), msgIdx: 0, tools: mainTools, batchBudget: .init())
        }
        precondition(Set(vm.executed) == expected && vm.hooks!.willRunCount == expected.count)
        vm.memoryEnabled = false
        precondition(!vm.promptForCheck().contains("memory_get") && !vm.promptForCheck().contains("memory_write"),
                     "Meeting prompt lists memory tools only while they are registered")
        precondition(!names().contains("memory_get") && !names().contains("memory_write"))
        precondition(vm.meetingToolRefusal(name: "memory_write", tools: vm.makeAgentTools()) != nil,
                     "Unavailable conditional tools cannot be called through a forged name")

        vm.agentRole = .executor
        vm.sessionSource = "subagent"
        vm.resolvedToolPolicy = .orchestrator
        let child = names()
        precondition(vm.effectiveToolPolicy == .standalone)
        precondition(child.isSuperset(of: ["shell_execute", "browser_use", "file_read", "file_write", "file_edit"]))
        precondition(!child.contains("answer_user") && !child.contains("apple_native") && !child.contains("spawn_subagent"))
        precondition(vm.meetingToolRefusal(name: "answer_user", tools: mainTools) != nil)
        precondition(vm.meetingToolRefusal(name: "apple_native", tools: mainTools) != nil)
        precondition(vm.meetingToolRefusal(name: "shell_execute", tools: vm.makeAgentTools()) == nil)

        vm.agentRole = .main
        vm.sessionSource = "chat"
        vm.chatMode = .full
        vm.resolvedToolPolicy = .standalone
        precondition(vm.effectiveToolPolicy == .standalone && names().contains("shell_execute") && names().contains("browser_use"))
        precondition(!names().contains("answer_user") && !names().contains("apple_native"))
        precondition(vm.meetingToolRefusal(name: "shell_execute", tools: vm.makeAgentTools()) == nil)
        vm.resolvedToolPolicy = .orchestrator
        precondition(names().contains("file_read") && names().contains("list_agents"), "Ordinary orchestrator tools remain unchanged")
        let ordinaryPrompt = vm.promptForCheck()
        precondition(ordinaryPrompt.contains("file_read") && ordinaryPrompt.contains("read_image") && ordinaryPrompt.contains("list_agents"))
        precondition(ordinaryPrompt.contains("shell_execute") && ordinaryPrompt.contains("send_agent_message"))
        precondition(!ordinaryPrompt.contains("apple_native") && !ordinaryPrompt.contains("answer_user"))
        precondition(OrchestratorPrompt.render(agentId: nil, memoryEnabled: true) ==
                     OrchestratorPrompt.render(agentId: nil, memoryEnabled: true, meetingVoiceMode: false),
                     "The new render parameter defaults to unchanged ordinary orchestration")
        print("PASS: actual tool registration and dispatch enforce a native/dispatch meeting ceiling; children execute and ordinary chats retain their policies")
        print("PASS: actual base prompt matches the meeting allowlist, dedicated voice delivery and async results; ordinary prompts and lite policy stay intact")
    }
}
