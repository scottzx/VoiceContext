import Foundation

/// Host-provided behavior. Agent identities and interaction sources select
/// configuration outside the execution engine; sessions still own their state.
@MainActor
struct AgentReplyDeliveryPolicy {
    let definition: AgentToolDefinition
    let canRequest: @MainActor (String?) -> Bool
    let reminder: String
    var didDeliver: @MainActor (String?) -> Bool = { _ in false }
}

@MainActor
struct AgentRuntimePolicy {
    var toolPolicyOverride: AgentToolPolicy?
    var allowedTools: Set<String>?
    var noticeAllowedTools: Set<String>?
    var additionalTools: [AgentToolDefinition] = []
    var replyDelivery: AgentReplyDeliveryPolicy?
    var allowsLiteMode = true
    var allowsAutomaticSpeech = true
    var headless = false
    var requiresIdle = false
    var requiresNoticeReplyBinding = false
    var requiresNavigationBinding = false
    var restoresSourceOnLoad = false
    var allowsItemPresentation = true
    var executionGeneration: (@MainActor (String) -> UInt64?)?
    var prompt: (@MainActor (String?, Bool, Bool) -> String)?

    func allowedToolNames(noticeDriven: Bool) -> Set<String>? {
        noticeDriven ? (noticeAllowedTools ?? allowedTools) : allowedTools
    }

    func filter(_ tools: [AgentToolDefinition], noticeDriven: Bool) -> [AgentToolDefinition] {
        guard let allowed = allowedToolNames(noticeDriven: noticeDriven) else { return tools }
        return tools.filter { allowed.contains($0.name) }
    }
}

/// Registered during host startup, before session restoration or notice drain.
/// New interaction adapters register a policy rather than adding engine branches.
@MainActor
enum AgentRuntimePolicies {
    private static var sources: [String: AgentRuntimePolicy] = [
        "shortcut": .init(headless: true),
        "hardware": .init(allowsLiteMode: false, headless: true),
        "group": .init(headless: true),
        "agent-relay": .init(headless: true),
        "subagent": .init(allowsLiteMode: false, allowsAutomaticSpeech: false,
                          headless: true, restoresSourceOnLoad: true)
    ]
    static var hostTools: [AgentToolDefinition] = []
    static var hiddenAgentIDs: Set<String> = []

    static func register(source: String, policy: AgentRuntimePolicy) {
        sources[source] = policy
    }

    static func policy(for source: String?) -> AgentRuntimePolicy {
        source.flatMap { sources[$0] } ?? .init()
    }

    static var managedToolNames: Set<String> {
        var names = Set(hostTools.map(\.name))
        for policy in sources.values {
            names.formUnion(policy.additionalTools.map(\.name))
            if let reply = policy.replyDelivery { names.insert(reply.definition.name) }
        }
        return names
    }
}
