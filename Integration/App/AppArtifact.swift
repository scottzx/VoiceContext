import Foundation

nonisolated struct AppArtifact: Codable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case text, image, chart, html }
    struct Point: Codable, Identifiable, Sendable {
        let label: String
        let value: Double
        var id: String { label }
    }
    struct Plot: Codable, Sendable {
        let kind: String
        let unit: String
        let source: String
        let points: [Point]

        func validate() throws {
            guard ["bar", "line"].contains(kind), !unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, unit.count <= 80,
                  !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, source.count <= 500,
                  !points.isEmpty, points.count <= 500,
                  Set(points.map(\.label)).count == points.count,
                  points.allSatisfy({ !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.label.count <= 100 && $0.value.isFinite }) else {
                throw AppArtifactError.invalid("图表需要明确来源、单位和不重复的有限数据点，最多 500 项。")
            }
        }
    }
    struct FileReference: Codable, Sendable {
        let bucket: String
        let path: String

        static func parse(_ raw: String) throws -> Self {
            var path = raw
            if raw.hasPrefix("minis://") {
                guard let url = URL(string: raw), url.query == nil, url.fragment == nil,
                      let host = url.host else { throw AppArtifactError.invalid("内容文件地址无效。") }
                path = host + url.path
            } else if raw.hasPrefix("/var/minis/") { path = String(raw.dropFirst("/var/minis/".count)) }
            let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
            guard pieces.count >= 2, ["workspace", "attachments"].contains(String(pieces[0])),
                  pieces.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  raw.utf8.count <= 2_048,
                  !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw AppArtifactError.invalid("只能展示本会话或已分派子会话 workspace/attachments 内的文件。")
            }
            return .init(bucket: String(pieces[0]), path: pieces.dropFirst().joined(separator: "/"))
        }

        func resolve(sessionRoot: URL, maximumBytes: Int) throws -> URL {
            let checked = try Self.parse(bucket + "/" + path)
            let session = sessionRoot.resolvingSymlinksInPath().standardizedFileURL
            let root = session.appendingPathComponent(checked.bucket).resolvingSymlinksInPath().standardizedFileURL
            let url = root.appendingPathComponent(checked.path).resolvingSymlinksInPath().standardizedFileURL
            guard root.path.hasPrefix(session.path + "/"), url.path.hasPrefix(root.path + "/") else {
                throw AppArtifactError.invalid("内容文件越过会话范围。")
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= maximumBytes else {
                throw AppArtifactError.invalid("内容文件不存在、为空或超过展示大小限制。")
            }
            return url
        }
    }

    let id: String
    let sessionID: String
    let sourceSessionID: String
    let title: String
    let kind: Kind
    let text: String?
    let file: FileReference?
    let chart: Plot?

    static func identifier(_ raw: String) throws -> (session: String, file: String) {
        let pieces = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2, validSession(String(pieces[0])), let id = UUID(uuidString: String(pieces[1])) else {
            throw AppArtifactError.invalid("产物标识无效。")
        }
        return (String(pieces[0]), id.uuidString)
    }

    static func validSession(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }

    func validate() throws {
        let identity = try Self.identifier(id)
        guard identity.session == sessionID, Self.validSession(sourceSessionID), !title.isEmpty, title.count <= 160 else {
            throw AppArtifactError.invalid("内容的会话或标题无效。")
        }
        switch kind {
        case .text:
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.count <= 50_000, file == nil, chart == nil else { throw AppArtifactError.invalid("文字内容需要 1–50000 字符。") }
        case .chart:
            guard let chart, text == nil, file == nil else { throw AppArtifactError.invalid("图表内容无效。") }
            try chart.validate()
        case .image, .html:
            guard let file, text == nil, chart == nil else { throw AppArtifactError.invalid("图片或网页需要真实文件。") }
            _ = try FileReference.parse(file.bucket + "/" + file.path)
        }
    }
}

nonisolated enum AppArtifactError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}
