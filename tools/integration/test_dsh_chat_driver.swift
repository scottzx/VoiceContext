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
enum AssistantBlockKind: Equatable {
    case text, thinking, shellTool(command: String)
    case fileReadTool(path: String), fileWriteTool(path: String), fileEditTool(path: String)
    case browserTool(action: String), readImageTool(path: String), memoryTool(action: String)
    case subagentTool(action: String, taskTitle: String), info
}
enum ToolBlockStatus: Equatable { case running, success, failed(message: String), cancelled }
final class AssistantBlock {
    let id = UUID()
    var content: String
    var kind: AssistantBlockKind
    var toolStatus: ToolBlockStatus?
    var thinkingContentBuffer = ""
    var isThinkingExpanded = false
    var thinkingUserToggled = false
    var cachedMarkdown: String?
    var cachedAttributedString: String?
    var toolUseId: String?
    var toolInputArgs: String?
    var toolSummary: String?
    var remoteToolName: String?
    var browserURL: String?
    var imageFilePath: String?
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
    var cacheFinalizationCounts: [UUID: Int] = [:]
    func cacheAttributedString(for block: AssistantBlock) {
        guard !block.content.isEmpty else { return }
        cacheFinalizationCounts[block.id, default: 0] += 1
        block.cachedMarkdown = "parsed:" + block.content
        block.cachedAttributedString = "rendered:" + block.content
    }
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
    var loadOlderCount = 0
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
    func loadOlder(sessionID: String) async throws { loadOlderCount += 1 }
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

    @MainActor static func session(_ service: DSHService, id: String) async -> (AIChatViewModel, DSHClient) {
        let vm = AIChatViewModel()
        vm.dshService = service
        vm.sessionId = id
        await vm.loadDSHSession()
        await settle()
        return (vm, DSHClient.latest!)
    }

    @MainActor static func assertUniqueIDs(_ vm: AIChatViewModel) {
        let messageIDs = vm.messages.map(\.id)
        let blockIDs = vm.messages.flatMap(\.blocks).map(\.id)
        precondition(Set(messageIDs).count == messageIDs.count, "diffable message identifiers must be unique")
        precondition(Set(blockIDs).count == blockIDs.count, "diffable block identifiers must be unique across messages")
    }

    @MainActor static func testTurnGroupingAndOrder(_ service: DSHService) async {
        let (vm, client) = await session(service, id: "ordered")
        let read = DSHChatTool(id: "read-call", name: "read_file", arguments: #"{"path":"/srv/report.md"}"#,
                               status: "completed", output: "file contents")
        let before = DSHChatEntry(id: "step-0", role: .assistant, text: "Before", reasoning: "Reason",
                                  tools: [read], parts: [
                                    DSHChatPart(id: "reason", kind: .reasoning("Reason")),
                                    DSHChatPart(id: "before", kind: .text("Before")),
                                    DSHChatPart(id: "read", kind: .tool(read))
                                  ], turn: 7, step: 0)
        let after = DSHChatEntry(id: "step-1", role: .assistant, text: "After", parts: [
            DSHChatPart(id: "after", kind: .text("After"))
        ], turn: 7, step: 1)
        var snapshot = DSHChatSnapshot(sessionID: "ordered", entries: [before, after], connectionState: .connected)
        client.emit(snapshot)
        await settle()
        precondition(vm.messages.count == 1, "successive assistant steps in one remote turn must share a native message")
        let grouped = vm.messages[0]
        precondition(grouped.blocks.map(\.kind) == [.thinking, .text, .fileReadTool(path: "/srv/report.md"), .text],
                     "reasoning, text, tool and following text must retain server order without legacy-tools duplication")
        precondition(grouped.blocks.map(\.content) == ["Reason", "Before", "file contents", "After"])
        let existingBlocks = grouped.blocks
        let nextUser = DSHChatEntry(id: "user-followup", role: .user, text: "Next", turn: 7)
        let nextReply = DSHChatEntry(id: "reply-followup", role: .assistant, text: "New reply", turn: 7)
        let newTurn = DSHChatEntry(id: "reply-9", role: .assistant, text: "Separate turn", turn: 9)
        snapshot.entries += [nextUser, nextReply, newTurn]
        client.emit(snapshot)
        await settle()
        precondition(vm.messages.count == 4 && vm.messages[0] === grouped && vm.messages[1].role == .user,
                     "a user boundary and a later explicit turn must each split assistant messages")
        precondition(zip(vm.messages[0].blocks, existingBlocks).allSatisfy { $0 === $1 })
        assertUniqueIDs(vm)

        // An ordered part list can interleave text and a tool inside one source message.
        let interleaved = DSHChatEntry(id: "interleaved", role: .assistant, text: "firstlast", parts: [
            DSHChatPart(id: "first", kind: .text("first")),
            DSHChatPart(id: "middle", kind: .tool(read)),
            DSHChatPart(id: "last", kind: .text("last"))
        ], turn: 10)
        snapshot.entries.append(interleaved)
        client.emit(snapshot)
        await settle()
        precondition(vm.messages.last!.blocks.map(\.content) == ["first", "file contents", "last"],
                     "aggregate text must not move trailing text ahead of its tool")
        snapshot.entries = [
            DSHChatEntry(id: "before-tool", role: .assistant, text: "Before tool", turn: 11),
            DSHChatEntry(id: "tool-event", role: .tool, toolName: "read_file", toolOutput: "file contents",
                         toolStatus: "completed", turn: 11),
            DSHChatEntry(id: "after-tool", role: .assistant, text: "After tool", turn: 11)
        ]
        client.emit(snapshot)
        await settle()
        precondition(vm.messages.count == 1 && vm.messages[0].blocks.map(\.content) == ["Before tool", "file contents", "After tool"],
                     "tool-role entries in the same known turn must stay between adjacent assistant steps")
        vm.detachDSHSession()
    }

