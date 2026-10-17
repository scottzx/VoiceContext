import Foundation

enum AgentToolPolicy { case standalone, orchestrator }

func AppLocalized(_ value: String) -> String { value }
struct HostLogger { func info(_ text: String) {} }
let logger = HostLogger()
final class ChatMessage {
    enum Role { case assistant }
    var error: String?
    init(role: Role, content: String, blocks: [String]) {}
}
@MainActor final class AIChatViewModel {
    enum ContextCheck { case ok, needsCompact, exhausted }
    var sessionSource: String?
    var context = ContextCheck.ok
    var autoCompactEnabled = false
    var skipCompactCheck = false
    var pendingSendText: String?
    var pendingSendAttachments: [String] = []
    var inputText = "原草稿"
    var attachments = ["原附件"]
    var messages: [ChatMessage] = []
    var showCompactBeforeSendPrompt = false
    var showContextExhaustedPrompt = false
    var compactionCalls = 0
    var contextChecks = 0
    var continuedSend = false
    func checkContextBeforeSend() -> ContextCheck { contextChecks += 1; return context }
    func compactAndSend() { compactionCalls += 1 }
}

@main struct AgentRelayContextChecks {
    @MainActor static func main() {
        for source in ["meeting_assistant", "xiaolan_voice", "arbitrary_adapter"] {
            AgentRuntimePolicies.register(source: source, policy: .init(headless: true))
        }
        for source in ["agent-relay", "shortcut", "hardware", "group", "subagent", "meeting_assistant", "xiaolan_voice", "arbitrary_adapter"] {
            let vm = AIChatViewModel()
            vm.sessionSource = source
            precondition(vm.isHeadlessSession)
            vm.context = .needsCompact
            vm.sendContextForCheck(text: "完整委派内容", pendingAttachments: ["真实附件"])
            precondition(vm.compactionCalls == 1 && vm.pendingSendText == "完整委派内容" && vm.pendingSendAttachments == ["真实附件"])
            precondition(vm.inputText.isEmpty && vm.attachments.isEmpty && !vm.showCompactBeforeSendPrompt && !vm.showContextExhaustedPrompt && !vm.continuedSend,
                         "Background relay must use the existing compact-and-send path without a UI prompt or dropping its payload")

            let full = AIChatViewModel()
            full.sessionSource = source; full.context = .exhausted
            full.sendContextForCheck(text: "不能安全执行的任务", pendingAttachments: ["附件"])
            precondition(full.messages.count == 1 && full.messages[0].error == "Context full. Start a new session to continue.")
            precondition(full.compactionCalls == 0 && !full.showCompactBeforeSendPrompt && !full.showContextExhaustedPrompt && !full.continuedSend,
                         "A truly exhausted background session returns an inline error instead of requiring invisible user interaction")
        }

        for source: String? in [nil, "chat", "agent"] {
            let vm = AIChatViewModel()
            vm.sessionSource = source; vm.context = .needsCompact
            precondition(!vm.isHeadlessSession)
            vm.sendContextForCheck(text: "用户输入", pendingAttachments: ["附件"])
            precondition(vm.compactionCalls == 0 && vm.showCompactBeforeSendPrompt && !vm.continuedSend)
            precondition(vm.pendingSendText == "用户输入" && vm.pendingSendAttachments == ["附件"])
            let full = AIChatViewModel()
            full.sessionSource = source; full.context = .exhausted
            full.sendContextForCheck(text: "用户输入", pendingAttachments: [])
            precondition(full.showContextExhaustedPrompt && full.messages.isEmpty && full.compactionCalls == 0,
                         "Opening Yima's normal agent chat keeps the existing manual exhaustion choice")
        }

        let optedIn = AIChatViewModel()
        optedIn.sessionSource = "chat"; optedIn.context = .needsCompact; optedIn.autoCompactEnabled = true
        optedIn.sendContextForCheck(text: "用户输入", pendingAttachments: [])
        precondition(optedIn.compactionCalls == 1 && !optedIn.showCompactBeforeSendPrompt)
        let ready = AIChatViewModel()
        ready.sessionSource = "agent-relay"
        ready.sendContextForCheck(text: "正常任务", pendingAttachments: [])
        precondition(ready.continuedSend && ready.contextChecks == 1 && ready.compactionCalls == 0)
        let skipped = AIChatViewModel()
        skipped.sessionSource = "agent-relay"; skipped.context = .needsCompact; skipped.skipCompactCheck = true
        skipped.sendContextForCheck(text: "压缩后继续", pendingAttachments: [])
        precondition(skipped.continuedSend && !skipped.skipCompactCheck && skipped.contextChecks == 0 && skipped.compactionCalls == 0)
        print("PASS: actual agent-relay headless/context branch auto-compacts with intact payload, reports exhaustion inline and preserves ordinary chat prompts/opt-in/skip behavior")
    }
}
