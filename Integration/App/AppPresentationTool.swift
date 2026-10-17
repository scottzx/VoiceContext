import Foundation
import CoreFoundation
import ImageIO

@MainActor
enum AppPresentationTool {
    static let definition = AgentToolDefinition(
        name: "app_present",
        description: "Save and display text, an image, a bar/line chart, or a local HTML file using an in-app content preview. Pass a title and exactly one text/path/chart_json payload. Files must exist in this session's workspace/attachments; source_session_id may name a verified direct subagent session. Chart JSON shape: {kind:bar|line,unit:string,source:string,points:[{label:string,value:number}]}; include factual source and units. Do not invent data. Read app_navigation get_state and pass expected_revision. Only visible confirms the preview rendered; saved but stale/failed does not mean displayed. Use the returned artifact_id with app_navigation artifact.preview to reopen. Background executors must return artifacts to their parent instead of controlling UI.",
        parameters: [
            "type": .init(type: .string, description: "Content type", enumValues: ["text", "image", "chart", "html"]),
            "title": .init(type: .string, description: "Short content title, at most 160 characters"),
            "text": .init(type: .string, description: "Public text content only, up to 50000 characters"),
            "path": .init(type: .string, description: "Existing workspace/... or attachments/... path; minis:// and /var/minis/ prefixes also accepted"),
            "chart_json": .init(type: .string, description: "Chart JSON with bar/line kind, unit, factual source and 1–500 uniquely labeled finite points"),
            "source_session_id": .init(type: .string, description: "For file content only: this session or an existing direct subagent session ID from a verified task receipt"),
            "expected_revision": .init(type: .integer, description: "Current app_navigation get_state revision, required before display")
        ], required: ["type", "title", "expected_revision"]
    )

    static func execute(_ args: [String: Any], sessionID: String?, sessionSource: String?, voiceGeneration: UInt64? = nil) async -> (output: String, success: Bool) {
        func result(_ body: [String: Any], success: Bool) -> (String, Bool) {
            let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
            return (String(decoding: data, as: UTF8.self), success)
        }
        do {
            guard let sessionID, AppArtifact.validSession(sessionID),
                  let type = args["type"] as? String, let kind = AppArtifact.Kind(rawValue: type),
                  let title = args["title"] as? String,
                  Set(args.keys).isSubset(of: ["type", "title", "text", "path", "chart_json", "source_session_id", "expected_revision"]),
                  let revision = args["expected_revision"] as? NSNumber,
                  CFGetTypeID(revision) != CFBooleanGetTypeID(), revision.doubleValue.isFinite,
                  revision.doubleValue == revision.doubleValue.rounded(), revision.doubleValue >= 0,
                  revision.doubleValue < Double(Int.max) else { throw AppArtifactError.invalid("展示参数无效，请先读取当前页面版本。") }
            guard args["source_session_id"] == nil || args["source_session_id"] is String else {
                throw AppArtifactError.invalid("内容来源会话必须是字符串。")
            }
            let source = args["source_session_id"] as? String ?? sessionID
            guard AppArtifact.validSession(source), await ChatStore.shared.getSession(sessionID) != nil else {
                throw AppArtifactError.invalid("当前会话已不存在。")
            }
            if source != sessionID {
                guard let child = await ChatStore.shared.getSession(source), child.parentSessionId == sessionID else {
                    throw AppArtifactError.invalid("只能展示当前会话或真实已分派子会话的产物。")
                }
            }
            let center = AppNavigationCenter.shared
            let voice = AgentRuntimePolicies.policy(for: sessionSource).requiresNavigationBinding
            guard !Task.isCancelled, !voice || center.isVoiceBindingCurrent(sessionID: sessionID, generation: voiceGeneration) else {
                return result(["status": "stale", "message": "语音请求已失效，不会打开内容。"], success: false)
            }
            let text = args["text"] as? String
            let path = args["path"] as? String
            let rawChart = args["chart_json"] as? String
            let payloadKey = kind == .text ? "text" : kind == .chart ? "chart_json" : "path"
            guard Set(args.keys).intersection(["text", "path", "chart_json"]) == [payloadKey], args[payloadKey] is String else {
                throw AppArtifactError.invalid("请只提供对应类型的 text、path 或 chart_json 字符串。")
            }
            var chart: AppArtifact.Plot?
            var file: AppArtifact.FileReference?
            if kind == .chart {
                guard let rawChart, rawChart.utf8.count <= 262_144 else { throw AppArtifactError.invalid("图表 JSON 无效或过大。") }
                chart = try JSONDecoder().decode(AppArtifact.Plot.self, from: Data(rawChart.utf8))
            } else if kind == .image || kind == .html {
                guard let path else { throw AppArtifactError.invalid("图片和 HTML 必须提供真实文件路径。") }
                file = try AppArtifact.FileReference.parse(path)
            } else if text == nil { throw AppArtifactError.invalid("文字展示缺少正文。") }
            let artifact = AppArtifact(id: sessionID + ":" + UUID().uuidString, sessionID: sessionID, sourceSessionID: source,
                                       title: title.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind, text: text, file: file, chart: chart)
            try artifact.validate()
            if kind == .image || kind == .html {
                let url = try AppArtifactStore.shared.fileURL(for: artifact)
                if kind == .html {
                    guard ["html", "htm"].contains(url.pathExtension.lowercased()), (try? String(contentsOf: url, encoding: .utf8)) != nil else {
                        throw AppArtifactError.invalid("需要 UTF-8 HTML 文件。")
                    }
                } else {
                    guard let image = CGImageSourceCreateWithURL(url as CFURL, nil),
                          let info = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                          let width = info[kCGImagePropertyPixelWidth] as? NSNumber,
                          let height = info[kCGImagePropertyPixelHeight] as? NSNumber,
                          width.doubleValue * height.doubleValue <= 40_000_000 else { throw AppArtifactError.invalid("图片无法读取或像素过大。") }
                }
            }
            try AppArtifactStore.shared.save(artifact)
            let navigation = await center.navigate(routeID: "artifact.preview", params: ["artifact_id": artifact.id],
                                                   expectedRevision: revision.intValue, sessionID: voice ? sessionID : nil,
                                                   voiceGeneration: voice ? voiceGeneration : nil)
            var body = navigation.dictionary
            body["artifact_id"] = artifact.id
            body["saved"] = true
            body["title"] = artifact.title
            return result(body, success: navigation.success)
        } catch {
            return result(["status": "failed", "message": error.localizedDescription], success: false)
        }
    }
}
