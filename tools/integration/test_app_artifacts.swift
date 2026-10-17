import Foundation

@main struct AppArtifactChecks {
    static func main() throws {
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: temporary) }
        let session = temporary.appendingPathComponent("session", isDirectory: true)
        let workspace = session.appendingPathComponent("workspace", isDirectory: true)
        let outside = temporary.appendingPathComponent("other-session", isDirectory: true)
        try manager.createDirectory(at: workspace, withIntermediateDirectories: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        let good = workspace.appendingPathComponent("report.html")
        let secret = outside.appendingPathComponent("secret.html")
        try Data("<p>Report</p>".utf8).write(to: good)
        try Data("private".utf8).write(to: secret)

        func rejects(_ label: String, _ operation: () throws -> Void) {
            do { try operation(); fatalError("Expected rejection: \(label)") } catch { }
        }
        for value in ["workspace/report.html", "minis://workspace/report.html", "/var/minis/workspace/report.html"] {
            let file = try AppArtifact.FileReference.parse(value)
            let resolved = try file.resolve(sessionRoot: session, maximumBytes: 100)
            precondition(resolved == good)
        }
        for path in ["workspace/../other-session/secret.html", "workspace//report.html", "shared/report.html",
                     "minis://workspace/%2e%2e/secret.html", "minis://workspace/report.html?query=1", "workspace/\nreport.html"] {
            rejects(path) { _ = try AppArtifact.FileReference.parse(path) }
        }
        try manager.createSymbolicLink(at: workspace.appendingPathComponent("escaped.html"), withDestinationURL: secret)
        rejects("file symlink outside workspace") {
            _ = try AppArtifact.FileReference.parse("workspace/escaped.html").resolve(sessionRoot: session, maximumBytes: 100)
        }
        try manager.createSymbolicLink(at: session.appendingPathComponent("attachments"), withDestinationURL: outside)
        rejects("bucket symlink outside session") {
            _ = try AppArtifact.FileReference.parse("attachments/secret.html").resolve(sessionRoot: session, maximumBytes: 100)
        }
        rejects("size bound") { _ = try AppArtifact.FileReference.parse("workspace/report.html").resolve(sessionRoot: session, maximumBytes: 1) }
        rejects("directory content") { _ = try AppArtifact.FileReference.parse("workspace/folder").resolve(sessionRoot: session, maximumBytes: 100) }
        for id in ["../other:123", "a:invalid", "a:b:" + UUID().uuidString] {
            rejects("malformed ID") { _ = try AppArtifact.identifier(id) }
        }
        let id = "owner:" + UUID().uuidString
        let content = AppArtifact(id: id, sessionID: "owner", sourceSessionID: "child", title: "报告", kind: .text,
                                  text: "真实文字", file: nil, chart: nil)
        try content.validate()
        let decoded = try JSONDecoder().decode(AppArtifact.self, from: JSONEncoder().encode(content))
        try decoded.validate()
        precondition(decoded.id == id && decoded.text == "真实文字")
        rejects("wrong owner") {
            try AppArtifact(id: id, sessionID: "other", sourceSessionID: "owner", title: "报告", kind: .text,
                            text: "正文", file: nil, chart: nil).validate()
        }
        rejects("mixed content") {
            try AppArtifact(id: id, sessionID: "owner", sourceSessionID: "owner", title: "报告", kind: .text,
                            text: "正文", file: .init(bucket: "workspace", path: "report.html"), chart: nil).validate()
        }
        let points: [AppArtifact.Point] = [.init(label: "一月", value: 12), .init(label: "二月", value: -3)]
        try AppArtifact.Plot(kind: "line", unit: "项", source: "用户提供的统计", points: points).validate()
        rejects("missing source") { try AppArtifact.Plot(kind: "bar", unit: "项", source: "", points: points).validate() }
        rejects("blank source") { try AppArtifact.Plot(kind: "bar", unit: "项", source: "  ", points: points).validate() }
        rejects("missing units") { try AppArtifact.Plot(kind: "bar", unit: "", source: "统计", points: points).validate() }
        rejects("duplicate labels") { try AppArtifact.Plot(kind: "bar", unit: "项", source: "统计", points: [points[0], points[0]]).validate() }
        rejects("infinite value") { try AppArtifact.Plot(kind: "line", unit: "项", source: "统计", points: [.init(label: "数据", value: .infinity)]).validate() }
        print("App artifact checks passed: scoped files, symlink boundaries, typed content, chart integrity.")
    }
}
