import Foundation

// Compile real protocol extensions, request builders, model guards, thinking
// shapes and SDK ToolChoice encoding against host-only capture transports.
struct LLMUsage {}
enum LLMError: Error { case providerError(message: String) }
func AppLocalized(_ text: String) -> String { text }
struct LLMModel {
    let id: String
    var displayName = ""
    var provider = "fixture"
    var supportsReasoning: Bool? = true
    var interleavedReasoningField: String? = nil
    var catalogMaxThinkingLevel: ThinkingLevel = .high
}
struct AppLogger {
    static var lines: [String] = []
    func info(_ value: String) { Self.lines.append(value) }
}
let logger = AppLogger()
let thinkingLogger = AppLogger()

final class OpenAIProvider {
    static let fastModeDefaultsKey = "meeting-required-wire-unused"
    var model: LLMModel
    var name: String { "fixture-openai" }
    var usesChatCompletionsAPI = true
    var isDashScope = false
    var useOpenRouterCompat = false
    var needsOpenRouterAnthropicCacheControl = false
    var usesUnifiedReasoningEffort = false
    var isMistral = false
    var isXAI = false
    var providerInstanceId: String? = nil
    var forceResponsesAPI = false
    var isOAuth = false
    var customBaseURL: String? = "https://api.minimax.io/v1"
    var chatExtraBody: [String: Any] = ["tool_choice": "auto", "parallel_tool_calls": true]
    var sentBodies: [[String: Any]] = []
    var responsesFlags: [Bool] = []
    var attempts = 0
    var failure: Error?
    init(_ id: String) { model = LLMModel(id: id) }
}
extension OpenAIAgentProvider {
    func flattenChatCompletionsMessages(_ messages: [AgentMessage], thinkingLevel: ThinkingLevel) -> [[String: Any]] {
        [["role": "user", "content": privateText]]
    }
    func convertMessagesResponsesAPI(_ messages: [AgentMessage]) -> [[String: Any]] {
        [["role": "user", "content": privateText]]
    }
    static func injectDashScopeCacheControl(messages: inout [[String: Any]], tools: inout [[String: Any]]) {}
    static func shouldSendPromptCacheKey(for provider: OpenAIProvider) -> Bool { false }
    static func derivePromptCacheKey(from messages: [AgentMessage]) -> String { "fixture" }
    static func explicitOffEffort(for provider: OpenAIProvider, model: LLMModel, level: ThinkingLevel) -> String? { nil }
    static func reasoningEffort(for model: LLMModel, level: ThinkingLevel) -> String? { level.isEnabled ? "high" : nil }
    static func injectThinkingParams(into body: inout [String: Any], model: LLMModel, level: ThinkingLevel,
                                     isOpenRouter: Bool, maxTokens: Int, offEffort: String?,
                                     unifiedReasoningEffort: Bool, isMistral: Bool, isXAI: Bool,
                                     isDashScope: Bool, providerInstanceId: String?) {
        // Thinking emission has its own golden regressions. The capture records
        // which level actually reaches this production builder after clamping.
        body["fixture_thinking_level"] = level.rawValue
    }
}

struct MessageParameter {
    enum Model { case other(String) }
    let model: Model
    let messages: [[String: String]]
    let maxTokens: Int
    let system: String?
    let temperature: Double?
    let tools: [String]
    let toolChoice: ToolChoice
}
final class AnthropicProvider {
    var model: LLMModel
    var name: String { "fixture-anthropic" }
    var isOfficialAnthropicEndpoint = true
    var parameters: [MessageParameter] = []
    init(_ id: String) { model = LLMModel(id: id) }
    func resolveSystemPrompt(_ text: String?) -> String? { text }
    func effectiveTemperature(_ value: Double) -> Double? { value }
}
extension AnthropicAgentProvider {
    func convertMessages(_ messages: [AgentMessage]) -> [[String: String]] { [["content": privateText]] }
    func convertTools(_ tools: [AgentToolDefinition]) -> [String] { tools.map(\.name) }
    func messagesWithCacheBreakpoints(_ messages: [[String: String]]) -> [[String: String]] { messages }
}
enum RequestBodyPatcher {
    static var budgets: [Int] = []
    static var efforts: [String] = []
    static var disabledModels: [String] = []
    static func setToolResultImages(_ images: [String: (data: Data, mimeType: String)]) {}
    static func setThinkingEffort(_ effort: String) { efforts.append(effort) }
    static func setThinkingBudget(_ budget: Int) { budgets.append(budget) }
    static func setThinkingDisabled(modelId: String) { disabledModels.append(modelId) }
    static func setReasoningHistory(_ history: [String?], injectPlaceholder: Bool) {}
    static func reset() { budgets = []; efforts = []; disabledModels = [] }
}