    @MainActor static func testReplayAndUnknownTurns(_ service: DSHService) async {
        let (vm, client) = await session(service, id: "replay")
        let tool = DSHChatTool(id: "same-call", name: "shell", arguments: #"{"command":"pwd"}"#,
                               status: "completed", output: "/srv")
        let part = DSHChatPart(id: "replayed-tool", kind: .tool(tool))
        let replay = DSHChatEntry(id: "event-1", role: .assistant, text: "Once", parts: [
            DSHChatPart(id: "replayed-text", kind: .text("Once")), part, part
        ], turn: 1, sourceMessageID: "source-1")
        client.emit(DSHChatSnapshot(sessionID: "replay", entries: [replay, replay], connectionState: .connected))
        await settle()
        precondition(vm.messages.count == 1 && vm.messages[0].blocks.count == 2,
                     "duplicate entry and part delivery must not render repeated native rows")
        assertUniqueIDs(vm)

        // A sourceMessageID can recur for distinct sequence records; it is not a UI row ID.
        let unknownA = DSHChatEntry(id: "event-a", role: .assistant, text: "A", parts: [
            DSHChatPart(id: "text-a", kind: .text("A")), DSHChatPart(id: "tool-a", kind: .tool(tool))
        ], sourceMessageID: "shared-source")
        let unknownB = DSHChatEntry(id: "event-b", role: .assistant, text: "B", parts: [
            DSHChatPart(id: "text-b", kind: .text("B")), DSHChatPart(id: "tool-b", kind: .tool(tool))
        ], sourceMessageID: "shared-source")
        client.emit(DSHChatSnapshot(sessionID: "replay", entries: [unknownA, unknownB], connectionState: .connected))
        await settle()
        precondition(vm.messages.count == 2 && vm.messages.map(\.content) == ["A", "B"],
                     "without a known turn, distinct sequence entries must remain separate")
        assertUniqueIDs(vm)
        precondition(vm.messages[0].blocks.last !== vm.messages[1].blocks.last,
                     "reused remote tool IDs in distinct parts must not share a diffable block object")

        let splitTurn = DSHChatSnapshot(sessionID: "replay", entries: [
            DSHChatEntry(id: "same-a", role: .assistant, text: "Same", turn: 7),
            DSHChatEntry(id: "unknown-tool", role: .tool, toolName: "shell", toolOutput: "orphan output", toolStatus: "completed"),
            DSHChatEntry(id: "same-b", role: .assistant, text: "Same", turn: 7)
        ], connectionState: .connected)
        client.emit(splitTurn)
        await settle()
        precondition(vm.messages.count == 3 && vm.messages[0].content == "Same" && vm.messages[2].content == "Same"
                     && vm.messages[1].blocks[0].content == "orphan output",
                     "nonadjacent groups with the same turn key and text must each receive their own visible content")
        let separatedMessages = vm.messages
        let separatedBlocks = vm.messages.flatMap(\.blocks)
        client.emit(splitTurn)
        await settle()
        precondition(vm.messages.count == separatedMessages.count && vm.messages.flatMap(\.blocks).count == separatedBlocks.count
                     && zip(vm.messages, separatedMessages).allSatisfy { $0 === $1 }
                     && zip(vm.messages.flatMap(\.blocks), separatedBlocks).allSatisfy { $0 === $1 },
                     "repeated snapshots must retain both separated same-turn message objects and their blocks")
        assertUniqueIDs(vm)
        vm.detachDSHSession()
    }

