import Foundation
import Combine

struct AppRouteDescriptor {
    let id: String
    let title: String
    let parent: String?
    var parameters: [String: [String]] = [:]

    var dictionary: [String: Any] {
        var value: [String: Any] = ["route": id, "title": title, "parameters": parameters]
        if let parent { value["parent"] = parent }
        return value
    }
}

/// Only routes with a mounted UI adapter are advertised. Parameter validation
/// happens before publishing a command, independently of the model's schema.
enum AppRouteCatalog {
    static let descriptors: [AppRouteDescriptor] = [
        .init(id: "chat", title: "聊天", parent: nil),
        .init(id: "chat.session", title: "对话", parent: "chat", parameters: ["session_id": ["id"]]),
        .init(id: "recordings.list", title: "记录", parent: nil),
        .init(id: "recording.detail", title: "录音详情", parent: "recordings.list", parameters: ["recording_id": ["uuid"]]),
        .init(id: "reminders", title: "提醒", parent: nil),
        .init(id: "reminders.all", title: "全部事项", parent: "reminders"),
        .init(id: "schedule.day", title: "某天日程", parent: "reminders", parameters: ["date": ["yyyy-MM-dd"]]),
        .init(id: "tasks.list", title: "待办", parent: "reminders", parameters: ["filter": ["incomplete", "all"]]),
        .init(id: "extensions", title: "拓展", parent: nil),
        .init(id: "extension.settings", title: "设置", parent: "extensions"),
        .init(id: "extension.skills", title: "技能", parent: "extensions"),
        .init(id: "extension.models", title: "模型与服务", parent: "extensions"),
        .init(id: "extension.soul", title: "助手设定", parent: "extensions"),
        .init(id: "extension.memory", title: "记忆", parent: "extensions"),
        .init(id: "extension.mcp", title: "工具连接", parent: "extensions"),
        .init(id: "extension.hardware", title: "硬件设备", parent: "extensions"),
        .init(id: "extension.terminal", title: "终端", parent: "extensions"),
        .init(id: "extension.browser", title: "浏览器", parent: "extensions"),
        .init(id: "extension.custom_functions", title: "管理自定义功能", parent: "extensions"),
        .init(id: "extension.custom", title: "自定义功能", parent: "extensions", parameters: ["id": ["uuid"]]),
        .init(id: "artifact.preview", title: "内容预览", parent: "chat", parameters: ["artifact_id": ["session_id:artifact_uuid"]])
    ]

    static func validate(routeID: String, params: [String: String]) -> String? {
        guard let route = descriptors.first(where: { $0.id == routeID }) else { return "Unknown app route." }
        guard Set(params.keys) == Set(route.parameters.keys) else { return "Pass exactly the parameters declared by this route." }
        for (key, allowed) in route.parameters {
            guard let value = params[key], !value.isEmpty, value.count <= 256,
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return "Invalid route parameter: \(key)." }
            if allowed == ["uuid"] {
                guard UUID(uuidString: value) != nil else { return "\(key) must be a real UUID from an existing item." }
            } else if allowed == ["session_id:artifact_uuid"] {
                let parts = value.split(separator: ":", omittingEmptySubsequences: false)
                guard parts.count == 2, parts[0].range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
                      UUID(uuidString: String(parts[1])) != nil else { return "artifact_id must be an existing opaque ID returned by app_present." }
            } else if allowed == ["id"] {
                guard value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return "Invalid item ID." }
            } else if allowed == ["yyyy-MM-dd"] {
                let format = DateFormatter()
                format.calendar = Calendar(identifier: .gregorian)
                format.locale = Locale(identifier: "en_US_POSIX")
                format.timeZone = .current
                format.dateFormat = "yyyy-MM-dd"
                format.isLenient = false
                guard value.count == 10, let date = format.date(from: value), format.string(from: date) == value else { return "date must be a real local date in yyyy-MM-dd format." }
            } else if !allowed.contains(value) { return "Unsupported value for \(key)." }
        }
        return nil
    }

    static func normalized(routeID: String, params: [String: String]) -> [String: String] {
        guard let route = descriptors.first(where: { $0.id == routeID }) else { return params }
        var values = params
        for (key, kind) in route.parameters where kind == ["uuid"] {
            if let raw = values[key], let id = UUID(uuidString: raw) { values[key] = id.uuidString }
        }
        if routeID == "artifact.preview", let raw = values["artifact_id"], let divider = raw.firstIndex(of: ":"),
           let id = UUID(uuidString: String(raw[raw.index(after: divider)...])) {
            values["artifact_id"] = String(raw[..<divider]) + ":" + id.uuidString
        }
        return values
    }
}

