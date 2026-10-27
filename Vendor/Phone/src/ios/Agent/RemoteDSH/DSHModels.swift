import Foundation

// Wire vocabulary verified against DSH 0.2.1-rc.2, build 332895e0.
struct DSHSessionSummary: Identifiable {
    let id: String
    let title: String
    let updatedAt: Date
    let isRunning: Bool
    let cwd: String?
}

struct DSHSessionSearchResult: Identifiable {
    let id: String
    let snippet: String
}

enum DSHChatRole: String { case user, assistant, tool }
enum DSHConnectionState: Equatable { case connecting, connected, reconnecting, disconnected }

struct DSHChatTool: Identifiable {
    let id: String
    let name: String
    let arguments: String
    var status: String = "running"
    var output: String?
}

/// The numbered text envelope returned by DSH read_file, not a general XML format.
struct DSHFileReadOutput {
    let path: String
    let content: String
    let notices: String?

    static func parse(_ raw: String) -> DSHFileReadOutput? {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let header = "</path>\n<type>file</type>\n<content>"
        guard text.hasPrefix("<path>"), let headerEnd = text.range(of: header),
              let closing = text.range(of: "\n</content>", options: .backwards),
              closing.lowerBound >= headerEnd.upperBound,
              text[closing.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let path = String(text[text.index(text.startIndex, offsetBy: 6)..<headerEnd.lowerBound])
        guard !path.isEmpty, !path.contains("\n") else { return nil }
        var body = String(text[headerEnd.upperBound..<closing.lowerBound])
        if body.hasPrefix("\n") { body.removeFirst() }
        if body.isEmpty { return DSHFileReadOutput(path: path, content: "", notices: nil) }

        var content: [String] = []
        var notices: [String] = []
        var previousLine: Int?
        for line in body.components(separatedBy: "\n") {
            if let colon = line.firstIndex(of: ":"), !line[..<colon].isEmpty,
               line[..<colon].unicodeScalars.allSatisfy({ (48...57).contains($0.value) }),
               let number = Int(line[..<colon]), number > 0 {
                let afterColon = line.index(after: colon)
                guard afterColon == line.endIndex || line[afterColon] == " ", notices.isEmpty else { return nil }
                if let previousLine {
                    guard previousLine < Int.max, number == previousLine + 1 else { return nil }
                }
                let start = afterColon == line.endIndex ? afterColon : line.index(after: afterColon)
                content.append(String(line[start...]))
                previousLine = number
            } else {
                // A numbered file's trailing EOF/truncation metadata stays visible separately.
                // Mixed or unnumbered formats fall back to the original literal tool result.
                guard previousLine != nil else { return nil }
                notices.append(line)
            }
        }
        return DSHFileReadOutput(path: path, content: content.joined(separator: "\n"),
                                 notices: notices.isEmpty ? nil : notices.joined(separator: "\n"))
    }
}

enum DSHChatPartKind {
    case text(String)
    case reasoning(String)
    case tool(DSHChatTool)
}

struct DSHChatPart: Identifiable {
    let id: String
    var kind: DSHChatPartKind
}

struct DSHChatEntry: Identifiable {
    let id: String
    var role: DSHChatRole
    var text: String = ""
    var reasoning: String = ""
    var isStreaming: Bool = false
    var toolName: String?
    var toolOutput: String?
    var toolStatus: String?
    var tools: [DSHChatTool] = []
    /// Authoritative display order; aggregate fields above remain available to existing callers.
    var parts: [DSHChatPart] = []
    var turn: Int?
    var step: Int?
    var sourceMessageID: String?
}

enum DSHInteractionKind { case approval, questions }
struct DSHQuestionOption: Identifiable {
    var id: String { label }
    let label: String
    let detail: String
}
struct DSHQuestion: Identifiable {
    let id: String
    let prompt: String
    let detail: String
    let options: [DSHQuestionOption]
    let allowsMultiple: Bool
}
struct DSHQuestionAnswer {
    let id: String
    let selected: [String]
    var custom: String? = nil
}
struct DSHInteraction: Identifiable {
    let id: String
    let sessionID: String
    let kind: DSHInteractionKind
    let title: String
    let detail: String
    let questions: [DSHQuestion]
}
struct DSHModelOption: Identifiable {
    var id: String { provider + "/" + model }
    let provider: String
    let model: String
    let name: String
    let reasoningEfforts: [String]
}
struct DSHModelSelection {
    let provider: String
    let model: String
    let reasoningEffort: String?
}
struct DSHChatSnapshot {
    let sessionID: String
    var title: String = ""
    var entries: [DSHChatEntry] = []
    var isRunning: Bool = false
    var interactions: [DSHInteraction] = []
    var connectionState: DSHConnectionState = .connecting
    var hasMore: Bool = false
    var agentPreset: String?
    var modelSelection: DSHModelSelection?
}

enum DSHClientError: LocalizedError {
    case invalidAddress, unauthorized, invalidResponse, unsupportedVersion, historyGap, staleInteraction
    case remote(String, String)

    var errorDescription: String? {
        switch self {
        case .invalidAddress: return NSLocalizedString("远程服务地址无效。", comment: "DSH remote chat")
        case .unauthorized: return NSLocalizedString("远程服务登录已失效，请更新连接凭据。", comment: "DSH remote chat")
        case .invalidResponse: return NSLocalizedString("远程服务返回了无法识别的数据。", comment: "DSH remote chat")
        case .unsupportedVersion: return NSLocalizedString("此远程服务的协议版本暂不受支持。", comment: "DSH remote chat")
        case .historyGap: return NSLocalizedString("远程会话更新不完整，正在重新读取。", comment: "DSH remote chat")
        case .staleInteraction: return NSLocalizedString("此请求已失效，请等待重新连接后的最新请求。", comment: "DSH remote chat")
        case .remote(let code, let message): return "\(message)（\(code)）"
        }
    }
}

enum DSHWire {
    static func object(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
    static func array(_ value: Any?) -> [[String: Any]] { value as? [[String: Any]] ?? [] }
    static func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    static func decode(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DSHClientError.invalidResponse
        }
        return value
    }
    static func text(_ content: Any?) -> String {
        if let string = content as? String { return string }
        return array(content).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
    }
    static func open(streamID: String, endpoint: String, arguments: [String: Any]) -> [String: Any] {
        ["type": "open", "streamId": streamID, "endpoint": endpoint, "payload": ["args": arguments]]
    }
    static func response(_ data: Data, requestID: String) throws -> Any {
        let envelope = try decode(data)
        guard envelope["type"] as? String == "server-response", envelope["rpcId"] as? String == requestID,
              let result = envelope["result"] as? [String: Any], let ok = result["ok"] as? Bool else {
            throw DSHClientError.invalidResponse
        }
        if !ok {
            let error = object(result["error"])
            throw DSHClientError.remote(error["code"] as? String ?? "gateway/internal",
                                        error["message"] as? String ?? NSLocalizedString("远程请求失败", comment: "DSH remote chat"))
        }
        return result["value"] ?? NSNull()
    }
}
