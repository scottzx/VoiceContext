import Foundation

/// Xiaolan owns its voice sessions and persona; Yima keeps the existing
/// default-agent identity, history and long-term memory untouched.
@MainActor
enum XiaolanAgent {
    static let id = "agent-xiaolan"
    private static var preparation: Task<Void, Error>?
    private static let previousDefaultPersona = """
        你是小蓝同学，负责实时语音交互、App 内页面导航和简短原生操作。
        用简短、自然、明确的口语回应，以真实工具回执说明结果，不播报内部思考。
        一芥（Yima）是另一位独立助理，负责复杂任务、资料处理和长期记忆；需要这些能力时明确交给一芥，不冒充其身份或复制其会话与记忆。
        """
    static let defaultPersona = """
        你是小蓝同学，负责实时语音交互、App 内页面导航和简短原生操作。
        用简短、自然、明确的口语回应，以真实工具回执说明结果，不播报内部思考。
        复杂工作分派给后台子智能体，收到真实完成通知后再交付结果；保持自己的会话、人设和已确认偏好。
        """

    static func ensure() async throws {
        VoiceAgentConfiguration.install()
        if let preparation { try await preparation.value; return }
        let task = Task { @MainActor in try await prepare() }
        preparation = task
        defer { preparation = nil }
        try await task.value
    }

    static func ownsSession(_ sessionID: String) async -> Bool {
        await ChatStore.shared.getSession(sessionID)?.agentId == id
    }

    private static func prepare() async throws {
        let existing = await ChatStore.shared.getAgent(id)
        if existing?.isArchived == true {
            throw unavailable("小蓝同学已归档，暂时无法开启语音模式。")
        }
        try FileManager.default.createDirectory(at: AgentProfile.memoryDir(for: id), withIntermediateDirectories: true)
        let soulURL = SoulStore.fileURL(for: id)
        if var file = SoulStore.load(for: id), file.body == previousDefaultPersona || file.body == previousDefaultPersona + "\n" {
            file.body = defaultPersona
            try SoulStore.save(file, for: id)
        } else if !FileManager.default.fileExists(atPath: soulURL.path) {
            try SoulStore.save(SoulFile(
                metadata: SoulMetadata(name: existing?.name ?? "小蓝同学", emoji: "", style: "", lang: "auto", icon: ""),
                body: defaultPersona
            ), for: id)
        }
        guard existing == nil else { return }
        let roster = await ChatStore.shared.listAgents(includeArchived: true)
        // Another caller of ensure shares preparation; a profile arriving from
        // persistence while awaiting the roster must also keep its own values.
        if let current = await ChatStore.shared.getAgent(id) {
            guard !current.isArchived else {
                throw unavailable("小蓝同学已归档，暂时无法开启语音模式。")
            }
            return
        }
        await ChatStore.shared.upsertAgent(AgentProfile(
            id: id, name: "小蓝同学", emoji: "🎙️", title: "实时语音助理",
            summary: "语音交互、App 导航与简短操作", accentColor: "#636366",
            toolPolicy: .orchestrator, memoryEnabled: false,
            sortOrder: (roster.map(\.sortOrder).max() ?? 0) + 1
        ))
        guard await ChatStore.shared.getAgent(id) != nil else {
            throw unavailable("未能保存小蓝同学配置，请稍后重试。")
        }
        await AgentStore.shared.refresh()
    }

    private static func unavailable(_ text: String) -> NSError {
        NSError(domain: "Yima.XiaolanAgent", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
