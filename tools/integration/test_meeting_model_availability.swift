import Foundation

// Fake storage/auth only; routing, initial binding, text filtering and the
// meeting controller's availability method are extracted from product code.
struct AppLogger {
    init(category: String) {}
    func info(_ value: String) {}
    func warning(_ value: String) {}
}
func AppLocalized(_ value: String) -> String { value }
enum ThinkingLevel: String, Codable {
    case high
    static func decoded(_ value: String) -> ThinkingLevel? { Self(rawValue: value) }
}
struct ModelModality: OptionSet {
    let rawValue: Int
    static let imageOutput = Self(rawValue: 1)
    static let audioOutput = Self(rawValue: 2)
    static let videoOutput = Self(rawValue: 4)
    static let textOutput = Self(rawValue: 8)
    static let audioInput = Self(rawValue: 16)
}
struct LLMModel {
    let id: String
    var modalityOverride: ModelModality?
    var displayName: String { id }
}
struct ProviderInstance {
    let id: String
    var isEnabled = true
    var hasAnyCredential = true
    var label: String { id }
}
struct ModelEntry {
    let id: String
    let providerInstanceId: String
    let model: LLMModel
    var isHidden = false
}
enum SessionModelSource {
    case group(groupId: String, resolvedEntryId: String)
    case directEntry(modelEntryId: String)
    var entryID: String {
        switch self {
        case .group(_, let entryID), .directEntry(let entryID): return entryID
        }
    }
}
struct SessionModelBinding {
    let sessionId: String
    let primarySource: SessionModelSource
    let subModelSource: SessionModelSource?
}
@MainActor final class ProviderConfigStore {
    static let shared = ProviderConfigStore()
    var instances: [ProviderInstance] = []
    var modelEntries: [ModelEntry] = []
    var groups: [ModelGroup] = []
    var defaultPrimaryGroupId: String?
    var defaultSubGroupId: String?
    var bindings: [String: SessionModelBinding] = [:]
    func entry(for id: String) -> ModelEntry? { modelEntries.first { $0.id == id } }
    func instance(for id: String) -> ProviderInstance? { instances.first { $0.id == id } }
    func group(for id: String) -> ModelGroup? { groups.first { $0.id == id } }
    func setBinding(_ binding: SessionModelBinding, for id: String) { bindings[id] = binding }
}
struct ChatSession { let id: String; let modelId: String }
@MainActor final class ChatStore {
    static let shared = ChatStore()
    var sessions: [ChatSession] = []
    func listSessions() async -> [ChatSession] { sessions }
    func updateSessionModelId(_ id: String, modelId: String) async {}
}
@MainActor final class AIChatViewModel {
    var initialGroupId: String?
    func applyGroupSessionDefaults(group: ModelGroup, sessionId: String,
                                   preserveThinkingLevel: Bool = false) {}
}

