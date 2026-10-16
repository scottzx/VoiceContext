import Foundation

// The production schema, argument validation, permission sequence and
// cancellation handler are compiled unchanged; native iOS calls are faked.
enum PermissionResult { case allowed, denied(String) }
@MainActor final class OffloadPermissionManager {
    static let shared = OffloadPermissionManager()
    var denied: Set<String> = []
    var checks: [(String, String?)] = []
    var hold = false
    var pending: CheckedContinuation<PermissionResult, Never>?
    func checkPermission(for command: String, sessionId: String?, fullCommand: String) async -> PermissionResult {
        checks.append((command, sessionId))
        if hold { return await withCheckedContinuation { pending = $0 } }
        return denied.contains(command) ? .denied("denied " + command) : .allowed
    }
}
@MainActor final class MeetingAppleNativeBridge {
    static var calls: [(String, [String])] = []
    static var hold = false
    static var pending: (() -> Void)?
    static func executeCommand(_ command: String, arguments: [String], shouldExecute: @escaping () -> Bool, completion: @escaping (String, Int32) -> Void) {
        let invoke = {
            guard shouldExecute() else { completion("cancelled before dispatch", 1); return }
            calls.append((command, arguments))
            completion("native receipt", 0)
        }
        if hold { pending = invoke } else { invoke() }
    }
}