enum AppNavigationAction: String { case navigate, back }

struct AppNavigationCommand: Identifiable, Equatable {
    let id: UUID
    let action: AppNavigationAction
    let routeID: String
    let params: [String: String]
    let revision: Int
}

struct AppNavigationState: Equatable {
    var routeID: String?
    var params: [String: String] = [:]
    var revision = 0
    var canGoBack = false

    var dictionary: [String: Any] {
        ["route": routeID as Any? ?? NSNull(), "params": params,
         "revision": revision, "can_go_back": canGoBack]
    }
}

struct AppNavigationReceipt {
    let status: String
    let message: String
    let state: AppNavigationState
    var success: Bool { status == "visible" }
    var dictionary: [String: Any] { ["status": status, "message": message, "state": state.dictionary] }
}

@MainActor
final class AppNavigationCenter: ObservableObject {
    static let shared = AppNavigationCenter()
    @Published private(set) var command: AppNavigationCommand?
    @Published private(set) var state = AppNavigationState()
    private(set) var supportedRoutes: Set<String> = []
    private var foreground = false
    private var unlocked = false
    private var voiceBinding: (sessionID: String, generation: UInt64)?
    private var continuation: CheckedContinuation<AppNavigationReceipt, Never>?
    private var pendingVoiceGeneration: UInt64?
    private var timeout: Task<Void, Never>?
    private let timeoutNanoseconds: UInt64

    init(timeoutNanoseconds: UInt64 = 5_000_000_000) { self.timeoutNanoseconds = timeoutNanoseconds }

    var available: Bool { foreground && unlocked }

    func registerSupportedRoutes(_ routes: Set<String>) {
        supportedRoutes.formUnion(routes.intersection(Set(AppRouteCatalog.descriptors.map(\.id))))
    }

    func setAvailability(foreground: Bool, unlocked: Bool) {
        let wasAvailable = available
        self.foreground = foreground
        self.unlocked = unlocked
        if wasAvailable && !available {
            state.revision += 1
            invalidateVoiceSession()
            finish(status: "unavailable", message: "App navigation requires the foreground, unlocked app.")
        }
    }

    func bindVoiceSession(sessionID: String, generation: UInt64) {
        if let binding = voiceBinding, binding.sessionID == sessionID && binding.generation == generation { return }
        invalidateVoiceSession()
        voiceBinding = (sessionID, generation)
    }

    func invalidateVoiceSession() {
        voiceBinding = nil
        if pendingVoiceGeneration != nil { finish(status: "stale", message: "This voice request is no longer active.") }
    }

    func voiceGeneration(sessionID: String?) -> UInt64? {
        guard let sessionID, available, voiceBinding?.sessionID == sessionID else { return nil }
        return voiceBinding?.generation
    }

    func isVoiceBindingCurrent(sessionID: String?, generation: UInt64?) -> Bool {
        guard let generation else { return false }
        return voiceGeneration(sessionID: sessionID) == generation
    }

    func isCurrent(_ value: AppNavigationCommand) -> Bool { available && command?.id == value.id }

    /// Explicit user actions cancel pending assistant work before changing UI.
    func userNavigationBegan() {
        state.revision += 1
        invalidateVoiceSession()
        finish(status: "stale", message: "The user changed the page. Do not force the previous destination.")
    }

