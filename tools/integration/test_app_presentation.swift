import Foundation

enum AgentToolPolicy { case standalone, orchestrator }

// Only platform/session surroundings are replaced. The production tool,
// artifact validation, source checks and persistent store compile unchanged.
@MainActor final class ChatStore {
    struct Session { let parentSessionId: String? }
    static let shared = ChatStore()
    var sessions: [String: Session] = [:]
    func getSession(_ id: String) async -> Session? { sessions[id] }
}

@MainActor final class AIChatViewModel {
    static var fixtureRoot = FileManager.default.temporaryDirectory
    static func minisWorkspacePersistentDir(for id: String) -> URL {
        fixtureRoot.appendingPathComponent(id).appendingPathComponent("workspace")
    }
}

struct AppNavigationReceipt {
    let status: String
    let state: [String: Any]
    var success: Bool { status == "visible" }
    var dictionary: [String: Any] { ["status": status, "state": state] }
}

@MainActor final class AppNavigationCenter {
    struct Request {
        let routeID: String
        let params: [String: String]
        let revision: Int
        let sessionID: String?
        let generation: UInt64?
    }
    static let shared = AppNavigationCenter()
    var revision = 7
    var route = "extensions"
    var requests: [Request] = []
    var voiceSessionID: String?
    var voiceGeneration: UInt64?
    var mounted = true
    func isVoiceBindingCurrent(sessionID: String?, generation: UInt64?) -> Bool {
        sessionID != nil && sessionID == voiceSessionID && generation != nil && generation == voiceGeneration
    }
    func navigate(routeID: String, params: [String: String], expectedRevision: Int,
                  sessionID: String? = nil, voiceGeneration: UInt64? = nil) async -> AppNavigationReceipt {
        requests.append(.init(routeID: routeID, params: params, revision: expectedRevision, sessionID: sessionID, generation: voiceGeneration))
        let status = expectedRevision != revision ? "stale" : mounted ? "visible" : "failed"
        if status == "visible" { route = routeID; revision += 1 }
        return .init(status: status, state: ["route": route, "revision": revision])
    }
}

@main
struct AppPresentationChecks {
    @MainActor static func main() async throws {
        AgentRuntimePolicies.register(source: "xiaolan_voice", policy: .init(requiresNavigationBinding: true))
        AgentRuntimePolicies.register(source: "third_voice", policy: .init(requiresNavigationBinding: true))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Yima.AppPresentationChecks.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        AIChatViewModel.fixtureRoot = root
        let sessions = ChatStore.shared
        sessions.sessions = ["main": .init(parentSessionId: nil), "child": .init(parentSessionId: "main"),
                             "other": .init(parentSessionId: nil), "unrelated-child": .init(parentSessionId: "other")]
        let navigation = AppNavigationCenter.shared
        let store = AppArtifactStore.shared
        let fileManager = FileManager.default
        for id in sessions.sessions.keys {
            try fileManager.createDirectory(at: AIChatViewModel.minisWorkspacePersistentDir(for: id), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: root.appendingPathComponent(id).appendingPathComponent("attachments"), withIntermediateDirectories: true)
        }
        func manifests() -> [URL] {
            guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
            return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "json" && $0.deletingLastPathComponent().lastPathComponent == "AppPresentations" }
        }
        func textArgs(_ text: String = "已经核对的结论") -> [String: Any] {
            ["type": "text", "title": "结果", "text": text, "expected_revision": navigation.revision]
        }
        func execute(_ args: [String: Any], source: String = "chat", generation: UInt64? = nil, sessionID: String? = "main") async -> (body: [String: Any], success: Bool) {
            let result = await AppPresentationTool.execute(args, sessionID: sessionID, sessionSource: source, voiceGeneration: generation)
            let body = try! JSONSerialization.jsonObject(with: Data(result.output.utf8)) as! [String: Any]
            return (body, result.success)
        }
        func rejected(_ args: [String: Any]) async {
            let beforeFiles = manifests().count, beforeRequests = navigation.requests.count
            let result = await execute(args)
            precondition(!result.success && result.body["status"] as? String == "failed")
            precondition(manifests().count == beforeFiles && navigation.requests.count == beforeRequests,
                         "Rejected typed payloads must neither save a manifest nor navigate")
        }
        var badValues: [[String: Any]] = [[:]]
        for (key, value): (String, Any) in [
            ("type", 1), ("type", "video"), ("title", 2), ("title", "  "),
            ("text", 42), ("text", NSNull()), ("text", "   "),
            ("expected_revision", true), ("expected_revision", "7"), ("expected_revision", -1),
            ("expected_revision", 0.5), ("expected_revision", Double.nan),
            ("source_session_id", 7), ("source_session_id", NSNull()), ("unexpected", "value"),
            ("path", 7), ("path", NSNull()), ("chart_json", false),
            ("title", String(repeating: "字", count: 161)), ("text", String(repeating: "字", count: 50_001))
        ] {
            var args = textArgs(); args[key] = value; badValues.append(args)
        }
        badValues.append(["type": "chart", "title": "图", "text": "wrong payload", "expected_revision": navigation.revision])
        badValues.append(["type": "html", "title": "网页", "path": 7, "expected_revision": navigation.revision])
        badValues.append(["type": "image", "title": "图片", "path": "attachments/missing.png", "text": NSNull(), "expected_revision": navigation.revision])
        for args in badValues { await rejected(args) }