@main struct MeetingAppleNativeChecks {
    @MainActor static func main() async {
        func args(_ command: String = "apple-calendar", _ action: String = "list", _ values: [String] = []) -> [String: Any] {
            ["tool_title": "查日程", "command": command, "action": action, "arguments": values]
        }
        func invoke(_ value: [String: Any], source: String? = "meeting_assistant", sid: String? = "meeting-test") async -> (output: String, success: Bool) {
            await MeetingAppleTool.execute(value, sessionID: sid, sessionSource: source)
        }
        precondition(MeetingAppleTool.definition.name == "apple_native")
        precondition(MeetingAppleTool.definition.parameters["arguments"]?.type == .stringArray)
        let request = try! MeetingAppleTool.invocation(args("apple-calendar", "list", ["--today", "--limit", "10"]))
        precondition(request.command == "apple-calendar" && request.arguments == ["list", "--today", "--limit", "10", "--compact"])
        let literal = try! MeetingAppleTool.invocation(args("apple-reminders", "create", ["--title", "和小蓝同学讨论 '方案 A'", "--list", "工作"]))
        precondition(literal.arguments.contains("和小蓝同学讨论 '方案 A'"), "Natural text stays one native argument")
        let valid: [(String, String, [String])] = [
            ("apple-calendar", "freebusy", ["--start", "-7d"]), ("apple-calendar", "calendars", []),
            ("apple-calendar", "create", ["--title","会议","--start","2026-10-12T09:00+08:00","--end","2026-10-12T10:00+08:00"]),
            ("apple-calendar", "update", ["--id","event-id","--title","更新会议"]), ("apple-calendar", "delete", ["--id","event-id"]),
            ("apple-reminders", "list", ["--incomplete"]), ("apple-reminders", "update", ["--id","item-id","--clear-recur"]),
            ("apple-reminders", "complete", ["--id","item-id","--undo"]), ("apple-reminders", "delete", ["--id","item-id"]),
            ("apple-location", "current", ["--accuracy","near"]), ("apple-location", "geocode", ["--lat","31.2","--lng","121.4"]),
            ("apple-location", "forward", ["--address","上海"]), ("apple-maps", "search", ["--query","咖啡","--lat","31.2","--lon","121.4"]),
            ("apple-maps", "route", ["--from","上海","--to","北京"]), ("apple-maps", "eta", ["--from","上海","--to","北京"]),
            ("apple-device", "info", []), ("apple-device", "battery", []), ("apple-device", "storage", [])
        ]
        for (command, action, values) in valid { _ = try! MeetingAppleTool.invocation(args(command, action, values)) }
        for action in ["current", "hourly", "minute", "daily", "alerts", "report"] {
            _ = try! MeetingAppleTool.invocation(args("apple-weather", action, ["--lat","31.2","--lng","121.4"]))
        }
        var invalid: [[String: Any]] = [
            [:], args("/usr/local/bin/apple-calendar"), args("sh"), args("apple-speak"), args("apple-speech"), args("apple-player"), args("apple-open"),
            args("apple-calendar", "list; apple-speech"), args("apple-calendar", "remind"), args("apple-calendar", "unknown"),
            args("apple-calendar", "list", ["--today",";","apple-speech"]), args("apple-calendar", "list", ["--help"]),
            args("apple-calendar", "list", ["--today","--today"]), args("apple-calendar", "list", ["--calendar"]),
            args("apple-calendar", "list", ["--limit","101"]), args("apple-calendar", "list", ["--limit","0"]),
            args("apple-calendar", "list", ["list"]), args("apple-calendar", "create", ["--title","incomplete"]),
            args("apple-reminders", "create", ["--title","缺少列表"])
        ]
        for value in ["--help", "-q", "work\u{0}x", "$(apple-speech)", "x; apple-speech", "x | sh", "x && sh", "x\ny", "x > file"] {
            invalid.append(args("apple-calendar", "list", ["--calendar", value]))
        }
        var extra = args(); extra["command_string"] = "apple-calendar list"; invalid.append(extra)
        var nonArray = args(); nonArray["arguments"] = "--today"; invalid.append(nonArray)
        for value in invalid {
            do { _ = try MeetingAppleTool.invocation(value); preconditionFailure("Invalid arguments accepted: \(value)") }
            catch {}
            let result = await invoke(value)
            precondition(!result.success)
        }
        precondition(MeetingAppleNativeBridge.calls.isEmpty)
        for source: String? in [nil, "chat", "shortcut", "hardware", "group", "meeting_child"] {
            let result = await invoke(args(), source: source)
            precondition(!result.success)
        }
        let noSession = await invoke(args(), sid: nil)
        precondition(!noSession.success && MeetingAppleNativeBridge.calls.isEmpty)
        let permissions = OffloadPermissionManager.shared
        permissions.denied = ["apple-calendar"]
        let denied = await invoke(args())
        precondition(!denied.success && denied.output == "denied apple-calendar" && MeetingAppleNativeBridge.calls.isEmpty)
        permissions.denied = ["apple-location"]
        let weatherDenied = await invoke(args("apple-weather", "current"))
        precondition(!weatherDenied.success && weatherDenied.output == "denied apple-location" && MeetingAppleNativeBridge.calls.isEmpty)
        permissions.denied = []
        let allowed = await invoke(args())
        precondition(allowed.success && allowed.output == "native receipt" && MeetingAppleNativeBridge.calls.count == 1)
        precondition(permissions.checks.last!.1 == "meeting-test")

        // Closing a meeting while its permission sheet is awaiting an answer
        // cannot dispatch a native mutation after authorization arrives late.
        permissions.hold = true
        let lateAuth = Task { await invoke(args("apple-reminders", "complete", ["--id","item-id"])) }
        for _ in 0..<1_000 { if permissions.pending != nil { break }; await Task.yield() }
        precondition(permissions.pending != nil)
        lateAuth.cancel(); permissions.pending!.resume(returning: .allowed); permissions.pending = nil
        let lateResult = await lateAuth.value
        precondition(!lateResult.success && MeetingAppleNativeBridge.calls.count == 1)
        permissions.hold = false

        // A queued native operation also rechecks cancellation immediately
        // before invoking the existing handler.
        MeetingAppleNativeBridge.hold = true
        let queued = Task { await invoke(args("apple-calendar", "delete", ["--id","event-id"])) }
        for _ in 0..<1_000 { if MeetingAppleNativeBridge.pending != nil { break }; await Task.yield() }
        precondition(MeetingAppleNativeBridge.pending != nil)
        queued.cancel(); MeetingAppleNativeBridge.pending!(); MeetingAppleNativeBridge.pending = nil
        let queuedResult = await queued.value
        precondition(!queuedResult.success && MeetingAppleNativeBridge.calls.count == 1)
        print("Meeting native Apple checks passed: strict dispatch builder, literal tokens, six native capabilities, permissions, wrong-session denial and cancellation before dispatch")
    }
}
