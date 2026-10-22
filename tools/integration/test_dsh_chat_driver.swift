// macOS-host contract harness for the production DSH presentation extension.
// swiftc -swift-version 5 Vendor/Phone/src/ios/Agent/RemoteDSH/DSHModels.swift \
//   Vendor/Phone/src/ios/Agent/Chat/AIChatViewModel+DSH.swift \
//   tools/integration/test_dsh_chat_driver.swift -o /tmp/test-dsh-chat-driver
import Foundation

func AppLocalized(_ key: String.LocalizationValue) -> String { String(localized: key) }

struct DSHService { let id: UUID; let name: String; let url: URL }
@MainActor final class DSHServiceStore {
    static let shared = DSHServiceStore()
    var allowedOrigin: URL?
    func token(for id: UUID, matching url: URL) -> String? { allowedOrigin == nil || allowedOrigin == url ? "test" : nil }
}
enum ChatMessageRole { case user, assistant }
enum AssistantBlockKind: Equatable { case text, thinking, shellTool(command: String) }
enum ToolBlockStatus: Equatable { case running, success, failed(message: String), cancelled }
final class AssistantBlock {
    let id = UUID()
    var content: String
    var kind: AssistantBlockKind
    var toolStatus: ToolBlockStatus?
    var thinkingContentBuffer = ""
    var cachedMarkdown: String?
    var cachedAttributedString: String?
    init(kind: AssistantBlockKind, content: String) { self.content = content; self.kind = kind }
}
final class ChatMessage {
    let id = UUID()
    let role: ChatMessageRole
    var content: String
    var blocks: [AssistantBlock] = []
    var remoteAssistantName: String?
    init(role: ChatMessageRole, content: String) { self.role = role; self.content = content }
}
struct Signal { func send() {} }
@MainActor final class AIChatViewModel {
    static var activeSessionId: String?
    var dshService: DSHService?
    var dshClient: DSHClient?
    var dshFollowTask: Task<Void, Never>?
    var dshGeneration = UUID()
    var dshMessages: [String: ChatMessage] = [:]
    var dshRawTexts: [String: String] = [:]
    var dshBlocks: [String: AssistantBlock] = [:]
    var dshInteractions: [DSHInteraction] = []
    var dshModels: [DSHModelOption] = []
    var dshACPConfiguration: [String: Any] = [:]
    var dshModelSelection: DSHModelSelection?
    var dshAgentPreset: String?
    var dshHasMore = false
    var dshSending = false
    var dshConnected = false
    var dshControlBusy = false
    var dshStatusText = ""
    var dshTitle = ""
    var isLoadingSession = false
    var hasCompletedInitialLoad = false
    var errorMessage: String?
    var sessionId: String?
    var draftId: String?
    var inputText = ""
    var isProcessing = false
    var userDidCancel = false
    var attachments: [String] = []
    var currentTask: Task<Void, Never>?
    var messages: [ChatMessage] = []
    var streamingUIUpdatesSuspended = false
    var needsSnapshotReloadOnResume = false
    var isTransitionSuspended = false
    var retrySnapshotReloadSignal = Signal()
}
@MainActor final class ViewModelCache {
    static let shared = ViewModelCache()
    var entries: [String: AIChatViewModel] = [:]
    static func dshKey(serviceID: UUID, sessionID: String) -> String { "dsh:\(serviceID):\(sessionID)" }
    func cacheDSHSession(_ vm: AIChatViewModel, serviceID: UUID, sessionID: String) {
        entries[Self.dshKey(serviceID: serviceID, sessionID: sessionID)] = vm
    }
}
@MainActor final class DSHClient {
    static var latest: DSHClient!
    var continuation: AsyncThrowingStream<DSHChatSnapshot, Error>.Continuation?
    var sendCount = 0
    var cancelCount = 0
    var approvalCount = 0
    var createCount = 0
    var failSend = false
    var failApproval = false
    var selectedModel: String?
    init(baseURL: URL, token: String) { Self.latest = self }
    func connect() async throws {}
    func disconnect() { continuation?.finish(); continuation = nil }
    func modelCatalog() async throws -> [DSHModelOption] { [] }
    func createSession() async throws -> String { createCount += 1; return "created" }
    func follow(sessionID: String) -> AsyncThrowingStream<DSHChatSnapshot, Error> {
        AsyncThrowingStream { continuation = $0 }
    }
    func send(text: String, sessionID: String, requestID: String) async throws {
        sendCount += 1
        if failSend { throw DSHClientError.invalidResponse }
    }
    func cancel(sessionID: String) async throws { cancelCount += 1 }
    func loadOlder(sessionID: String) async throws {}
    func selectModel(sessionID: String, provider: String, model: String, reasoningEffort: String?) async throws { selectedModel = model }
    func acpConfiguration(sessionID: String) async throws -> [String: Any] { [:] }
    func configureACP(sessionID: String, configID: String, value: String) async throws -> [String: Any] { [:] }
    func respondToApproval(interactionID: String, allow: Bool) async throws {
        approvalCount += 1
        if failApproval { throw DSHClientError.invalidResponse }
    }
    func respondToQuestions(interactionID: String, answers: [DSHQuestionAnswer]) async throws {}
    func emit(_ snapshot: DSHChatSnapshot) { continuation?.yield(snapshot) }
}

