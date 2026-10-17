import Foundation

enum AgentToolPolicy: String, Sendable { case standalone, orchestrator }
struct AgentProfile: Sendable, Equatable {
    let id: String
    var name: String
    var emoji = ""
    var title = ""
    var summary = ""
    var accentColor = "#636366"
    var mainSessionId: String?
    var defaultModelEntryId: String?
    var toolPolicy = AgentToolPolicy.orchestrator
    var memoryEnabled = true
    var archivedAt: Date?
    var sortOrder = 0
    var isArchived: Bool { archivedAt != nil }
    static let defaultAgentId = "agent-default"
    static var root: URL { URL(fileURLWithPath: CommandLine.arguments[1]) }
    static func directory(for id: String) -> URL { root.appendingPathComponent("agents/" + id) }
    static func memoryDir(for id: String) -> URL { directory(for: id).appendingPathComponent("memory") }
}
struct SoulMetadata { let name: String; let emoji: String; let style: String; let lang: String; let icon: String }
struct SoulFile { var metadata: SoulMetadata; var body: String }
@MainActor enum VoiceAgentConfiguration {
    static func install() { AgentRuntimePolicies.hiddenAgentIDs.insert(XiaolanAgent.id) }
}
enum SoulStore {
    static func fileURL(for id: String?) -> URL {
        if id == nil || id == AgentProfile.defaultAgentId { return AgentProfile.root.appendingPathComponent("legacy-memory/SOUL.md") }
        return AgentProfile.directory(for: id!).appendingPathComponent("SOUL.md")
    }
    static func save(_ file: SoulFile, for id: String?) throws {
        let url = fileURL(for: id)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (file.metadata.name + "\n" + file.body).write(to: url, atomically: true, encoding: .utf8)
    }
    static func load(for id: String?) -> SoulFile? {
        guard let raw = try? String(contentsOf: fileURL(for: id), encoding: .utf8), let split = raw.firstIndex(of: "\n") else { return nil }
        return .init(metadata: .init(name: String(raw[..<split]), emoji: "", style: "", lang: "", icon: ""), body: String(raw[raw.index(after: split)...]))
    }
}
struct HostSession: Sendable, Equatable { let id: String; var agentId: String? }
@MainActor final class ChatStore {
    static let shared = ChatStore()
    var profiles: [String: AgentProfile] = [:]
    var sessions: [String: HostSession] = [:]
    var memories: [String: Bool] = [:]
    var globalMemory = true
    var upserts = 0
    func getAgent(_ id: String) async -> AgentProfile? { await Task.yield(); return profiles[id] }
    func listAgents(includeArchived: Bool = false) async -> [AgentProfile] {
        await Task.yield()
        return profiles.values.filter { includeArchived || !$0.isArchived }.sorted { $0.sortOrder < $1.sortOrder }
    }
    func upsertAgent(_ profile: AgentProfile) async { upserts += 1; profiles[profile.id] = profile }
    func getSession(_ id: String) async -> HostSession? { sessions[id] }
    func newSession() -> String {
        let id = UUID().uuidString; sessions[id] = .init(id: id, agentId: nil); memories[id] = globalMemory; return id
    }
    func linkSession(_ id: String, agentId: String, role: String, parentSessionId: String?, spawnTitle: String?) async { sessions[id]?.agentId = agentId }
    func linkGroupSession(_ id: String, title: String) async {}
    func setMemoryEnabled(sessionId: String, enabled: Bool) async { memories[sessionId] = enabled }
}
@MainActor final class AgentStore {
    static let shared = AgentStore()
    var agents: [AgentProfile] = []
    func loadAgent(_ id: String) async -> AgentProfile? { await ChatStore.shared.getAgent(id) }
}
enum GroupSessionRole { static let group = "group" }
enum HostRole { case main, executor }
struct GroupMember {
    let id: String; let name: String; let title: String; let emoji: String; let accentColor: String; let summary: String; let slot: Int
}
@MainActor final class HostVM {
    var sessionSource = "", agentId: String?, groupId: String?
    var isGroupTranscript = false
    var agentRole = HostRole.main
    var resolvedToolPolicy = AgentToolPolicy.standalone
    var memoryEnabled = true
    var groupMembers: [GroupMember] = []
    func ensureSessionReturningId() async -> String {
        let id = ChatStore.shared.newSession()
        memoryEnabled = ChatStore.shared.memories[id]!
        return id
    }
}
@MainActor final class ViewModelCache {
    static let shared = ViewModelCache()
    var cached: [String: HostVM] = [:]
    func createDraft() -> HostVM { HostVM() }
    func cacheDraft(_ vm: HostVM, sessionId: String) { cached[sessionId] = vm }
}
struct SessionModelBinding {
    enum Source: Equatable { case directEntry(modelEntryId: String) }
    let sessionId: String
    let primarySource: Source
}
@MainActor final class ProviderConfigStore {
    static let shared = ProviderConfigStore()
    var bindings: [String: SessionModelBinding] = [:]
    func binding(for id: String) -> SessionModelBinding? { bindings[id] }
    func entry(for id: String) -> String? { id }
    func setBinding(_ binding: SessionModelBinding, for id: String) { bindings[id] = binding }
}
@MainActor final class IOSAgentSessionRunner { static let shared = IOSAgentSessionRunner() }