@main struct MeetingModelAvailabilityChecks {
    @MainActor static func main() async {
        let store = ProviderConfigStore.shared
        let provider = ProviderInstance(id: "minimax")
        let text = ModelEntry(id: "minimax/text", providerInstanceId: provider.id,
                              model: .init(id: "MiniMax-M2.5"))
        let tts = ModelEntry(id: "minimax/tts", providerInstanceId: provider.id,
                             model: .init(id: "speech-2.8-hd", modalityOverride: .audioOutput))
        let outside = ModelEntry(id: "minimax/outside", providerInstanceId: provider.id,
                                 model: .init(id: "other-chat"))
        func reset(_ entries: [ModelEntry]) {
            store.instances = [provider]
            store.modelEntries = entries
            store.groups = []
            store.defaultPrimaryGroupId = nil
            store.defaultSubGroupId = nil
            store.bindings = [:]
            ChatStore.shared.sessions = []
        }
        func setDefault(_ members: [String], strategy: RoutingStrategy = .fallback) {
            let group = ModelGroup(id: "primary", name: "Primary", memberEntryIds: members,
                                   strategy: strategy)
            store.groups = [group]
            store.defaultPrimaryGroupId = group.id
        }
        func boundEntry(_ id: String = "new-session") -> String? {
            store.bindings[id]?.primarySource.entryID
        }
        func permitted() -> Bool { MeetingAssistantController.modelUnavailableReason() == nil }

        reset([text, tts])
        precondition(permitted(), "No default group must use the same text fallback as a new chat")
        await AIChatViewModel().testCreateBinding()
        precondition(boundEntry() == text.id, "Newest TTS must not outrank an available text model")

        reset([tts])
        precondition(!permitted(), "A speech-only service cannot execute Agent tasks")
        precondition(MeetingAssistantController.modelUnavailableReason()!.contains("聊天模型"))
        await AIChatViewModel().testCreateBinding()
        precondition(boundEntry() == nil)

        for unavailable in ["disabled", "credentialless", "hidden"] {
            reset([text, tts])
            if unavailable == "disabled" { store.instances[0].isEnabled = false }
            if unavailable == "credentialless" { store.instances[0].hasAnyCredential = false }
            if unavailable == "hidden" { store.modelEntries[0].isHidden = true }
            precondition(!permitted(), "Unavailable text model was allowed: \(unavailable)")
            setDefault([text.id, tts.id])
            precondition(!permitted(), "Default group bypassed availability: \(unavailable)")
            await AIChatViewModel().testCreateBinding()
            precondition(boundEntry() == nil)
        }

        reset([text])
        store.defaultPrimaryGroupId = "deleted-group"
        precondition(permitted(), "Deleted default group must use the normal fallback")
        await AIChatViewModel().testCreateBinding()
        precondition(boundEntry() == text.id)

        reset([text, tts, outside])
        setDefault([tts.id, text.id])
        precondition(permitted())
        await AIChatViewModel().testCreateBinding()
        precondition(boundEntry() == text.id, "Text members in the default group retain priority")
        guard case .group(let groupID, _)? = store.bindings["new-session"]?.primarySource else {
            preconditionFailure("Mixed default group must retain its group binding")
        }
        precondition(groupID == "primary")

        reset([text, tts])
        setDefault([tts.id])
        precondition(permitted(), "TTS-only default group must fall back to available text elsewhere")
        await AIChatViewModel().testCreateBinding()
        precondition(boundEntry() == text.id)
        reset([tts])
        setDefault([tts.id])
        precondition(!permitted(), "A TTS-only default group must not pass the model gate")

        reset([text, tts, outside])
        setDefault([tts.id, text.id, outside.id], strategy: .loadBalance)
        for index in 0..<30 {
            let id = "load-balanced-\(index)"
            let entry = AIChatViewModel.resolveInitialPrimaryGroupEntry(
                group: store.groups[0], sessionId: id, store: store
            )
            precondition(entry?.id == text.id || entry?.id == outside.id)
            await AIChatViewModel().testCreateBinding(id)
            precondition(boundEntry(id) == entry?.id, "Gate helper must match actual initial binding")
        }

        reset([text, tts, outside])
        ChatStore.shared.sessions = [.init(id: "recent-tts", modelId: tts.model.id),
                                     .init(id: "older-chat", modelId: text.model.id)]
        await AIChatViewModel().testCreateBinding()
        precondition(boundEntry() == text.id, "Last-used TTS must not become an Agent chat binding")

        for additionalOutput in [ModelModality.audioOutput, .imageOutput, .videoOutput] {
            let multimodal = ModelEntry(
                id: "minimax/multimodal", providerInstanceId: provider.id,
                model: .init(id: "multimodal-chat", modalityOverride: [.textOutput, additionalOutput])
            )
            reset([multimodal, outside])
            setDefault([multimodal.id])
            precondition(permitted(), "Explicit text output must permit multimodal chat")
            await AIChatViewModel().testCreateBinding()
            precondition(boundEntry() == multimodal.id, "Default multimodal chat must retain group priority")
            reset([multimodal, outside])
            ChatStore.shared.sessions = [.init(id: "recent-multimodal", modelId: multimodal.model.id)]
            await AIChatViewModel().testCreateBinding()
            precondition(boundEntry() == multimodal.id, "Last-used multimodal chat must remain usable")
            reset([multimodal])
            precondition(permitted())
            await AIChatViewModel().testCreateBinding()
            precondition(boundEntry() == multimodal.id, "Latest-model fallback must allow multimodal text output")
        }
        for nonText in [ModelModality.audioOutput, .imageOutput, .videoOutput, .audioInput] {
            let entry = ModelEntry(id: "minimax/non-text", providerInstanceId: provider.id,
                                   model: .init(id: "non-chat", modalityOverride: nonText))
            reset([entry])
            setDefault([entry.id])
            precondition(!permitted(), "Explicit metadata without text output must not pass the chat gate")
            await AIChatViewModel().testCreateBinding()
            precondition(boundEntry() == nil)
        }
        print("PASS: meeting model gate, actual initial binding, defaults, TTS filtering and availability")
    }
}