    @MainActor static func testTextCachesAndStableHistory(_ service: DSHService) async {
        let (vm, client) = await session(service, id: "cache")
        let history = DSHChatEntry(id: "history", role: .assistant, text: "History", parts: [
            DSHChatPart(id: "history-text", kind: .text("History"))
        ], turn: 2)
        var live = DSHChatEntry(id: "live", role: .assistant, text: "A", isStreaming: true, parts: [
            DSHChatPart(id: "live-text", kind: .text("A"))
        ], turn: 3, step: 1)
        var snapshot = DSHChatSnapshot(sessionID: "cache", entries: [history, live], isRunning: true,
                                       connectionState: .connected, hasMore: true)
        client.emit(snapshot)
        await settle()
        let historyMessage = vm.messages[0]
        let historyBlock = historyMessage.blocks[0]
        let liveMessage = vm.messages[1]
        let liveBlock = liveMessage.blocks[0]
        precondition(vm.cacheFinalizationCounts[historyBlock.id] == 1 && historyBlock.cachedAttributedString == "rendered:History",
                     "settled historical text must use the native completed Markdown cache even while another turn runs")
        precondition(vm.cacheFinalizationCounts[liveBlock.id] == nil && liveBlock.cachedAttributedString == nil,
                     "live text must not be finalized into a completed cache")
        live.text = "AB"
        live.parts[0].kind = .text("AB")
        snapshot.entries[1] = live
        client.emit(snapshot)
        await settle()
        precondition(vm.messages[1] === liveMessage && vm.messages[1].blocks[0] === liveBlock && liveBlock.content == "AB")
        precondition(vm.cacheFinalizationCounts[historyBlock.id] == 1 && vm.cacheFinalizationCounts[liveBlock.id] == nil)

        client.emit(DSHChatSnapshot(sessionID: "cache", connectionState: .disconnected))
        await settle()
        precondition(vm.messages[0] === historyMessage && vm.messages[1] === liveMessage)
        precondition(vm.cacheFinalizationCounts[liveBlock.id] == nil, "transport loss must not masquerade as completed text")
        client.emit(snapshot)
        await settle()
        precondition(vm.messages[1] === liveMessage && vm.messages[1].blocks[0] === liveBlock,
                     "reconnection must reuse existing message and block objects")
        live.isStreaming = false
        snapshot.entries[1] = live
        snapshot.isRunning = false
        client.emit(snapshot)
        await settle()
        precondition(vm.cacheFinalizationCounts[liveBlock.id] == 1 && liveBlock.cachedMarkdown == "parsed:AB"
                     && liveBlock.cachedAttributedString == "rendered:AB",
                     "completion with unchanged text must still finalize its existing block")
        client.emit(snapshot)
        await settle()
        precondition(vm.cacheFinalizationCounts[liveBlock.id] == 1 && vm.cacheFinalizationCounts[historyBlock.id] == 1,
                     "unchanged completed snapshots must reuse, rather than repeatedly rebuild, their caches")

        vm.loadOlderDSHMessages()
        await settle()
        let older = DSHChatEntry(id: "older", role: .assistant, text: "Older", turn: 1)
        snapshot.entries.insert(older, at: 0)
        client.emit(snapshot)
        await settle()
        precondition(client.loadOlderCount == 1 && client.sendCount == 0 && client.cancelCount == 0)
        precondition(vm.messages[1] === historyMessage && vm.messages[1].blocks[0] === historyBlock
                     && vm.messages[2] === liveMessage && vm.messages[2].blocks[0] === liveBlock,
                     "prepending history must preserve visible native objects and their final caches")
        snapshot.entries.insert(DSHChatEntry(id: "earlier-step", role: .assistant, text: "Earlier step", turn: 3, step: 0), at: 2)
        client.emit(snapshot)
        await settle()
        precondition(vm.messages.count == 3 && vm.messages[2] === liveMessage
                     && vm.messages[2].blocks.first!.content == "Earlier step" && vm.messages[2].blocks.last === liveBlock,
                     "paging an earlier step into an existing turn must retain the group's existing message alias")
        precondition(vm.cacheFinalizationCounts[liveBlock.id] == 1)
        snapshot.entries.insert(DSHChatEntry(id: "earlier-user", role: .user, text: "Original question", turn: 3), at: 2)
        client.emit(snapshot)
        await settle()
        precondition(vm.messages.count == 4 && vm.messages[2].role == .user && vm.messages[3] === liveMessage
                     && vm.messages[3].blocks.last === liveBlock,
                     "paging the earlier user boundary must preserve the visible turn through entry aliases")

        // A cold history replay can replace provisional source/part IDs entirely.
        vm.detachDSHSession()
        await vm.loadDSHSession()
        await settle()
        let resumedClient = DSHClient.latest!
        let durable = DSHChatEntry(id: "durable-step", role: .assistant, text: "Durable settled text", parts: [
            DSHChatPart(id: "durable-text", kind: .text("Durable settled text"))
        ], turn: 3, step: 1)
        snapshot.entries = Array(snapshot.entries.prefix(3)) + [durable]
        resumedClient.emit(snapshot)
        await settle()
        precondition(resumedClient !== client && vm.messages[3] === liveMessage
                     && liveMessage.content == "Durable settled text" && liveMessage.blocks.count == 1
                     && liveMessage.blocks[0] !== liveBlock && liveMessage.blocks[0].content == "Durable settled text",
                     "changed durable IDs must use the canonical turn cache and replace, rather than retain, provisional blocks")
        precondition(vm.messages[1] === historyMessage && vm.messages[1].blocks[0] === historyBlock)
        precondition(liveMessage.blocks[0].cachedAttributedString == "rendered:Durable settled text")
        assertUniqueIDs(vm)
        vm.detachDSHSession()
    }

