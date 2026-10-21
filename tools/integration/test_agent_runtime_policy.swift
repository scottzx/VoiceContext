import Foundation

enum AgentToolPolicy { case standalone, orchestrator }

@main struct RuntimePolicyChecks {
    @MainActor static func main() {
        func tool(_ name: String) -> AgentToolDefinition {
            .init(name: name, description: name, parameters: [:], required: [])
        }
        precondition(AgentRuntimePolicies.requiresShellRuntime(for: nil))
        AgentRuntimePolicies.bootsShellForUnconfiguredSessions = false
        precondition(!AgentRuntimePolicies.requiresShellRuntime(for: nil))
        var native = AgentRuntimePolicy()
        native.requiresShellRuntime = false
        native.blockedTools = ["shell_execute"]
        precondition(native.filter([.init(name: "shell_execute", description: "shell", parameters: [:], required: [])], noticeDriven: false).isEmpty)
        AgentRuntimePolicies.register(source: "native-only", policy: native)
        precondition(!AgentRuntimePolicies.requiresShellRuntime(for: "native-only"))
        AgentRuntimePolicies.bootsShellForUnconfiguredSessions = true
        let ordinary = AgentRuntimePolicies.policy(for: "unregistered")
        precondition(ordinary.toolPolicyOverride == nil && ordinary.allowedTools == nil)
        precondition(ordinary.allowsLiteMode && ordinary.allowsAutomaticSpeech && !ordinary.requiresIdle)
        let candidates = [tool("execute"), tool("preview"), tool("reply"), tool("private")]
        precondition(ordinary.filter(candidates, noticeDriven: false).count == candidates.count)
        precondition(ordinary.filter(candidates, noticeDriven: true).count == candidates.count)
        var activeID: String? = "active-session"
        let delivery = AgentReplyDeliveryPolicy(definition: tool("reply"), canRequest: { $0 == activeID }, reminder: "Deliver once")
        let configured = AgentRuntimePolicy(
            toolPolicyOverride: .orchestrator,
            allowedTools: ["execute", "reply", "preview"], noticeAllowedTools: ["reply"],
            additionalTools: [tool("preview")], replyDelivery: delivery,
            allowsLiteMode: false, allowsAutomaticSpeech: false, headless: true,
            requiresIdle: true, requiresNoticeReplyBinding: true, requiresNavigationBinding: true,
            restoresSourceOnLoad: true,
            prompt: { identity, _, notice in "\(identity ?? "anonymous"):\(notice ? "notice" : "request")" }
        )
        // A new identity/interaction requires only registration, no engine branch.
        AgentRuntimePolicies.register(source: "third-party-entry", policy: configured)
        let third = AgentRuntimePolicies.policy(for: "third-party-entry")
        precondition(third.toolPolicyOverride == .orchestrator && third.headless && third.requiresIdle)
        precondition(!third.allowsAutomaticSpeech && !third.allowsLiteMode && third.restoresSourceOnLoad)
        precondition(third.requiresNoticeReplyBinding && third.requiresNavigationBinding)
        precondition(third.filter(candidates, noticeDriven: false).map(\.name) == ["execute", "preview", "reply"])
        precondition(third.filter(candidates, noticeDriven: true).map(\.name) == ["reply"])
        precondition(third.prompt?("third-agent", false, false) == "third-agent:request")
        precondition(third.prompt?("third-agent", false, true) == "third-agent:notice")
        precondition(third.replyDelivery!.canRequest("active-session"))
        activeID = nil
        precondition(!third.replyDelivery!.canRequest("active-session"))
        AgentRuntimePolicies.hostTools = [tool("shared-host")]
        precondition(AgentRuntimePolicies.managedToolNames.isSuperset(of: ["reply", "preview", "shared-host"]))
        precondition(!AgentRuntimePolicies.managedToolNames.contains("execute"), "Allowlisting is not a tool registration")
        AgentRuntimePolicies.hiddenAgentIDs.insert("third-agent")
        precondition(AgentRuntimePolicies.hiddenAgentIDs.contains("third-agent"))
        precondition(AgentRuntimePolicies.policy(for: "unregistered").allowedTools == nil)
        print("PASS: arbitrary source/identity configuration selects prompts, capabilities, delivery, notice-only tools and lifecycle policies without changing the engine; ordinary defaults stay unchanged")
    }
}