@main struct DSHChatDriverTests {
    @MainActor static func settle() async {
        for _ in 0..<8 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    @MainActor static func main() async {
        let service = DSHService(id: UUID(), name: "Remote", url: URL(string: "http://100.100.100.1:9000")!)
        let vm = AIChatViewModel()
        vm.dshService = service
        vm.sessionId = "s1"
        await vm.loadDSHSession()
        await settle()
        let client = DSHClient.latest!
        var snapshot = DSHChatSnapshot(sessionID: "s1", entries: [DSHChatEntry(id: "m1", role: .assistant, text: "A", reasoning: "think")], isRunning: true, connectionState: .connected)
        client.emit(snapshot)
        await settle()
        let messageID = vm.messages[0].id
        let blockIDs = vm.messages[0].blocks.map(\.id)
        snapshot.entries[0].text = "AB"
        client.emit(snapshot)
        await settle()
        precondition(vm.messages[0].id == messageID && vm.messages[0].blocks.map(\.id) == blockIDs, "delta must preserve native message/block identity")
        precondition(vm.messages[0].content == "AB" && vm.messages[0].remoteAssistantName == "Remote")
        snapshot.entries[0].tools = [
            DSHChatTool(id: "call1", name: "read", arguments: "path=a", status: "running"),
            DSHChatTool(id: "call2", name: "search", arguments: "q=b", status: "completed", output: "found")
        ]
        client.emit(snapshot)
        await settle()
        precondition(vm.messages[0].blocks.count == 4, "all remote tool calls must render, including pure calls")
        let toolIDs = vm.messages[0].blocks.suffix(2).map(\.id)
        snapshot.entries[0].tools[0].status = "completed"
        snapshot.entries[0].tools[0].output = "contents"
        snapshot.entries.append(DSHChatEntry(id: "orphan", role: .tool, text: "once", toolOutput: "once", toolStatus: "unknown"))
        client.emit(snapshot)
        await settle()
        precondition(vm.messages[0].blocks.suffix(2).map(\.id) == toolIDs)
        precondition(vm.messages[1].blocks[0].content == "once" && vm.messages[1].blocks[0].toolStatus == nil,
                     "orphan tool output must not duplicate or claim unknown success")
        client.emit(DSHChatSnapshot(sessionID: "s1", connectionState: .connecting))
        await settle()
        precondition(vm.messages.count == 2, "connecting must not erase cached history")
        let approval = DSHInteraction(id: "approve", sessionID: "s1", kind: .approval, title: "Confirm", detail: "", questions: [])
        snapshot.interactions = [approval]
        snapshot.connectionState = .reconnecting
        client.emit(snapshot)
        await settle()
        precondition(!vm.dshConnected && vm.dshInteractions.isEmpty)
        let staleAnswer = await vm.respondToDSHApproval(approval, allow: true)
        precondition(!staleAnswer && client.approvalCount == 0, "stale approval must not leave client")
        snapshot.connectionState = .connected
        client.emit(snapshot)
        await settle()
        client.failApproval = true
        let failedAnswer = await vm.respondToDSHApproval(approval, allow: true)
        precondition(!failedAnswer && vm.errorMessage != nil, "failed approval must remain visible")
        vm.detachDSHSession()
        precondition(client.cancelCount == 0 && client.sendCount == 0, "navigation must not stop or resend a remote run")
        let draft = AIChatViewModel()
        draft.dshService = service
        draft.draftId = "draft"
        await draft.loadDSHSession()
        let sender = DSHClient.latest!
        draft.inputText = "hello"
        draft.sendDSHMessage()
        await draft.currentTask?.value
        precondition(sender.createCount == 1 && sender.sendCount == 1 && draft.sessionId == "created" && draft.inputText.isEmpty)
        precondition(ViewModelCache.shared.entries[ViewModelCache.dshKey(serviceID: service.id, sessionID: "created")] === draft)
        draft.isProcessing = false
        draft.inputText = "uncertain"
        sender.failSend = true
        draft.sendDSHMessage()
        await draft.currentTask?.value
        precondition(sender.sendCount == 2 && draft.inputText == "uncertain" && draft.errorMessage != nil, "uncertain send must not retry or lose draft")
        let mismatched = AIChatViewModel()
        mismatched.dshService = service
        DSHServiceStore.shared.allowedOrigin = URL(string: "http://100.100.100.2:9000")!
        let previousClient = DSHClient.latest
        await mismatched.loadDSHSession()
        precondition(mismatched.dshClient == nil && !mismatched.dshConnected && mismatched.errorMessage != nil && DSHClient.latest === previousClient, "origin mismatch must fail before a client receives credentials")
        DSHServiceStore.shared.allowedOrigin = nil
        let resource = "![p](minis://shared/photo.png)\n```swift\n[x](minis://code)\n```\n`[x](minis://inline)`"
        let display = AIChatViewModel.dshDisplayText(resource)
        precondition(display.contains("![p](dshresource://unavailable/") && display.contains("[x](minis://code)") && display.contains("[x](minis://inline)"))
        let localTargets = AIChatViewModel.dshDisplayText("![a](/var/minis/shared/a.png) ![b](file:///private/b.png) ![c](relative.png)\n[img]: minis://shared/c.png\n<img src=\"file:///private/d.png\">\n[web](https://example.com/a.png)")
        precondition(!localTargets.contains("](file:") && !localTargets.contains("](/var/") && !localTargets.contains("](relative.png)") && !localTargets.contains(": minis://") && !localTargets.contains("src=\"file://"))
        precondition(localTargets.contains("[web](https://example.com/a.png)"), "web resources must retain their remote address")
        draft.detachDSHSession()
        print("DSH chat driver contract tests passed")
    }
}
