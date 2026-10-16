// Host fixture: .sh inserts actual production methods at the ACTUAL markers.
import Foundation

struct LLMModel {
    let id: String
    var catalogMaxThinkingLevel: ThinkingLevel { .high }
}
enum ThinkingLevel: Int, Comparable {
    case off, high
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    var isEnabled: Bool { self != .off }
}
struct LLMUsage {}
enum LLMError: Error {
    case providerError(message: String), invalidAPIKey(detail: String), rateLimited
    case transientError(message: String), networkError(underlying: Error), cancelled
}
enum GeminiStreamEvent {
    case textDelta(String), thinkingDelta(String), finishReason(String), usage(LLMUsage), done
    case functionCall(name: String, args: [String: Any], thoughtSignature: String?)
}
struct TestLogger { func error(_ message: String) {} }
private let logger = TestLogger()
enum MinisUserAgent { static let `default` = "MeetingHostTest" }
enum URLBuilding { static func join(_ parts: String...) -> String { parts.joined(separator: "/") } }

// Replaces network transport, so no API credentials or network requests are used.
actor WireCapture {
    static let shared = WireCapture()
    var requests: [URLRequest] = []
    var status = 200
    func reset(status: Int = 200) { requests = []; self.status = status }
    func capture(_ request: URLRequest) -> Int { requests.append(request); return status }
    func snapshot() -> [URLRequest] { requests }
}
final class URLSession {
    static let shared = URLSession()
    struct AsyncBytes { let lines: AsyncThrowingStream<String, Error> }
    func bytes(for request: URLRequest) async throws -> (AsyncBytes, URLResponse) {
        let status = await WireCapture.shared.capture(request)
        let lines = AsyncThrowingStream<String, Error> { continuation in
            if status >= 400 { continuation.yield("required tool rejected") }
            continuation.finish()
        }
        return (AsyncBytes(lines: lines), HTTPURLResponse(url: request.url!, statusCode: status,
                                                        httpVersion: nil, headerFields: nil)!)
    }
}
private let geminiStreamingSession = URLSession.shared

final class GeminiProvider {
    enum AuthMode { case apiKey(String), oauth(() async throws -> String) }
    let name = "Google"
    var model = LLMModel(id: "gemini-test")
    var authMode: AuthMode = .apiKey("fixture")
    var gcpProjectID: String?
    let sessionId = "test-session"
    let basePath = "https://gemini.invalid/v1beta"
    let cloudCodeBase = "https://cloudcode.invalid/v1internal"
    var extraGenerationConfig: [String: Any]?
    var useCloudCode: Bool { if case .oauth = authMode, gcpProjectID != nil { return true }; return false }
    func minimalThinkingConfig() -> [String: Any] { ["thinkingBudget": 0] }
    func elevatedThinkingConfig(level: ThinkingLevel) -> [String: Any] { ["thinkingBudget": 100] }
    func parseStreamChunk(_ json: [String: Any]) -> [GeminiStreamEvent] { [] }
    func applyGeminiCLIHeaders(_ request: inout URLRequest) { request.setValue("fixture", forHTTPHeaderField: "User-Agent") }
    func generatePromptId() -> String { "test-prompt" }
// ACTUAL_GEMINI_PROVIDER_METHODS
}
final class AntigravityProvider {
    let name = "Antigravity"
    var model = LLMModel(id: "gemini-test")
    let authTokenProvider: () async throws -> String = { "fixture" }
    var projectID: String? = "test-project"
    let sessionId = "test-session"
    let activeBaseURL = "https://antigravity.invalid"
    func minimalThinkingConfig() -> [String: Any] { ["thinkingBudget": 0] }
    func elevatedThinkingConfig(level: ThinkingLevel) -> [String: Any] { ["thinkingBudget": 100] }
    func parseStreamChunk(_ json: [String: Any]) -> [GeminiStreamEvent] { [] }
// ACTUAL_ANTIGRAVITY_PROVIDER_METHODS
}
final class GeminiAgentProvider: AgentProvider {
    let provider: GeminiProvider
    var name: String { provider.name }
    var model: LLMModel { provider.model }
    var defaultMaxTokens: Int { 16384 }
    init(provider: GeminiProvider) { self.provider = provider }
    func convertMessages(_ messages: [AgentMessage]) -> [[String: Any]] { [["role": "user", "parts": [["text": "test"]]]] }
    func convertTools(_ tools: [AgentToolDefinition]) -> [[String: Any]] { tools.map { ["name": $0.name] } }
// ACTUAL_GEMINI_AGENT_METHOD
}
final class AntigravityAgentProvider: AgentProvider {
    let provider: AntigravityProvider
    var name: String { provider.name }
    var model: LLMModel { provider.model }
    var defaultMaxTokens: Int { 16384 }
    init(provider: AntigravityProvider) { self.provider = provider }
    func convertMessages(_ messages: [AgentMessage]) -> [[String: Any]] { [["role": "user", "parts": [["text": "test"]]]] }
    func convertTools(_ tools: [AgentToolDefinition]) -> [[String: Any]] { tools.map { ["name": $0.name] } }
// ACTUAL_ANTIGRAVITY_AGENT_METHOD
}

