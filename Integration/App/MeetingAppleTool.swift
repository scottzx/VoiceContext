import Foundation

/// Structured access to existing Apple handlers. No command enters a shell.
@MainActor
enum MeetingAppleTool {
    static let definition = AgentToolDefinition(
        name: "apple_native",
        description: "Use Apple system calendar/reminders, location, maps, weather or device information directly during the meeting. Commands/actions: apple-calendar list/freebusy/calendars/create/update/delete; apple-reminders list/create/update/complete/delete; apple-location current/geocode/forward; apple-maps search/route/eta; apple-weather current/hourly/minute/daily/alerts/report; apple-device info/battery/storage. Preserve user permissions. Query before changing existing items; only mutate a specifically authorized item. Use exact IDs/list names from results and verified dates. A reminder due date alone is not an alarm. No terminal, browser, URL opening, microphone, audio playback or speech synthesis. Speak to the user only with answer_user.",
        parameters: [
            "tool_title": AgentToolParam(type: .string, description: "Short action summary in the user's language"),
            "command": AgentToolParam(type: .string, description: "Native Apple capability", enumValues: ["apple-calendar", "apple-reminders", "apple-location", "apple-maps", "apple-weather", "apple-device"]),
            "action": AgentToolParam(type: .string, description: "One supported action for the selected command"),
            "arguments": AgentToolParam(type: .stringArray, description: "Literal native options as separate tokens, e.g. [\"--today\",\"--limit\",\"10\"], or [\"--title\",\"Review\",\"--list\",\"Work\"]. No command/action token or shell syntax. Calendar accepts --start/--end/--calendar/--title/--id/--notes; reminders --list/--title/--id/--due/--completed/--incomplete/--undo; location --accuracy or --lat/--lng or --address; maps --query/--lat/--lon/--radius/--limit or --from/--to/--mode; weather --lat/--lng/--hours/--minutes/--days. Unsupported options fail before execution.")
        ],
        required: ["tool_title", "command", "action"]
    )

    struct Invocation: Sendable {
        let command: String
        let arguments: [String]
        let permissions: [String]
    }

    private struct Options {
        var values: Set<String>
        var flags: Set<String> = []
        var required: Set<String> = []
    }

    private static let recurrence: Set<String> = ["--recur", "--recur-interval", "--recur-days", "--recur-until", "--recur-count"]
    private static let reminderValues: Set<String> = ["--title", "--due", "--list", "--priority", "--notes", "--lat", "--lng", "--location-name", "--radius", "--proximity"]

    private static func options(command: String, action: String) -> Options? {
        switch (command, action) {
        case ("apple-calendar", "list"), ("apple-calendar", "freebusy"):
            return Options(values: ["--start", "--end", "--days", "--limit", "--calendar"], flags: ["--today"])
        case ("apple-calendar", "calendars"), ("apple-device", "info"), ("apple-device", "battery"), ("apple-device", "storage"):
            return Options(values: [])
        case ("apple-calendar", "create"):
            return Options(values: Set(["--title", "--start", "--end", "--calendar", "--location", "--notes", "--alarm"]).union(recurrence), required: ["--title", "--start", "--end"])
        case ("apple-calendar", "update"):
            return Options(values: ["--id", "--title", "--start", "--end", "--calendar", "--location", "--notes", "--alarm", "--occurrence-date", "--span"], required: ["--id"])
        case ("apple-calendar", "delete"):
            return Options(values: ["--id", "--occurrence-date", "--span"], required: ["--id"])
        case ("apple-reminders", "list"):
            return Options(values: ["--list", "--limit"], flags: ["--completed", "--incomplete"])
        case ("apple-reminders", "create"):
            return Options(values: reminderValues.union(recurrence), required: ["--title", "--list"])
        case ("apple-reminders", "update"):
            return Options(values: reminderValues.union(recurrence).union(["--id"]), flags: ["--clear-recur", "--clear-location"], required: ["--id"])
        case ("apple-reminders", "complete"):
            return Options(values: ["--id"], flags: ["--undo"], required: ["--id"])
        case ("apple-reminders", "delete"):
            return Options(values: ["--id"], required: ["--id"])
        case ("apple-location", "current"):
            return Options(values: ["--accuracy"])
        case ("apple-location", "geocode"):
            return Options(values: ["--lat", "--lng"], required: ["--lat", "--lng"])
        case ("apple-location", "forward"):
            return Options(values: ["--address"], required: ["--address"])
        case ("apple-maps", "search"):
            return Options(values: ["--query", "--lat", "--lon", "--radius", "--limit"], required: ["--query", "--lat", "--lon"])
        case ("apple-maps", "route"), ("apple-maps", "eta"):
            return Options(values: ["--from", "--to", "--mode"], required: ["--from", "--to"])
        case ("apple-weather", "current"), ("apple-weather", "hourly"), ("apple-weather", "minute"), ("apple-weather", "daily"), ("apple-weather", "alerts"), ("apple-weather", "report"):
            return Options(values: ["--lat", "--lng", "--hours", "--minutes", "--days"])
        default:
            return nil
        }
    }

