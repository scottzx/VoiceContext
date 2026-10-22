import Foundation

#if DSH_OFFLINE_TESTS
// The protocol suite supplies its own credential closures and must never touch Keychain.
nonisolated enum DSHCookieCredentialStore {
    static func cookie(for url: URL) -> String? { preconditionFailure("Inject the offline credential loader") }
    static func save(cookie: String, for url: URL) throws { preconditionFailure("Inject the offline credential saver") }
}
#endif

/// Offline protocol checks. No DSH process, model, iPhone, or simulator is contacted.
private final class DSHFixtureProtocol: URLProtocol {
    static var respond: ((URLRequest) throws -> (Int, [String: String], Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, headers, bytes) = try Self.respond(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main
struct DSHProtocolTests {
    @MainActor
    static func main() async throws {
        try journalTests()
        try wireTests()
        try await httpTests()
        print("DSH offline protocol tests passed")
    }

    static func event(_ seq: Int, _ type: String, _ data: [String: Any], surface: Any? = nil) -> [String: Any] {
        var value: [String: Any] = ["type": type, "seq": seq, "time": 123, "data": data]
        if let surface { value["surfaceOp"] = surface }
        return ["type": "event", "event": value]
    }

    static func opening(_ records: [[String: Any]], cursor: Int, more: Bool = false,
                        stream: [String: Any] = [:]) -> [String: Any] {
        ["type": "snapshot", "header": ["id": "test-session", "version": 4, "agentPreset": "standard"],
         "cursor": cursor, "records": records, "hasMore": more, "assistantStream": stream,
         "projections": ["asOfSeq": cursor, "values": ["title": "Fixture"]]]
    }

    static func snapshot(_ reducer: DSHChatReducer) -> DSHChatSnapshot {
        reducer.snapshot(state: .connected, interactions: [])
    }

    static func journalTests() throws {
        var reducer = DSHChatReducer(sessionID: "test-session")
        let user = event(10, "user/message", ["id": "u1", "source": ["kind": "user"],
                                                   "content": [["type": "text", "text": "Hello"]]], surface: "append")
        let hidden = event(11, "user/message", ["id": "system", "source": ["kind": "runtime-context"],
                                                       "content": [["type": "text", "text": "PRIVATE CONTEXT"]]])
        try reducer.apply(opening([user, hidden, event(12, "turn/start", ["turn": 1])], cursor: 12, more: true))
        precondition(snapshot(reducer).entries.map(\.text) == ["Hello"])
        precondition(snapshot(reducer).isRunning && snapshot(reducer).hasMore)
        precondition(snapshot(reducer).agentPreset == "standard")
        reducer.setProjection(key: "modelSelection", value: ["next": ["provider": "remote", "model": "new"]], at: 13)
        reducer.setProjectionValues(["title": "Stale"], at: 11)
        precondition(snapshot(reducer).modelSelection?.model == "new", "Late control baselines cannot erase newer projections")
        reducer.setProjection(key: "modelSelection", value: ["next": NSNull(), "lastUsed": ["provider": "remote", "model": "last"]], at: 13)
        precondition(snapshot(reducer).modelSelection?.model == "last", "JSON null next falls back to the last used model")

        try reducer.apply(["type": "assistant-stream", "frame": ["type": "start", "attemptId": "a1", "revision": 1,
                                                                            "turn": 1, "step": 1, "startedAfterSeq": 12]])
        let delta: [String: Any] = ["type": "assistant-stream", "frame": ["type": "chunk", "attemptId": "a1",
            "revision": 2, "index": 0, "time": 124, "chunk": ["type": "text-delta", "index": 0, "text": "Hi"]]]
        try reducer.apply(delta)
        try reducer.apply(delta)
        precondition(snapshot(reducer).entries.last?.text == "Hi", "Duplicate stream indices cannot double text")
        var gap = delta
        var frame = DSHWire.object(gap["frame"])
        frame["index"] = 2
        frame["revision"] = 3
        gap["frame"] = frame
        try expectFailure { try reducer.apply(gap) }

        let assistant = event(13, "assistant/message", ["turn": 1, "step": 1,
            "message": ["id": "a-message", "role": "assistant", "content": [["type": "text", "text": "Hi"]]]], surface: "append")
        try reducer.apply(assistant)
        try reducer.apply(assistant)
        precondition(snapshot(reducer).entries.count == 2, "Durable settlement replaces its streaming counterpart")
        try reducer.apply(event(14, "turn/end", ["turn": 1]))
        precondition(!snapshot(reducer).isRunning)
        try expectFailure { try reducer.apply(event(16, "turn/start", ["turn": 2])) }

        try reducer.apply(opening([user, assistant, event(14, "turn/end", ["turn": 1])], cursor: 14))
        precondition(snapshot(reducer).entries.count == 2 && !snapshot(reducer).isRunning,
                     "Reconnect replaces the baseline rather than appending duplicate history")
        let replacement = event(15, "assistant/message", ["message": ["id": "replacement", "content": [
            ["type": "text", "text": "Corrected"]]]], surface: ["op": "replace", "startSeq": 13, "endSeq": 13])
        try reducer.apply(replacement)
        precondition(snapshot(reducer).entries.map(\.text) == ["Hello", "Corrected"])

        var streaming = DSHChatReducer(sessionID: "test-session")
        try streaming.apply(opening([event(0, "turn/start", ["turn": 1])], cursor: 0, stream: ["revision": 9,
            "activeAttempt": ["attemptId": "reconnected", "turn": 1, "step": 1, "startedAfterSeq": 0,
                "nextIndex": 3, "stream": [["type": "text-chunks", "index": 0, "time0": 1,
                                            "dt": [1, 1], "texts": ["Al", "rea", "dy"]]]]]))
        precondition(snapshot(streaming).entries.last?.text == "Already")
        try streaming.apply(["type": "assistant-stream", "frame": ["type": "chunk", "attemptId": "reconnected",
            "revision": 10, "index": 3, "time": 125, "chunk": ["type": "text-delta", "index": 0, "text": " here"]]])
        precondition(snapshot(streaming).entries.last?.text == "Already here")

        let attempt = event(1, "assistant/attempt", ["turn": 1, "step": 1, "stream": [
            ["type": "text-chunks", "index": 0, "texts": ["Interrupted text"], "dt": [], "time0": 1]]])
        try streaming.apply(attempt)
        try streaming.apply(event(2, "turn/end", ["turn": 1]))
        precondition(snapshot(streaming).entries.last?.text == "Interrupted text")
        try reducer.prepend(["records": [event(9, "user/message", ["id": "older", "source": ["kind": "user"],
                "content": [["type": "text", "text": "Older"]]])], "hasMore": false])
        precondition(snapshot(reducer).entries.first?.text == "Older")
        precondition(!snapshot(reducer).hasMore)
        try expectFailure { try reducer.apply(opening([], cursor: 0).merging(["header": ["id": "wrong", "version": 4]]) { _, b in b }) }

        var tools = DSHChatReducer(sessionID: "test-session")
        try tools.apply(opening([event(0, "assistant/message", ["turn": 1, "step": 1, "message": ["id": "tools", "content": [
            ["type": "tool-call", "id": "t1", "name": "read", "arguments": "a"],
            ["type": "tool-call", "id": "t2", "name": "write", "arguments": "b"]]]]),
            event(1, "tool/result", ["role": "tool", "id": "output", "toolCallId": "t1", "content": [["type": "text", "text": "done"]]]),
            event(2, "turn/end", ["turn": 1])], cursor: 2))
        let calls = snapshot(tools).entries.first!.tools
        precondition(calls.count == 2 && calls[0].status == "completed" && calls[0].output == "done")
        precondition(calls[1].status == "unknown", "Missing historical results cannot imply completion or cancellation")
        precondition(snapshot(tools).entries.count == 1, "Attached tool output is not repeated as another chat message")
    }

    static func wireTests() throws {
        let open = DSHWire.open(streamID: "events", endpoint: "$events", arguments: [:])
        precondition(open.keys.sorted() == ["endpoint", "payload", "streamId", "type"])
        precondition(DSHWire.object(DSHWire.object(open["payload"])["args"]).isEmpty)
        let response = try DSHWire.data(["type": "server-response", "rpcId": "expected", "result": ["ok": true, "value": ["accepted": true]]])
        let accepted = try DSHWire.response(response, requestID: "expected")
        precondition(DSHWire.object(accepted)["accepted"] as? Bool == true)
        try expectFailure { _ = try DSHWire.response(response, requestID: "other") }
        let failure = try DSHWire.data(["type": "server-response", "rpcId": "expected", "result": ["ok": false,
            "error": ["code": "session/writer-held", "message": "Busy"]]])
        try expectFailure { _ = try DSHWire.response(failure, requestID: "expected") }
    }

    @MainActor
    static func httpTests() async throws {
        let address = URL(string: "http://100.100.100.100:3080")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DSHFixtureProtocol.self]
        var calls: [String] = []
        var savedCookie: String?
        DSHFixtureProtocol.respond = { request in
            calls.append(request.url!.path)
            if request.url!.path == "/connect" {
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                precondition(query.first { $0.name == "interactions" }?.value == "answer")
                precondition(query.first { $0.name == "token" }?.value == "fixture-secret")
                return (302, ["Set-Cookie": "fixture=signed; Path=/; HttpOnly", "Location": "./api/remote.mux"], Data())
            }
            precondition(request.value(forHTTPHeaderField: "Cookie") == "fixture=signed")
            let bytes = try requestBody(request)
            let envelope = try DSHWire.decode(bytes)
            let method = envelope["method"] as! String
            let args = DSHWire.object(DSHWire.object(envelope["payload"])["args"])
            let result: Any
            switch method {
            case "session/canOpenWorkspacePath":
                precondition(args.isEmpty)
                result = true
            case "session/list":
                precondition(args.keys.sorted() == ["_request"])
                result = ["items": [["sessionId": "s", "updatedAt": 123000.0, "running": false, "blank": false,
                                     "agentAvailable": true, "projections": ["values": ["title": "Example"]]]]]
            case "session/create":
                precondition(DSHWire.object(args["request"])["cwd"] as? String == "/project")
                result = ["sessionId": "new"]
            case "session/prompt":
                let prompt = DSHWire.object(args["request"])
                precondition(prompt["requestId"] as? String == "stable-request")
                precondition(prompt["mode"] as? String == "queue")
                precondition(DSHWire.text(prompt["content"]) == "Hello")
                throw URLError(.networkConnectionLost)
            case "session/cancel": result = ["accepted": true]
            default: preconditionFailure("Unexpected mutation \(method)")
            }
            return (200, [:], try DSHWire.data(["type": "server-response", "rpcId": envelope["rpcId"]!,
                                               "result": ["ok": true, "value": result]]))
        }
        let client = DSHClient(baseURL: address, token: "fixture-secret", cookieLoader: { _ in nil },
                               cookieSaver: { value, _ in savedCookie = value }, configuration: configuration)
        try await client.connect()
        precondition(savedCookie == "fixture=signed")
        let cached = DSHClient(baseURL: address, token: "", cookieLoader: { _ in savedCookie },
                               cookieSaver: { _, _ in preconditionFailure("Valid cookie must not reauthenticate") },
                               configuration: configuration)
        try await cached.connect()
        precondition(calls.last == "/api/session/canOpenWorkspacePath", "Cookie probes cannot scan conversation history")
        let list = try await client.listSessions()
        precondition(list.count == 1 && list[0].title == "Example" && list[0].updatedAt.timeIntervalSince1970 == 123)
        let created = try await client.createSession(cwd: "/project")
        precondition(created == "new")
        do { try await client.send(text: "Hello", sessionID: "s", requestID: "stable-request"); preconditionFailure("Expected network failure") }
        catch is URLError {}
        precondition(calls.filter { $0 == "/api/session/prompt" }.count == 1, "Uncertain admission must never resubmit")
        try await client.cancel(sessionID: "s")
        let before = calls.count
        client.disconnect()
        precondition(calls.count == before, "Leaving a page cannot cancel the remote turn")
        do { try await client.respondToApproval(interactionID: "stale", allow: true); preconditionFailure("stale approval accepted") }
        catch DSHClientError.staleInteraction {}
    }

    static func requestBody(_ request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { throw DSHClientError.invalidResponse }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? DSHClientError.invalidResponse }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    static func expectFailure(_ action: () throws -> Void) throws {
        do { try action() } catch { return }
        preconditionFailure("Expected a protocol rejection")
    }
}