private func require(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message)
}
private func body(_ request: URLRequest) throws -> [String: Any] {
    let serialized = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    return serialized["request"] as? [String: Any] ?? serialized
}
private func check(_ request: URLRequest, mode: String?, thinkingBudget: Int? = nil) throws {
    let inner = try body(request)
    let config = (inner["toolConfig"] as? [String: Any])?["functionCallingConfig"] as? [String: Any]
    require(config?["mode"] as? String == mode, "incorrect final HTTP function mode")
    if mode == "ANY" {
        require(config?["allowedFunctionNames"] as? [String] == ["answer_user"], "must force only answer_user")
        let declarations = (inner["tools"] as? [[String: Any]])?.first?["functionDeclarations"] as? [[String: Any]]
        require(declarations?.contains(where: { $0["name"] as? String == "answer_user" }) == true,
                "required tool declaration missing")
    } else {
        require(config?["allowedFunctionNames"] == nil, "required tool leaked into a normal request")
    }
    if let thinkingBudget {
        let generation = inner["generationConfig"] as? [String: Any]
        let thinking = generation?["thinkingConfig"] as? [String: Any]
        require(thinking?["thinkingBudget"] as? Int == thinkingBudget, "request-local thinking override lost or leaked")
    }
}
private let tools = ["business_tool", "answer_user"].map {
    AgentToolDefinition(name: $0, description: $0, parameters: [:], required: [])
}
private func consume<T>(_ stream: AsyncThrowingStream<T, Error>) async throws {
    for try await _ in stream {}
}
private func exercise(_ agent: any AgentProvider, label: String) async throws {
    await WireCapture.shared.reset()
    try await consume(agent.streamAgentMessage(messages: [], systemPrompt: "meeting", tools: tools,
                                               maxTokens: 512, thinkingLevel: .high))
    try await consume(agent.streamAgentMessage(messages: [], systemPrompt: "meeting", tools: tools,
                                               requiredToolName: "answer_user", maxTokens: 512, thinkingLevel: .high))
    try await consume(agent.streamAgentMessage(messages: [], systemPrompt: "meeting", tools: tools,
                                               maxTokens: 512, thinkingLevel: .high))
    try await consume(agent.streamAgentMessage(messages: [], systemPrompt: nil, tools: [], maxTokens: 512))
    let requests = await WireCapture.shared.snapshot()
    require(requests.count == 4, "unexpected extra request")
    try check(requests[0], mode: "AUTO", thinkingBudget: 100)
    try check(requests[1], mode: "ANY", thinkingBudget: 0)
    try check(requests[2], mode: "AUTO", thinkingBudget: 100)
    try check(requests[3], mode: nil)

    // Missing tool must fail before transport rather than silently becoming AUTO.
    do {
        _ = try await agent.streamAgentMessage(messages: [], systemPrompt: nil, tools: [],
                                               requiredToolName: "answer_user", maxTokens: 512)
        preconditionFailure("missing required tool was accepted")
    } catch LLMError.providerError {} catch { preconditionFailure("unexpected error: \(error)") }
    let afterMissing = await WireCapture.shared.snapshot()
    require(afterMissing.count == 4, "missing tool reached transport")

    // A real production HTTP check handles rejection; no AUTO fallback or replay.
    await WireCapture.shared.reset(status: 400)
    do {
        _ = try await agent.streamAgentMessage(messages: [], systemPrompt: nil, tools: tools,
                                               requiredToolName: "answer_user", maxTokens: 512)
        preconditionFailure("HTTP rejection was swallowed")
    } catch LLMError.providerError {} catch { preconditionFailure("unexpected error: \(error)") }
    let rejected = await WireCapture.shared.snapshot()
    require(rejected.count == 1, "rejected required tool request was replayed")
    try check(rejected[0], mode: "ANY")
    print("PASS \(label): AUTO/ANY, final JSON, per-request thinking, no leakage, rejection without fallback")
}