    static func invocation(_ args: [String: Any]) throws -> Invocation {
        func invalid(_ detail: String) -> NSError {
            NSError(domain: "Yima.MeetingApple", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid native Apple arguments: " + detail])
        }
        guard Set(args.keys).isSubset(of: ["tool_title", "command", "action", "arguments"]),
              let title = args["tool_title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 120,
              let command = args["command"] as? String, let action = args["action"] as? String,
              let rule = options(command: command, action: action) else { throw invalid("unsupported command/action or missing title") }
        let raw = args["arguments"] ?? [String]()
        guard let arguments = raw as? [String], arguments.count <= 64,
              arguments.reduce(0, { $0 + $1.utf8.count }) <= 16_384 else { throw invalid("arguments must be a bounded string array") }
        var seen: Set<String> = []
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard !seen.contains(flag), rule.values.contains(flag) || rule.flags.contains(flag) || flag == "--compact" else {
                throw invalid("unsupported or repeated option: " + flag)
            }
            seen.insert(flag)
            index += 1
            if rule.values.contains(flag) {
                guard index < arguments.count else { throw invalid("missing value for " + flag) }
                let value = arguments[index]
                guard !value.isEmpty, value.count <= 2_000, !value.hasPrefix("--"), value != "-h", value != "-q",
                      !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                      ![";", "|", "<", ">", "`", "$(", "${", "&&"].contains(where: value.contains), value != "&" else {
                    throw invalid("option value contains shell syntax, control characters or another option")
                }
                if flag == "--limit" {
                    guard let limit = Int(value), (1...100).contains(limit) else { throw invalid("--limit must be between 1 and 100") }
                }
                index += 1
            }
        }
        guard rule.required.isSubset(of: seen) else { throw invalid("missing required options") }
        var permissions = [command]
        if (command == "apple-weather" && !(seen.contains("--lat") && seen.contains("--lng"))) ||
            (command == "apple-reminders" && (seen.contains("--lat") || seen.contains("--lng"))) {
            permissions.append("apple-location")
        }
        return Invocation(command: command, arguments: [action] + arguments + (seen.contains("--compact") ? [] : ["--compact"]), permissions: permissions)
    }

    static func execute(_ args: [String: Any], sessionID: String?, sessionSource: String?) async -> (output: String, success: Bool) {
        guard sessionSource == "meeting_assistant", let sessionID, !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ("Native Apple tools require an active meeting assistant session.", false)
        }
        do {
            let request = try invocation(args)
            for command in request.permissions {
                guard !Task.isCancelled else { return ("Meeting request cancelled; nothing executed.", false) }
                let result = await OffloadPermissionManager.shared.checkPermission(for: command, sessionId: sessionID, fullCommand: ([request.command] + request.arguments).joined(separator: " "))
                if case .denied(let reason) = result { return (reason, false) }
            }
            guard !Task.isCancelled else { return ("Meeting request cancelled; nothing executed.", false) }
            let cancellation = MeetingAppleCancellation()
            let result: (output: String, success: Bool) = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    MeetingAppleNativeBridge.executeCommand(request.command, arguments: request.arguments, shouldExecute: { !cancellation.isCancelled }) { output, exitCode in
                        continuation.resume(returning: (output, exitCode == 0))
                    }
                }
            } onCancel: {
                cancellation.cancel()
            }
            if Task.isCancelled {
                return ("Meeting request cancelled. A native operation already started may have completed; check its result before repeating a mutation.", false)
            }
            return result
        } catch { return (error.localizedDescription, false) }
    }
}

nonisolated private final class MeetingAppleCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
