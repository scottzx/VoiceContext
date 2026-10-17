import Foundation

enum AgentToolPolicy { case standalone, orchestrator }

@main
struct AppNavigationChecks {
    @MainActor
    static func main() async throws {
        AgentRuntimePolicies.register(source: "xiaolan_voice", policy: .init(requiresNavigationBinding: true))
        AgentRuntimePolicies.register(source: "third_voice", policy: .init(requiresNavigationBinding: true))
        func check(_ condition: Bool, _ message: String = "Navigation condition failed") { precondition(condition, message) }
        let center = AppNavigationCenter(timeoutNanoseconds: 80_000_000)
        center.registerSupportedRoutes(["chat", "extensions", "extension.settings", "schedule.day", "recording.detail"])
        center.setAvailability(foreground: true, unlocked: true)
        center.mount(routeID: "chat")
        let initial = center.state.revision

        func rejected(_ args: [String: Any]) {
            do { _ = try AppNavigationTool.invocation(args); preconditionFailure("Invalid navigation arguments were accepted: \(args)") }
            catch {}
        }
        for args: [String: Any] in [
            ["action": "tree", "route": "chat"],
            ["action": "get_state", "params": "{}"],
            ["action": "navigate", "route": "chat"],
            ["action": "navigate", "route": "chat", "expected_revision": true],
            ["action": "navigate", "route": "chat", "expected_revision": "1"],
            ["action": "navigate", "route": "chat", "expected_revision": 1.5],
            ["action": "navigate", "route": "chat", "expected_revision": -1],
            ["action": "navigate", "route": "chat", "expected_revision": 0, "params": "{\"unknown\":\"value\"}"],
            ["action": "navigate", "route": "schedule.day", "expected_revision": 0, "params": "{\"date\":\"2026-02-30\"}"],
            ["action": "navigate", "route": "schedule.day", "expected_revision": 0, "params": "{\"date\":\"2026-2-3\"}"],
            ["action": "navigate", "route": "tasks.list", "expected_revision": 0, "params": "{\"filter\":\"completed\"}"],
            ["action": "navigate", "route": "recording.detail", "expected_revision": 0, "params": "{\"recording_id\":\"../../private\"}"],
            ["action": "navigate", "route": "artifact.preview", "expected_revision": 0, "params": "{\"artifact_id\":\"../../private:6A97F31C-2862-4511-8A09-6C533591A5BB\"}"],
            ["action": "navigate", "route": "schedule.day", "expected_revision": 0, "params": "{\"date\":1}"],
            ["action": "navigate", "route": "nonexistent.crm", "expected_revision": 0],
            ["action": "back", "expected_revision": 0, "route": "chat"]
        ] { rejected(args) }
        _ = try AppNavigationTool.invocation(["action": "navigate", "route": "schedule.day", "expected_revision": 0,
                                              "params": "{\"date\":\"2028-02-29\"}"])
        let stale = await center.navigate(routeID: "extensions", expectedRevision: initial - 1)
        precondition(stale.status == "stale" && center.command == nil && center.state.routeID == "chat")
        let unsupported = await center.navigate(routeID: "extension.browser", expectedRevision: initial)
        precondition(unsupported.status == "unavailable" && center.command == nil)

        let first = Task { await center.navigate(routeID: "extension.settings", expectedRevision: initial) }
        await waitForCommand(center)
        let command = center.command!
        let busy = await center.navigate(routeID: "extensions", expectedRevision: initial)
        precondition(busy.status == "busy")
        center.mount(routeID: "extensions", commandID: command.id)
        precondition(center.command?.id == command.id && center.state.routeID == "chat", "Intermediate root must not acknowledge a deeper destination")
        center.unmount(routeID: "chat")
        precondition(center.state.routeID == nil && center.command?.id == command.id, "Disappeared page cannot remain reported as visible")
        center.mount(routeID: "extension.settings", canGoBack: true, commandID: command.id)
        let appeared = await first.value
        precondition(appeared.success && appeared.status == "visible" && appeared.state.routeID == "extension.settings")

        let returning = Task { await center.back(expectedRevision: center.state.revision) }
        await waitForCommand(center)
        let returnCommand = center.command!
        center.mount(routeID: "extension.settings", canGoBack: true, commandID: returnCommand.id)
        precondition(center.command != nil, "The original page appearing again is not a successful back")
        center.mount(routeID: "extensions", commandID: returnCommand.id)
        check(await returning.value.success)
        check(await center.back(expectedRevision: center.state.revision).status == "at_root")

        center.bindVoiceSession(sessionID: "voice", generation: 1)
        let voice = Task { await center.navigate(routeID: "chat", expectedRevision: center.state.revision, sessionID: "voice", voiceGeneration: 1) }
        await waitForCommand(center)
        let old = center.command!
        center.invalidateVoiceSession()
        check(await voice.value.status == "stale")
        center.bindVoiceSession(sessionID: "voice", generation: 2)
        check(await center.navigate(routeID: "chat", expectedRevision: center.state.revision, sessionID: "voice", voiceGeneration: 1).status == "stale")
        center.mount(routeID: "chat", commandID: old.id)
        precondition(center.state.routeID == "extensions", "Late mounted callback cannot revive a cancelled request")
        center.userNavigationBegan()
        precondition(!center.isVoiceBindingCurrent(sessionID: "voice", generation: 2))

        let id = UUID()
        let lowerID = id.uuidString.lowercased()
        let recording = Task { await center.navigate(routeID: "recording.detail", params: ["recording_id": lowerID], expectedRevision: center.state.revision) }
        await waitForCommand(center)
        precondition(center.command!.params["recording_id"] == id.uuidString)
        center.mount(routeID: "recording.detail", params: ["recording_id": id.uuidString], canGoBack: true)
        check(await recording.value.success)

        let absent = Task { await center.navigate(routeID: "chat", expectedRevision: center.state.revision) }
        await waitForCommand(center)
        let absentID = center.command!.id
        center.unmount(routeID: "recording.detail", params: ["recording_id": id.uuidString])
        check(await absent.value.status == "failed", "A requested route is not visible until its adapter confirms it")
        center.mount(routeID: "chat", commandID: absentID)
        precondition(center.state.routeID == nil)

        center.mount(routeID: "extensions")
        let cancelled = Task { await center.navigate(routeID: "chat", expectedRevision: center.state.revision) }
        await waitForCommand(center)
        cancelled.cancel()
        check(await cancelled.value.status == "stale" && center.command == nil)
        center.setAvailability(foreground: false, unlocked: true)
        check(await center.navigate(routeID: "chat", expectedRevision: center.state.revision).status == "unavailable")
        center.setAvailability(foreground: true, unlocked: false)
        check(await center.navigate(routeID: "chat", expectedRevision: center.state.revision).status == "unavailable")

        let shared = AppNavigationCenter.shared
        shared.registerSupportedRoutes(["chat", "extensions"])
        shared.setAvailability(foreground: true, unlocked: true)
        shared.mount(routeID: "chat")
        let executor = await AppNavigationTool.execute(["action": "get_state"], sessionID: "child", sessionSource: "subagent", isExecutor: true, voiceGeneration: nil)
        precondition(!executor.success && executor.output.contains("forbidden"))
        let relay = await AppNavigationTool.execute(["action": "get_state"], sessionID: "yima", sessionSource: "agent-relay", isExecutor: false, voiceGeneration: nil, blocksAppUI: true)
        precondition(!relay.success && relay.output.contains("forbidden"), "A trusted Xiaolan relay cannot directly acquire device navigation")
        let tree = await AppNavigationTool.execute(["action": "tree"], sessionID: "main", sessionSource: "chat", isExecutor: false, voiceGeneration: nil)
        let treeJSON = try JSONSerialization.jsonObject(with: Data(tree.output.utf8)) as! [String: Any]
        let routes = (treeJSON["routes"] as! [[String: Any]]).compactMap { $0["route"] as? String }
        precondition(Set(routes) == ["chat", "extensions"], "Never advertise routes whose UI is not installed")
        shared.registerSupportedRoutes(["extension.custom"])
        let custom = CustomExtensionItem(name: "项目看板", url: URL(string: "http://localhost:3000/private?token=secret")!, logoData: Data("private logo".utf8))
        let customTree = AppNavigationTool.routeTree(center: shared, customItems: [custom])
        let customRoute = customTree.first(where: { $0["route"] as? String == "extension.custom" })!
        let customOptions = customRoute["destinations"] as! [[String: String]]
        precondition(customOptions == [["id": custom.id.uuidString, "title": "项目看板"]], "Route options expose actual shortcut IDs/titles without private URLs or logos")
        let foreign = await AppNavigationTool.execute(["action": "navigate", "route": "artifact.preview", "params": "{\"artifact_id\":\"other:\(UUID().uuidString)\"}", "expected_revision": shared.state.revision], sessionID: "main", sessionSource: "chat", isExecutor: false, voiceGeneration: nil)
        precondition(!foreign.success && foreign.output.contains("forbidden"))
        let oldVoice = await AppNavigationTool.execute(["action": "get_state"], sessionID: "voice", sessionSource: "xiaolan_voice", isExecutor: false, voiceGeneration: 9)
        precondition(!oldVoice.success && oldVoice.output.contains("stale"))
        let thirdStale = await AppNavigationTool.execute(["action": "get_state"], sessionID: "third", sessionSource: "third_voice", isExecutor: false, voiceGeneration: 1)
        precondition(!thirdStale.success && thirdStale.output.contains("stale"))
        shared.bindVoiceSession(sessionID: "third", generation: 2)
        let thirdCurrent = await AppNavigationTool.execute(["action": "get_state"], sessionID: "third", sessionSource: "third_voice", isExecutor: false, voiceGeneration: 2)
        precondition(thirdCurrent.success, "A third configured adapter receives identical live-generation enforcement")
        print("PASS: actual app routes validate parameters, mounted receipts, revision/generation, cancellation, deadline, native back, foreground/lock, executor policy and session-owned artifacts")
    }

    @MainActor
    private static func waitForCommand(_ center: AppNavigationCenter) async {
        for _ in 0..<10_000 {
            if center.command != nil { return }
            await Task.yield()
        }
        preconditionFailure("Navigation command was not published")
    }
}
