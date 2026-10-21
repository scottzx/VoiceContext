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
    var blockedTools: Set<String> = []
    var noticeAllowedTools: Set<String>?
    var additionalTools: [AgentToolDefinition] = []
    var replyDelivery: AgentReplyDeliveryPolicy?
    var requiresShellRuntime = true
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
        let permitted = tools.filter { !blockedTools.contains($0.name) }
        guard let allowed = allowedToolNames(noticeDriven: noticeDriven) else { return permitted }
        return permitted.filter { allowed.contains($0.name) }
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
    /// Hosts with native-only professional sessions can keep optional shell lazy.
    static var bootsShellForUnconfiguredSessions = true
    /// Native host callbacks are dispatched only after the existing policy,
    /// hooks and preflight gates in AIChatViewModel. Registration does not
    /// grant a role or interaction permission to call the tool.
    static var hostToolHandlers: [String: AgentHostToolHandler] = [:]

    static func executeHostTool(name: String, context: AgentHostToolContext) async throws -> AgentHostToolResult? {
        guard let handler = hostToolHandlers[name] else { return nil }
        try Task.checkCancellation()
        let result = try await handler(context)
        try Task.checkCancellation()
        return result
    }
    static var hiddenAgentIDs: Set<String> = []

    static func register(source: String, policy: AgentRuntimePolicy) {
        sources[source] = policy
    }

    static func requiresShellRuntime(for source: String?) -> Bool {
        guard let source, let policy = sources[source] else { return bootsShellForUnconfiguredSessions }
        return policy.requiresShellRuntime
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


/// JSON stays provider-neutral and preserves the caller's tool-use identity.
/// Business schemas are validated by the injected host, not this registry.
struct AgentHostToolContext: Sendable {
    let toolCallId: String
    let sessionId: String?
    let source: String?
    let argumentsJSON: String
}

struct AgentHostToolResult: Sendable {
    let content: String
    let succeeded: Bool
}

typealias AgentHostToolHandler = @MainActor (AgentHostToolContext) async throws -> AgentHostToolResult