        let visible = await execute(textArgs())
        precondition(visible.success && visible.body["status"] as? String == "visible" && visible.body["saved"] as? Bool == true)
        let textID = visible.body["artifact_id"] as! String
        let persisted = try store.load(id: textID)
        precondition(persisted.kind == .text && persisted.text == "已经核对的结论" && persisted.sessionID == "main")
        try await store.validateSource(persisted)
        precondition(navigation.requests.last!.routeID == "artifact.preview" && navigation.requests.last!.params["artifact_id"] == textID)

        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jQxcAAAAASUVORK5CYII=")!
        try png.write(to: root.appendingPathComponent("main/attachments/pixel.png"))
        let image = await execute(["type": "image", "title": "图片", "path": "minis://attachments/pixel.png", "expected_revision": navigation.revision])
        precondition(image.success)
        let imageArtifact = try store.load(id: image.body["artifact_id"] as! String)
        precondition(imageArtifact.kind == .image && imageArtifact.file?.bucket == "attachments")
        try Data("not an image".utf8).write(to: root.appendingPathComponent("main/attachments/broken.png"))
        await rejected(["type": "image", "title": "损坏图片", "path": "attachments/broken.png", "expected_revision": navigation.revision])

        let chartJSON = "{\"kind\":\"line\",\"unit\":\"次\",\"source\":\"用户提供的数据\",\"points\":[{\"label\":\"周一\",\"value\":2},{\"label\":\"周二\",\"value\":5}]}"
        let chart = await execute(["type": "chart", "title": "统计", "chart_json": chartJSON, "expected_revision": navigation.revision])
        precondition(chart.success)
        let chartArtifact = try store.load(id: chart.body["artifact_id"] as! String)
        precondition(chartArtifact.chart?.points.count == 2 && chartArtifact.chart?.kind == "line")
        for invalidChart in [chartJSON.replacingOccurrences(of: "line", with: "pie"),
                             chartJSON.replacingOccurrences(of: "周二", with: "周一"),
                             chartJSON.replacingOccurrences(of: "用户提供的数据", with: ""),
                             chartJSON.replacingOccurrences(of: "\"value\":2", with: "\"value\":\"2\"")] {
            await rejected(["type": "chart", "title": "统计", "chart_json": invalidChart, "expected_revision": navigation.revision])
        }