    @MainActor static func testConsecutiveReasoning(_ service: DSHService) async {
        let (vm, client) = await session(service, id: "reasoning")
        let r34 = DSHChatPart(id: "reason-34", kind: .reasoning("34"))
        let r30 = DSHChatPart(id: "reason-30", kind: .reasoning("30"))
        let r25 = DSHChatPart(id: "reason-25", kind: .reasoning("25"))
        var first = DSHChatEntry(id: "reason-step-0", role: .assistant, reasoning: "34", parts: [r34], turn: 30, step: 0)
        var second = DSHChatEntry(id: "reason-step-1", role: .assistant, reasoning: "25", parts: [r25], turn: 30, step: 1)
        var snapshot = DSHChatSnapshot(sessionID: "reasoning", entries: [first], connectionState: .connected)
        client.emit(snapshot)
        await settle()
        let message = vm.messages[0]
        let firstBlock = message.blocks[0]
        firstBlock.isThinkingExpanded = true
        firstBlock.thinkingUserToggled = true
        first.parts = [r34, r30]
        first.reasoning = "34\n\n30"
        snapshot.entries = [first, second]
        client.emit(snapshot)
        await settle()
        precondition(vm.messages.count == 1 && message.blocks.count == 1 && message.blocks[0].kind == .thinking,
                     "consecutive reasoning parts across assistant steps must render as one thinking block")
        precondition(message.blocks[0] === firstBlock && firstBlock.content == "34\n\n30\n\n25"
                     && firstBlock.thinkingContentBuffer == firstBlock.content
                     && firstBlock.isThinkingExpanded && firstBlock.thinkingUserToggled,
                     "a growing reasoning run must preserve its first block UUID and user expansion state")
        client.emit(snapshot)
        await settle()
        precondition(message.blocks[0] === firstBlock && firstBlock.content == "34\n\n30\n\n25",
                     "full snapshot replay must rebuild, rather than append, the reasoning run")
        let r87 = DSHChatPart(id: "reason-87", kind: .reasoning("87"))
        let r63 = DSHChatPart(id: "reason-63", kind: .reasoning("63"))
        second.parts = [DSHChatPart(id: r25.id, kind: .reasoning("25 updated")), r87, r63]
        snapshot.entries[1] = second
        client.emit(snapshot)
        await settle()
        precondition(firstBlock.content == "34\n\n30\n\n25 updated\n\n87\n\n63"
                     && firstBlock.thinkingContentBuffer == firstBlock.content,
                     "updated complete parts must replace prior reasoning without retaining stale text")

        first.parts.insert(DSHChatPart(id: "earlier-reason", kind: .reasoning("Earlier")), at: 0)
        snapshot.entries[0] = first
        client.emit(snapshot)
        await settle()
        precondition(message.blocks.count == 1 && message.blocks[0] === firstBlock
                     && firstBlock.content == "Earlier\n\n34\n\n30\n\n25 updated\n\n87\n\n63"
                     && firstBlock.isThinkingExpanded && firstBlock.thinkingUserToggled,
                     "prepending an older reasoning part must reuse an existing run member's block and expansion state")

        let read = DSHChatTool(id: "reason-tool", name: "read_file", arguments: #"{"path":"/srv/report.md"}"#,
                               status: "completed", output: "tool output")
        first.parts += [DSHChatPart(id: "answer-break", kind: .text("Answer")), r25,
                        DSHChatPart(id: "tool-break", kind: .tool(read)), r87]
        second.parts = [r63]
        snapshot.entries = [first, second,
            DSHChatEntry(id: "question-break", role: .user, text: "Follow-up", turn: 30),
            DSHChatEntry(id: "after-question", role: .assistant, parts: [
                DSHChatPart(id: "question-reason", kind: .reasoning("Question reply"))
            ], turn: 30),
            DSHChatEntry(id: "next-reason-turn", role: .assistant, parts: [
                DSHChatPart(id: "next-turn-reason", kind: .reasoning("Next turn"))
            ], turn: 31)
        ]
        client.emit(snapshot)
        await settle()
        precondition(vm.messages.count == 4 && vm.messages[0] === message && vm.messages[1].role == .user)
        precondition(message.blocks.map(\.kind) == [.thinking, .text, .thinking, .fileReadTool(path: "/srv/report.md"), .thinking]
                     && message.blocks.map(\.content) == ["Earlier\n\n34\n\n30", "Answer", "25", "tool output", "87\n\n63"],
                     "text and tool parts must split reasoning runs without moving their content")
        precondition(message.blocks[0] === firstBlock && firstBlock.isThinkingExpanded && firstBlock.thinkingUserToggled)
        precondition(vm.messages[2].blocks.map(\.content) == ["Question reply"]
                     && vm.messages[3].blocks.map(\.content) == ["Next turn"],
                     "user boundaries and new turns must each start an independent thinking block")
        assertUniqueIDs(vm)
        let splitBlocks = vm.messages.flatMap(\.blocks)
        client.emit(snapshot)
        await settle()
        precondition(vm.messages.flatMap(\.blocks).count == splitBlocks.count
                     && zip(vm.messages.flatMap(\.blocks), splitBlocks).allSatisfy { $0 === $1 },
                     "splitting a formerly merged run must not duplicate a cached block UUID or replace stable split blocks")
        assertUniqueIDs(vm)
        vm.detachDSHSession()
    }