final class ProviderSpy: AgentProvider {
    let name = "spy"
    let model = LLMModel(id: "spy")
    let defaultMaxTokens = 100
    var requests: [(required: String?, thinking: ThinkingLevel)] = []
    func streamAgentMessageClamped(messages: [AgentMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                                   requiredToolName: String?, maxTokens: Int, thinkingLevel: ThinkingLevel) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        requests.append((requiredToolName, thinkingLevel))
        return AsyncThrowingStream { $0.finish() }
    }
}

let privateText = "private calendar result must never be logged"
let answerTool = AgentToolDefinition(name: "answer_user", description: "Public spoken reply",
                                    parameters: ["text": .init(type: .string, description: "Reply")], required: ["text"])
let messages = [AgentMessage(role: .user, parts: [.text(privateText)])]
func require(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}
func choice(_ body: [String: Any]) -> [String: Any] { body["tool_choice"] as? [String: Any] ?? [:] }
func sdkChoice(_ parameter: MessageParameter) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(parameter.toolChoice)) as! [String: Any]
}

@main
struct MeetingRequiredToolWireTests {
    static func main() async throws {
        let spy = ProviderSpy()
        _ = try await spy.streamAgentMessage(messages: messages, systemPrompt: nil, tools: [answerTool], maxTokens: 100, thinkingLevel: .ultra)
        _ = try await spy.streamAgentMessage(messages: messages, systemPrompt: nil, tools: [answerTool], requiredToolName: "answer_user", maxTokens: 100, thinkingLevel: .ultra)
        _ = try await spy.streamAgentMessage(messages: messages, systemPrompt: nil, tools: [answerTool], maxTokens: 100, thinkingLevel: .ultra)
        require(spy.requests.map(\.thinking) == [.high, .off, .high], "Required thinking override leaked into later ordinary request")
        require(spy.requests.map(\.required) == [nil, "answer_user", nil], "Protocol extension dropped or persisted required name")
        _ = try await spy.streamAgentMessage(messages: messages, systemPrompt: nil, tools: [answerTool], requiredToolName: "answer_user", maxTokens: 100)
        require(spy.requests.last?.required == "answer_user", "Default-thinking overload dropped required name")
        let count = spy.requests.count
        do {
            _ = try await spy.streamAgentMessage(messages: messages, systemPrompt: nil, tools: [], requiredToolName: "answer_user", maxTokens: 100)
            fatalError("Missing required tool reached transport")
        } catch LLMError.providerError {}
        require(spy.requests.count == count, "Missing tool should reject before provider dispatch")

        let chat = OpenAIProvider("MiniMax-M3")
        let chatAgent = OpenAIAgentProvider(provider: chat)
        _ = try await chatAgent.streamAgentMessage(messages: messages, systemPrompt: privateText, tools: [answerTool], maxTokens: 100, thinkingLevel: .high)
        _ = try await chatAgent.streamAgentMessage(messages: messages, systemPrompt: privateText, tools: [answerTool], requiredToolName: "answer_user", maxTokens: 100, thinkingLevel: .high)
        _ = try await chatAgent.streamAgentMessage(messages: messages, systemPrompt: privateText, tools: [answerTool], maxTokens: 100, thinkingLevel: .high)
        require(chat.responsesFlags == [false, false, false], "MiniMax must use actual Chat Completions route")
        require(chat.sentBodies[0]["tool_choice"] == nil && chat.sentBodies[2]["tool_choice"] == nil, "Ordinary Chat default-auto behavior changed")
        let forcedChat = chat.sentBodies[1]
        require(forcedChat["tool_choice"] as? String == "required", "Single-tool MiniMax Chat must use mandatory required choice")
        require(forcedChat["parallel_tool_calls"] == nil, "Chat added an unnecessary vendor compatibility field")
        require(forcedChat["fixture_thinking_level"] as? String == "off", "Forced Chat did not receive request-local thinking off")
        let schema = (((forcedChat["tools"] as! [[String: Any]])[0]["function"] as! [String: Any])["parameters"] as! [String: Any])
        require(schema["required"] as? [String] == ["text"], "Answer tool schema changed in provider conversion")
        require((schema["properties"] as! [String: Any]).keys.sorted() == ["text"], "Provider added answer_user parameters")
        let otherTool = AgentToolDefinition(name: "other_tool", description: "Other tool", parameters: [:], required: [])
        _ = try await chatAgent.streamAgentMessage(messages: messages, systemPrompt: nil, tools: [answerTool, otherTool], requiredToolName: "answer_user", maxTokens: 100)
        let multiple = chat.sentBodies.last!
        require(choice(multiple)["type"] as? String == "function", "Multiple-tool Chat must keep named selection")
        require((choice(multiple)["function"] as? [String: Any])?["name"] as? String == "answer_user", "Multiple-tool Chat selected an unspecified function")
        let attemptsBeforeFailure = chat.attempts
        let bodiesBeforeFailure = chat.sentBodies.count
        chat.failure = LLMError.providerError(message: "Unsupported forced choice")
        do {
            _ = try await chatAgent.streamAgentMessage(messages: messages, systemPrompt: nil, tools: [answerTool], requiredToolName: "answer_user", maxTokens: 100)
            fatalError("Forced request failure silently downgraded to auto")
        } catch LLMError.providerError {}
        require(chat.attempts == attemptsBeforeFailure + 1 && chat.sentBodies.count == bodiesBeforeFailure, "Provider retried unsupported force as auto")
        chat.failure = nil
        _ = try await chatAgent.streamAgentMessage(messages: messages, systemPrompt: nil, tools: [answerTool], maxTokens: 100)
        require(chat.sentBodies.last?["tool_choice"] == nil, "Rejected forced request contaminated later ordinary Chat")

        for codex in [false, true] {
            let response = OpenAIProvider("gpt-fixture")
            response.usesChatCompletionsAPI = false
            response.isOAuth = codex
            response.customBaseURL = codex ? nil : "https://example.invalid"
            response.forceResponsesAPI = !codex
            let agent = OpenAIAgentProvider(provider: response)
            for required: String? in [nil, "answer_user", nil] {
                _ = try await agent.streamAgentMessage(messages: messages, systemPrompt: privateText, tools: [answerTool], requiredToolName: required, maxTokens: 100)
            }
            require(response.responsesFlags == [true, true, true], "Responses route dropped")
            require(response.sentBodies[0]["tool_choice"] as? String == "auto" && response.sentBodies[2]["tool_choice"] as? String == "auto", "Responses force leaked across requests")
            require(choice(response.sentBodies[1])["type"] as? String == "function" && choice(response.sentBodies[1])["name"] as? String == "answer_user", "Responses/Codex required choice has wrong wire shape")
            require(response.sentBodies[1]["parallel_tool_calls"] as? Bool == false, "Forced Responses allows parallel calls")
            require(response.sentBodies[2]["parallel_tool_calls"] as? Bool == true, "Ordinary Responses parallel behavior changed")
            if codex { require(response.sentBodies[1]["max_output_tokens"] == nil, "Codex output limit behavior changed") }
        }

        for id in ["claude-3-7-sonnet", "claude-sonnet-4-6", "claude-opus-5", "claude-haiku-5-5"] {
            let provider = AnthropicProvider(id)
            let agent = AnthropicAgentProvider(provider: provider)
            RequestBodyPatcher.reset()
            _ = try await agent.streamAgentMessage(messages: messages, systemPrompt: privateText, tools: [answerTool], requiredToolName: "answer_user", maxTokens: 100, thinkingLevel: .high)
            let wire = try sdkChoice(provider.parameters[0])
            require(wire["type"] as? String == "tool" && wire["name"] as? String == "answer_user", "Anthropic SDK did not encode named choice")
            require(wire["disable_parallel_tool_use"] as? Bool == true && wire.count == 3, "Anthropic forced parallel flag/schema wrong")
            require(RequestBodyPatcher.budgets.isEmpty && RequestBodyPatcher.efforts.isEmpty, "Forced Anthropic enabled manual/adaptive thinking parameters")
            require(RequestBodyPatcher.disabledModels == (id == "claude-sonnet-4-6" ? [id] : []), "Existing model-specific thinking-off contract changed")
            _ = try await agent.streamAgentMessage(messages: messages, systemPrompt: privateText, tools: [answerTool], maxTokens: 100, thinkingLevel: .high)
            let auto = try sdkChoice(provider.parameters[1])
            require(auto["type"] as? String == "auto" && auto.count == 1, "Anthropic ordinary request inherited force")
            require(!RequestBodyPatcher.budgets.isEmpty || !RequestBodyPatcher.efforts.isEmpty, "Forced request changed saved thinking behavior")
        }
        for id in ["claude-opus-5-5", "anthropic/claude-sonnet-5.5", "claude-fable-5-1", "claude-mythos-5-1"] {
            let provider = AnthropicProvider(id)
            let agent = AnthropicAgentProvider(provider: provider)
            do {
                _ = try await agent.streamAgentMessage(messages: messages, systemPrompt: nil, tools: [answerTool], requiredToolName: "answer_user", maxTokens: 100)
                fatalError("Known unsupported Anthropic forced model did not fail")
            } catch LLMError.providerError {}
            require(provider.parameters.isEmpty, "Unsupported force reached Anthropic transport")
            _ = try await agent.streamAgentMessage(messages: messages, systemPrompt: nil, tools: [answerTool], maxTokens: 100)
            let auto = try sdkChoice(provider.parameters[0])
            require(auto["type"] as? String == "auto", "Unsupported-force guard changed ordinary model behavior")
        }
        require(!AppLogger.lines.contains(where: { $0.contains(privateText) }), "Request metadata log leaked user content")
        print("PASS meeting required tool wire: real MiniMax Chat/Responses/Codex bodies, Anthropic SDK choice, protocol forwarding and request isolation")
    }
}