    /// Called by actual visible destinations, never merely after selecting a tab.
    func mount(routeID: String, params: [String: String] = [:], canGoBack: Bool = false, commandID: UUID? = nil) {
        guard available, supportedRoutes.contains(routeID), AppRouteCatalog.validate(routeID: routeID, params: params) == nil else { return }
        let params = AppRouteCatalog.normalized(routeID: routeID, params: params)
        if let pending = command {
            guard commandID == nil || commandID == pending.id else { return }
            if pending.action == .navigate {
                guard pending.routeID == routeID, pending.params == params else { return }
            } else {
                guard pending.routeID != routeID || pending.params != params else { return }
            }
            state = .init(routeID: routeID, params: params, revision: state.revision + 1, canGoBack: canGoBack)
            finish(status: "visible", message: "The requested page is mounted and visible.")
        } else {
            guard commandID == nil else { return }
            if state.routeID != routeID || state.params != params || state.canGoBack != canGoBack {
                if state.routeID != nil, state.routeID != routeID || state.params != params { invalidateVoiceSession() }
                state = .init(routeID: routeID, params: params, revision: state.revision + 1, canGoBack: canGoBack)
            }
        }
    }

    func unmount(routeID: String, params: [String: String] = [:]) {
        guard state.routeID == routeID, state.params == AppRouteCatalog.normalized(routeID: routeID, params: params) else { return }
        if command == nil { invalidateVoiceSession() }
        state = .init(routeID: nil, revision: state.revision + 1)
    }

    func fail(commandID: UUID, message: String) {
        guard command?.id == commandID else { return }
        finish(status: "failed", message: message)
    }

    func navigate(routeID: String, params: [String: String] = [:], expectedRevision: Int,
                  sessionID: String? = nil, voiceGeneration: UInt64? = nil) async -> AppNavigationReceipt {
        if let error = AppRouteCatalog.validate(routeID: routeID, params: params) { return receipt("invalid_arguments", error) }
        guard supportedRoutes.contains(routeID) else { return receipt("unavailable", "This route has no installed app navigation adapter.") }
        return await submit(action: .navigate, routeID: routeID, params: AppRouteCatalog.normalized(routeID: routeID, params: params), expectedRevision: expectedRevision,
                            sessionID: sessionID, voiceGeneration: voiceGeneration)
    }

    func back(expectedRevision: Int, sessionID: String? = nil, voiceGeneration: UInt64? = nil) async -> AppNavigationReceipt {
        guard state.canGoBack, let routeID = state.routeID else { return receipt("at_root", "The current page has no registered native return action.") }
        return await submit(action: .back, routeID: routeID, params: state.params, expectedRevision: expectedRevision,
                            sessionID: sessionID, voiceGeneration: voiceGeneration)
    }

    private func submit(action: AppNavigationAction, routeID: String, params: [String: String], expectedRevision: Int,
                        sessionID: String?, voiceGeneration: UInt64?) async -> AppNavigationReceipt {
        guard !Task.isCancelled else { return receipt("stale", "This request was cancelled.") }
        guard available else { return receipt("unavailable", "App navigation requires the foreground, unlocked app.") }
        if sessionID != nil || voiceGeneration != nil {
            guard isVoiceBindingCurrent(sessionID: sessionID, generation: voiceGeneration) else { return receipt("stale", "This voice request is no longer active.") }
        }
        guard expectedRevision == state.revision else { return receipt("stale", "The current page changed. Read get_state before another navigation request.") }
        guard command == nil else { return receipt("busy", "Another page transition is awaiting its visible destination.") }
        if action == .navigate, state.routeID == routeID, state.params == params { return receipt("visible", "This page is already mounted and visible.") }
        let value = AppNavigationCommand(id: UUID(), action: action, routeID: routeID, params: params, revision: state.revision)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                pendingVoiceGeneration = voiceGeneration
                timeout = Task { [weak self] in
                    guard let self else { return }
                    do { try await Task.sleep(nanoseconds: timeoutNanoseconds) } catch { return }
                    guard command?.id == value.id else { return }
                    finish(status: "failed", message: "The destination did not report a visible page before the navigation deadline.")
                }
                command = value
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.command?.id == value.id else { return }
                self?.finish(status: "stale", message: "This navigation request was cancelled.")
            }
        }
    }

    private func receipt(_ status: String, _ message: String) -> AppNavigationReceipt { .init(status: status, message: message, state: state) }

    private func finish(status: String, message: String) {
        let result = receipt(status, message)
        let waiting = continuation
        continuation = nil
        timeout?.cancel()
        timeout = nil
        pendingVoiceGeneration = nil
        command = nil
        waiting?.resume(returning: result)
    }
}