    @MainActor static func testReusedPartIDsAcrossKinds(_ service: DSHService) async {
        let tool = DSHChatTool(id: "kind-change-tool", name: "read_file", arguments: #"{"path":"/srv/report.md"}"#,
                               status: "completed", output: "tool output")
        for (label, leading) in [("tool", DSHChatPartKind.tool(tool)), ("empty", DSHChatPartKind.text(""))] {
            let sessionID = "compacted-" + label
            let (vm, client) = await session(service, id: sessionID)
            let live = DSHChatEntry(id: "live-entry", role: .assistant, text: "C", reasoning: "A\n\nB", isStreaming: true,
                                    parts: [DSHChatPart(id: "p0", kind: leading),
                                            DSHChatPart(id: "p1", kind: .reasoning("A")),
                                            DSHChatPart(id: "p2", kind: .reasoning("B")),
                                            DSHChatPart(id: "p3", kind: .text("C"))], turn: 40, step: 0)
            client.emit(DSHChatSnapshot(sessionID: sessionID, entries: [live], isRunning: true, connectionState: .connected))
            await settle()
            let message = vm.messages[0]
            let thinking = message.blocks.first { $0.kind == .thinking }!
            thinking.isThinkingExpanded = true
            thinking.thinkingUserToggled = true
            let settled = DSHChatEntry(id: "settled-entry", role: .assistant, text: "C", reasoning: "A\n\nB", parts: [
                DSHChatPart(id: "p0", kind: .reasoning("A")),
                DSHChatPart(id: "p1", kind: .reasoning("B")),
                DSHChatPart(id: "p2", kind: .text("C"))
            ], turn: 40, step: 0)
            let snapshot = DSHChatSnapshot(sessionID: sessionID, entries: [settled], connectionState: .connected)
            client.emit(snapshot)
            await settle()
            precondition(vm.messages[0] === message && message.blocks.map(\.kind) == [.thinking, .text]
                         && message.blocks.map(\.content) == ["A\n\nB", "C"],
                         "settlement compaction must not overwrite a shared reasoning alias with following text")
            precondition(message.blocks[0] === thinking && message.blocks[1] !== thinking
                         && thinking.thinkingContentBuffer == "A\n\nB"
                         && thinking.isThinkingExpanded && thinking.thinkingUserToggled,
                         "compacted reasoning must keep its existing object and expansion while text receives a distinct block")
            assertUniqueIDs(vm)
            let settledBlocks = message.blocks
            client.emit(snapshot)
            await settle()
            precondition(message.blocks.count == settledBlocks.count
                         && zip(message.blocks, settledBlocks).allSatisfy { $0 === $1 },
                         "replayed compacted parts must retain their distinct native block objects")
            assertUniqueIDs(vm)
            vm.detachDSHSession()
        }

        let boundaries: [(String, DSHChatPartKind, AssistantBlockKind, String)] = [
            ("text", .text("C"), .text, "C"),
            ("tool", .tool(tool), .fileReadTool(path: "/srv/report.md"), "tool output")
        ]
        for (label, replacement, kind, content) in boundaries {
            for boundaryFirst in [true, false] {
                let sessionID = "changed-\(label)-\(boundaryFirst)"
                let (vm, client) = await session(service, id: sessionID)
                var entry = DSHChatEntry(id: "changing-entry", role: .assistant, parts: [
                    DSHChatPart(id: "p0", kind: .reasoning("A")), DSHChatPart(id: "p1", kind: .reasoning("B"))
                ], turn: 50)
                client.emit(DSHChatSnapshot(sessionID: sessionID, entries: [entry], connectionState: .connected))
                await settle()
                let message = vm.messages[0]
                let thinking = message.blocks[0]
                thinking.isThinkingExpanded = true
                thinking.thinkingUserToggled = true
                entry.parts = boundaryFirst
                    ? [DSHChatPart(id: "p0", kind: replacement), DSHChatPart(id: "p1", kind: .reasoning("B"))]
                    : [DSHChatPart(id: "p0", kind: .reasoning("A")), DSHChatPart(id: "p1", kind: replacement)]
                let snapshot = DSHChatSnapshot(sessionID: sessionID, entries: [entry], connectionState: .connected)
                client.emit(snapshot)
                await settle()
                let thinkingIndex = boundaryFirst ? 1 : 0
                let boundaryIndex = boundaryFirst ? 0 : 1
                precondition(message.blocks.count == 2 && message.blocks[thinkingIndex] === thinking
                             && thinking.kind == .thinking && thinking.content == (boundaryFirst ? "B" : "A")
                             && thinking.thinkingContentBuffer == thinking.content
                             && thinking.isThinkingExpanded && thinking.thinkingUserToggled,
                             "a reused text/tool part ID must not mutate the surviving reasoning alias or lose its expansion state")
                precondition(message.blocks[boundaryIndex] !== thinking && message.blocks[boundaryIndex].kind == kind
                             && message.blocks[boundaryIndex].content == content)
                assertUniqueIDs(vm)
                let changedBlocks = message.blocks
                client.emit(snapshot)
                await settle()
                precondition(message.blocks.count == changedBlocks.count
                             && zip(message.blocks, changedBlocks).allSatisfy { $0 === $1 })
                assertUniqueIDs(vm)
                vm.detachDSHSession()
            }
        }
    }