@main struct MeetingRequiredGoogleTests {
    static func main() async throws {
        let gemini = GeminiProvider()
        // Generic extra config must never overwrite the forced stream toolConfig.
        gemini.extraGenerationConfig = ["toolConfig": ["functionCallingConfig": ["mode": "AUTO"]]]
        try await exercise(GeminiAgentProvider(provider: gemini), label: "Gemini direct API-key")
        gemini.authMode = .oauth { "fixture" }
        try await exercise(GeminiAgentProvider(provider: gemini), label: "Gemini manual OAuth")
        gemini.gcpProjectID = "test-project"
        try await exercise(GeminiAgentProvider(provider: gemini), label: "Gemini Cloud Code envelope")
        let antigravity = AntigravityProvider()
        try await exercise(AntigravityAgentProvider(provider: antigravity), label: "Antigravity Gemini envelope")
        antigravity.model = LLMModel(id: "claude-test")
        try await exercise(AntigravityAgentProvider(provider: antigravity), label: "Antigravity Claude envelope")

        // The concrete defaults preserve existing direct streamWithTools callers.
        await WireCapture.shared.reset()
        try await consume(gemini.streamWithTools(contents: [], systemPrompt: nil, maxTokens: 512,
                                                 tools: [["name": "answer_user"]]))
        try await consume(antigravity.streamWithTools(contents: [], systemPrompt: nil, maxTokens: 512,
                                                      tools: [["name": "answer_user"]]))
        let requests = await WireCapture.shared.snapshot()
        require(requests.count == 2, "concrete defaults changed transport")
        for request in requests { try check(request, mode: "AUTO") }
        do {
            _ = try await gemini.streamWithTools(contents: [], systemPrompt: nil, maxTokens: 512,
                                                 tools: [], requiredToolName: "answer_user")
            preconditionFailure("Gemini accepted an undeclared required tool")
        } catch LLMError.providerError {} catch { preconditionFailure("unexpected error: \(error)") }
        do {
            _ = try await antigravity.streamWithTools(contents: [], systemPrompt: nil, maxTokens: 512,
                                                      tools: [["name": "business_tool"]], requiredToolName: "answer_user")
            preconditionFailure("Antigravity accepted an undeclared required tool")
        } catch LLMError.providerError {} catch { preconditionFailure("unexpected error: \(error)") }
        let afterInvalid = await WireCapture.shared.snapshot()
        require(afterInvalid.count == 2, "invalid concrete request reached transport")
        print("PASS Google concrete defaults remain AUTO; undeclared required tools fail before transport")
    }
}