@main struct XiaolanAgentChecks {
    @MainActor static func main() async throws {
        AgentRuntimePolicies.hiddenAgentIDs = [XiaolanAgent.id]
        let store = ChatStore.shared
        let defaultAgent = AgentProfile(id: AgentProfile.defaultAgentId, name: "自定义一芥", emoji: "🌿",
                                        summary: "旧配置", defaultModelEntryId: "yima-model", toolPolicy: .standalone,
                                        memoryEnabled: true, sortOrder: 0)
        store.profiles[defaultAgent.id] = defaultAgent
        try SoulStore.save(.init(metadata: .init(name: "一芥", emoji: "", style: "", lang: "", icon: ""), body: "一芥原有个性与长期记忆"), for: defaultAgent.id)
        let legacySoul = try Data(contentsOf: SoulStore.fileURL(for: defaultAgent.id))

        // All simultaneous launch/voice/meeting callers share one bootstrap.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<30 { group.addTask { try await XiaolanAgent.ensure() } }
            try await group.waitForAll()
        }
        precondition(store.upserts == 1 && store.profiles.count == 2)
        let seeded = store.profiles[XiaolanAgent.id]!
        precondition(seeded.name == "小蓝同学" && !seeded.memoryEnabled && seeded.mainSessionId == nil)
        precondition(seeded.toolPolicy == .orchestrator && seeded.id != AgentProfile.defaultAgentId)
        precondition(AgentStore.shared.agents.map(\.id) == [AgentProfile.defaultAgentId], "Xiaolan is a backend voice identity, not a new roster chat")
        precondition(FileManager.default.fileExists(atPath: AgentProfile.memoryDir(for: XiaolanAgent.id).path))
        precondition(SoulStore.fileURL(for: XiaolanAgent.id) != SoulStore.fileURL(for: defaultAgent.id))
        let firstSoul = try Data(contentsOf: SoulStore.fileURL(for: XiaolanAgent.id))
        try await XiaolanAgent.ensure()
        let secondSoul = try Data(contentsOf: SoulStore.fileURL(for: XiaolanAgent.id))
        let preservedLegacySoul = try Data(contentsOf: SoulStore.fileURL(for: defaultAgent.id))
        precondition(store.upserts == 1 && firstSoul == secondSoul)
        precondition(store.profiles[defaultAgent.id] == defaultAgent && legacySoul == preservedLegacySoul)
        let shippedBefore = """
            你是小蓝同学，负责实时语音交互、App 内页面导航和简短原生操作。
            用简短、自然、明确的口语回应，以真实工具回执说明结果，不播报内部思考。
            一芥（Yima）是另一位独立助理，负责复杂任务、资料处理和长期记忆；需要这些能力时明确交给一芥，不冒充其身份或复制其会话与记忆。
            """
        for body in [shippedBefore, shippedBefore + "\n"] {
            try SoulStore.save(.init(metadata: .init(name: "小蓝同学", emoji: "", style: "", lang: "", icon: ""), body: body), for: XiaolanAgent.id)
            try await XiaolanAgent.ensure()
            precondition(SoulStore.load(for: XiaolanAgent.id)?.body == XiaolanAgent.defaultPersona,
                         "Only the exactly shipped previous persona migrates to the configured subagent wording")
        }

        // Existing personalization, own model and memory choice are not reset.
        var custom = seeded
        custom.name = "我的小蓝"; custom.summary = "保留自定义资料"; custom.memoryEnabled = true
        custom.defaultModelEntryId = "xiaolan-preferred"; custom.toolPolicy = .standalone
        store.profiles[XiaolanAgent.id] = custom
        let customSoul = "用户编写的小蓝人设"
        try customSoul.write(to: SoulStore.fileURL(for: XiaolanAgent.id), atomically: true, encoding: .utf8)
        try await XiaolanAgent.ensure()
        precondition(store.profiles[XiaolanAgent.id] == custom && store.upserts == 1)
        let preservedCustomSoul = try String(contentsOf: SoulStore.fileURL(for: XiaolanAgent.id), encoding: .utf8)
        precondition(preservedCustomSoul == customSoul)