    @MainActor static func testRemoteToolPresentation(_ service: DSHService) async {
        let (vm, client) = await session(service, id: "tools")
        let fixtures: [(String, String, AssistantBlockKind, String?)] = [
            ("functions.file_read", #"{"path":"/srv/read.md","tool_title":"Read remote report"}"#, .fileReadTool(path: "/srv/read.md"), "Read remote report"),
            ("write_file", #"{"file_path":"/srv/write.md","content":"draft"}"#, .fileWriteTool(path: "/srv/write.md"), nil),
            ("apply_patch", #"{"filename":"/srv/edit.md","patch":"replacement"}"#, .fileEditTool(path: "/srv/edit.md"), nil),
            ("browser_use", #"{"action":"navigate","url":"https://example.com/remote"}"#, .browserTool(action: "navigate"), nil),
            ("view_image", #"{"path":"/srv/image.png"}"#, .readImageTool(path: "/srv/image.png"), nil)
        ]
        var parts = [DSHChatPart(id: "before", kind: .text("![remote](minis://shared/private.png) [web](https://example.com)"))]
        for (index, fixture) in fixtures.enumerated() {
            let tool = DSHChatTool(id: "tool-\(index)", name: fixture.0, arguments: fixture.1,
                                   status: "completed", output: "remote output \(index)")
            parts.append(DSHChatPart(id: "part-\(index)", kind: .tool(tool)))
        }
        parts.append(DSHChatPart(id: "after", kind: .text("![remote](file:///private/phone.png)")))
        let entry = DSHChatEntry(id: "tools-entry", role: .assistant, parts: parts, turn: 1)
        client.emit(DSHChatSnapshot(sessionID: "tools", entries: [entry], connectionState: .connected))
        await settle()
        let blocks = vm.messages[0].blocks
        precondition(blocks.count == fixtures.count + 2)
        for (index, fixture) in fixtures.enumerated() {
            let block = blocks[index + 1]
            precondition(block.kind == fixture.2 && block.toolStatus == .success, "remote tools must use their native presentation kind")
            precondition(block.content == "remote output \(index)" && block.toolInputArgs == fixture.1
                         && block.toolUseId == "tool-\(index)", "tool output, raw arguments and call identity must remain distinct")
            precondition(block.remoteToolName == fixture.0 && block.toolSummary == fixture.3,
                         "copy details must retain the remote tool name; only explicit tool_title overrides native summaries")
            precondition(block.imageFilePath == nil && block.browserURL == nil,
                         "remote file/browser metadata must not activate phone-local media or browser preview")
        }
        precondition(blocks.first!.content.contains("dshresource://unavailable/") && blocks.first!.content.contains("https://example.com"))
        precondition(blocks.last!.content.contains("dshresource://unavailable/") && !blocks.last!.content.contains("](file:"),
                     "every ordered text part must keep remote resources out of the phone workspace namespace")
        assertUniqueIDs(vm)
        vm.detachDSHSession()
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
        await testTurnGroupingAndOrder(service)
        await testReplayAndUnknownTurns(service)
        await testTextCachesAndStableHistory(service)
        await testConsecutiveReasoning(service)
        await testReusedPartIDsAcrossKinds(service)
        await testRemoteToolPresentation(service)
        print("DSH chat driver contract tests passed")
    }
}