        let childHTML = root.appendingPathComponent("child/workspace/report.html")
        try "<!doctype html><title>已验证报告</title><p>测试内容</p>".write(to: childHTML, atomically: true, encoding: .utf8)
        try Data([0xff, 0xfe, 0xff]).write(to: root.appendingPathComponent("child/workspace/invalid.html"))
        await rejected(["type": "html", "title": "编码错误", "path": "workspace/invalid.html", "source_session_id": "child", "expected_revision": navigation.revision])
        let htmlArgs: [String: Any] = ["type": "html", "title": "报告", "path": "workspace/report.html", "source_session_id": "child", "expected_revision": navigation.revision]
        let html = await execute(htmlArgs)
        precondition(html.success)
        let htmlArtifact = try store.load(id: html.body["artifact_id"] as! String)
        precondition(htmlArtifact.sessionID == "main" && htmlArtifact.sourceSessionID == "child")
        let resolvedHTML = try store.fileURL(for: htmlArtifact)
        precondition(resolvedHTML == childHTML)
        try await store.validateSource(htmlArtifact)
        for source in ["other", "unrelated-child", "missing"] {
            var args = htmlArgs; args["source_session_id"] = source; args["expected_revision"] = navigation.revision
            await rejected(args)
        }
        sessions.sessions["child"] = .init(parentSessionId: "other")
        do { try await store.validateSource(try store.load(id: htmlArtifact.id)); preconditionFailure("Reopening a reparented child artifact must fail ownership validation") }
        catch {}
        sessions.sessions.removeValue(forKey: "main")
        do { try await store.validateSource(try store.load(id: textID)); preconditionFailure("Deleted owning sessions must invalidate a reopened artifact") }
        catch {}
        sessions.sessions["main"] = .init(parentSessionId: nil)
        sessions.sessions["child"] = .init(parentSessionId: "main")

        let beforeStaleFiles = manifests().count, beforeStaleNavigation = navigation.requests.count
        navigation.voiceSessionID = "main"; navigation.voiceGeneration = 2
        let staleVoice = await execute(textArgs(), source: "xiaolan_voice", generation: 1)
        precondition(!staleVoice.success && staleVoice.body["status"] as? String == "stale")
        precondition(manifests().count == beforeStaleFiles && navigation.requests.count == beforeStaleNavigation,
                     "An old voice generation cannot save content or navigate")

        let thirdStale = await execute(textArgs(), source: "third_voice", generation: 1)
        precondition(!thirdStale.success && thirdStale.body["status"] as? String == "stale")
        precondition(manifests().count == beforeStaleFiles && navigation.requests.count == beforeStaleNavigation,
                     "Third-party source policy receives the same generation guard")
        var staleArgs = textArgs(); staleArgs["expected_revision"] = navigation.revision - 1
        let savedStale = await execute(staleArgs)
        precondition(!savedStale.success && savedStale.body["status"] as? String == "stale" && savedStale.body["saved"] as? Bool == true)
        _ = try store.load(id: savedStale.body["artifact_id"] as! String)
        precondition(manifests().count == beforeStaleFiles + 1 && (savedStale.body["state"] as? [String: Any])?["revision"] as? Int == navigation.revision,
                     "A saved artifact with a stale page revision must report current state without claiming it appeared")
        navigation.mounted = false
        let notMounted = await execute(textArgs())
        precondition(!notMounted.success && notMounted.body["status"] as? String == "failed" && notMounted.body["saved"] as? Bool == true)
        _ = try store.load(id: notMounted.body["artifact_id"] as! String)

        // File and manifest access use real scoped filesystem validation.
        let outside = root.appendingPathComponent("outside.html")
        try "private".write(to: outside, atomically: true, encoding: .utf8)
        let escaped = root.appendingPathComponent("child/workspace/escaped.html")
        try fileManager.createSymbolicLink(at: escaped, withDestinationURL: outside)
        var symlinkArgs = htmlArgs; symlinkArgs["path"] = "workspace/escaped.html"; symlinkArgs["expected_revision"] = navigation.revision
        await rejected(symlinkArgs)
        var traversalArgs = htmlArgs; traversalArgs["path"] = "workspace/../../outside.html"; traversalArgs["expected_revision"] = navigation.revision
        await rejected(traversalArgs)
        let mismatchedID = "main:" + UUID().uuidString
        let manifest = AIChatViewModel.minisWorkspacePersistentDir(for: "main").appendingPathComponent("AppPresentations/\(try AppArtifact.identifier(mismatchedID).file).json")
        try JSONEncoder().encode(persisted).write(to: manifest)
        do { _ = try store.load(id: mismatchedID); preconditionFailure("Manifest identity must match the requested artifact") } catch {}
        print("PASS: actual app_present and artifact store enforce typed payloads, real content validation, child ownership on reopen, scoped files, stale voice isolation and truthful saved/mounted receipts")
    }
}