        // Archive is a user choice, never a reason to duplicate or resurrect it.
        var archived = custom; archived.archivedAt = Date(); store.profiles[XiaolanAgent.id] = archived
        do { try await XiaolanAgent.ensure(); preconditionFailure("Archived profile must be rejected") } catch {}
        precondition(store.profiles[XiaolanAgent.id] == archived && store.upserts == 1)
        let runner = IOSAgentSessionRunner.shared
        let archivedSession = await runner.createSession(.init(agentId: XiaolanAgent.id, source: "xiaolan_voice"))
        precondition(archivedSession == nil && store.sessions.isEmpty, "Archive rejection precedes session creation")
        store.profiles[XiaolanAgent.id] = custom

        // Persisted ownership is authoritative; merely being a voice source
        // cannot give an old Yima/unowned session the new agent's identity.
        for (name, owner, expected) in [("legacy", Optional<String>.none, false), ("yima", Optional(defaultAgent.id), false), ("xiaolan", Optional(XiaolanAgent.id), true)] {
            store.sessions[name] = .init(id: name, agentId: owner)
            let owns = await XiaolanAgent.ownsSession(name)
            precondition(owns == expected && store.sessions[name]?.agentId == owner)
        }

        // Every explicit saved profile supplies its own preferences; global
        // composer defaults never replace that agent's saved choices.
        var withoutMemory = custom; withoutMemory.memoryEnabled = false; store.profiles[XiaolanAgent.id] = withoutMemory
        store.globalMemory = true
        let first = await runner.createSession(.init(agentId: XiaolanAgent.id, source: "xiaolan_voice"))
        precondition(first != nil && store.sessions[first!]?.agentId == XiaolanAgent.id && store.memories[first!] == false)
        precondition(ViewModelCache.shared.cached[first!]?.memoryEnabled == false)
        precondition(ProviderConfigStore.shared.bindings[first!]?.primarySource == .directEntry(modelEntryId: "xiaolan-preferred"))
        store.globalMemory = false
        store.profiles[XiaolanAgent.id] = custom
        let second = await runner.createSession(.init(agentId: XiaolanAgent.id, source: "meeting_assistant", defaultModelEntryId: "explicit-model"))
        precondition(store.memories[second!] == true && ViewModelCache.shared.cached[second!]?.memoryEnabled == true)
        precondition(ProviderConfigStore.shared.bindings[second!]?.primarySource == .directEntry(modelEntryId: "explicit-model"))
        let yima = await runner.createSession(.init(agentId: defaultAgent.id, source: "agent"))
        precondition(store.memories[yima!] == true && ViewModelCache.shared.cached[yima!]?.memoryEnabled == true)
        precondition(ProviderConfigStore.shared.bindings[yima!]?.primarySource == .directEntry(modelEntryId: "yima-model"))
        precondition(store.profiles[defaultAgent.id] == defaultAgent)
        let third = AgentProfile(id: "arbitrary-profile", name: "第三位助手", defaultModelEntryId: "third-model", toolPolicy: .standalone, memoryEnabled: false)
        store.profiles[third.id] = third
        let thirdSession = await runner.createSession(.init(agentId: third.id, source: "arbitrary_adapter"))
        precondition(store.sessions[thirdSession!]?.agentId == third.id && store.memories[thirdSession!] == false)
        precondition(ViewModelCache.shared.cached[thirdSession!]?.resolvedToolPolicy == .standalone)
        precondition(ProviderConfigStore.shared.bindings[thirdSession!]?.primarySource == .directEntry(modelEntryId: "third-model"))
        var archivedThird = third; archivedThird.archivedAt = Date(); store.profiles[third.id] = archivedThird
        let sessionCount = store.sessions.count
        let rejectedThird = await runner.createSession(.init(agentId: third.id))
        let rejectedMissing = await runner.createSession(.init(agentId: "missing-profile"))
        precondition(rejectedThird == nil && rejectedMissing == nil && store.sessions.count == sessionCount)
        AgentRuntimePolicies.hiddenAgentIDs = [third.id]
        await AgentStore.shared.refresh()
        precondition(AgentStore.shared.agents.contains { $0.id == XiaolanAgent.id }, "Hidden roster identities come from host config rather than runtime identity literals")
        let finalLegacySoul = try Data(contentsOf: SoulStore.fileURL(for: defaultAgent.id))
        precondition(store.profiles[defaultAgent.id] == defaultAgent && finalLegacySoul == legacySoul)
        print("PASS: profile bootstrap preserves custom/archive/history and migrates only the shipped persona; generic creation inherits any saved profile's model/memory/policy and roster visibility follows configuration")
    }
}
