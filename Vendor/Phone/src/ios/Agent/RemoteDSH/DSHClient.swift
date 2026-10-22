import Foundation

private final class DSHRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // The token exchange's cookie is inspected before following any server-provided URL.
        completionHandler(nil)
    }
}

/// Native client for the installed DSH 0.2.1-rc.2 HTTP RPC and WebSocket mux.
@MainActor
final class DSHClient {
    let baseURL: URL
    private let token: String
    private let session: URLSession
    private let persistCookie: (String, URL) throws -> Void
    private var cookie: String?
    private var socket: URLSessionWebSocketTask?
    private var observation: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<DSHChatSnapshot, Error>.Continuation?
    private var generation = UUID()
    private var reducer: DSHChatReducer?
    private var state: DSHConnectionState = .disconnected
    private var interactions: [String: DSHInteraction] = [:]
    private var eventsClientID: String?
    private var eventGeneration: [String: UUID] = [:]
    private var answeredInteractions: Set<String> = []
    private var connectionEpoch = UUID()

    init(baseURL: URL, token: String,
         cookieLoader: ((URL) -> String?)? = nil,
         cookieSaver: ((String, URL) throws -> Void)? = nil,
         configuration: URLSessionConfiguration? = nil) {
        self.baseURL = baseURL
        self.token = token
        self.cookie = (cookieLoader ?? { DSHCookieCredentialStore.cookie(for: $0) })(baseURL)
        self.persistCookie = cookieSaver ?? { try DSHCookieCredentialStore.save(cookie: $0, for: $1) }
        let config = configuration ?? .ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config, delegate: DSHRedirectPolicy(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func connect() async throws {
        guard ["http", "https"].contains(baseURL.scheme?.lowercased() ?? ""), baseURL.host != nil,
              baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil else {
            throw DSHClientError.invalidAddress
        }
        if cookie != nil {
            do {
                // Verify admission without scanning every persisted conversation.
                _ = try await rawRPC("session/canOpenWorkspacePath", arguments: [:])
                return
            } catch DSHClientError.unauthorized { cookie = nil }
        }
        try await authenticate()
    }

    /// Unsubscribes from observation. It never sends session/cancel.
    func disconnect() {
        generation = UUID()
        observation?.cancel()
        observation = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        state = .disconnected
        eventsClientID = nil
        interactions.removeAll()
        eventGeneration.removeAll()
        continuation?.finish()
        continuation = nil
    }

    func listSessions() async throws -> [DSHSessionSummary] {
        let value = DSHWire.object(try await rpc("session/list", arguments: ["_request": [:]]))
        guard let items = value["items"] as? [[String: Any]] else { throw DSHClientError.invalidResponse }
        return try items.filter { $0["origin"] as? String != "subagent" }.map { item in
            guard let id = item["sessionId"] as? String, let timestamp = item["updatedAt"] as? Double else {
                throw DSHClientError.invalidResponse
            }
            let values = DSHWire.object(DSHWire.object(item["projections"])["values"])
            return DSHSessionSummary(id: id, title: values["title"] as? String ?? "",
                                     updatedAt: Date(timeIntervalSince1970: timestamp / 1000),
                                     isRunning: item["running"] as? Bool ?? false, cwd: item["cwd"] as? String)
        }
    }

    func createSession(cwd: String? = nil, agentPreset: String? = nil) async throws -> String {
        var request: [String: Any] = [:]
        if let cwd { request["cwd"] = cwd }
        if let agentPreset { request["agentPreset"] = agentPreset }
        let value = DSHWire.object(try await rpc("session/create", arguments: ["request": request]))
        guard let id = value["sessionId"] as? String else { throw DSHClientError.invalidResponse }
        return id
    }

    func searchSessions(query: String) async throws -> [DSHSessionSearchResult] {
        let value = DSHWire.object(try await rpc("session/search", arguments: ["request": ["query": query]]))
        return try DSHWire.array(value["items"]).map { item in
            guard let id = item["sessionId"] as? String, let snippet = item["snippet"] as? String else {
                throw DSHClientError.invalidResponse
            }
            return DSHSessionSearchResult(id: id, snippet: snippet)
        }
    }

    func send(text: String, sessionID: String, requestID: String = UUID().uuidString) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Network failure is intentionally returned to the caller, without resubmitting a prompt.
        _ = try await rpc("session/prompt", arguments: ["request": ["requestId": requestID,
            "sessionId": sessionID, "mode": "queue", "content": [["type": "text", "text": text]],
            "clientTimeZone": TimeZone.current.identifier]])
    }

    func cancel(sessionID: String) async throws {
        _ = try await rpc("session/cancel", arguments: ["request": ["sessionId": sessionID]])
    }

    func rename(sessionID: String, title: String) async throws {
        _ = try await rpc("session/rename", arguments: ["request": ["sessionId": sessionID, "title": title]])
    }

    func follow(sessionID: String) -> AsyncThrowingStream<DSHChatSnapshot, Error> {
        disconnect()
        reducer = DSHChatReducer(sessionID: sessionID)
        let lifetime = UUID()
        generation = lifetime
        state = .connecting
        return AsyncThrowingStream { stream in
            continuation = stream
            publish()
            stream.onTermination = { [weak self] _ in
                Task { @MainActor in
                    if self?.generation == lifetime { self?.disconnect() }
                }
            }
            observation = Task { [weak self] in await self?.observe(sessionID: sessionID, lifetime: lifetime) }
        }
    }

    func loadOlder(sessionID: String) async throws {
        guard let current = reducer, current.sessionID == sessionID, current.hasMore,
              let oldest = current.oldestSequence else { return }
        let lifetime = generation
        let epoch = connectionEpoch
        let page = DSHWire.object(try await rpc("session/page", arguments: ["request": [
            "address": ["kind": "session", "sessionId": sessionID], "throughSeq": current.cursor,
            "beforeSeq": oldest, "maxMessages": 100]]))
        guard lifetime == generation, epoch == connectionEpoch, reducer?.sessionID == sessionID else { return }
        try reducer?.prepend(page)
        publish()
    }

    func modelCatalog() async throws -> [DSHModelOption] {
        let value = DSHWire.object(try await rpc("session/modelCatalog", arguments: [:]))
        return DSHWire.array(value["groups"]).flatMap { group in
            DSHWire.array(group["models"]).compactMap { model in
                guard let provider = group["id"] as? String, let id = model["id"] as? String else { return nil }
                let efforts = DSHWire.array(DSHWire.object(model["reasoning"])["efforts"]).compactMap { $0["id"] as? String }
                return DSHModelOption(provider: provider, model: id, name: model["name"] as? String ?? id,
                                      reasoningEfforts: efforts)
            }
        }
    }

    func selectModel(sessionID: String, provider: String, model: String, reasoningEffort: String? = nil) async throws {
        var request: [String: Any] = ["sessionId": sessionID, "provider": provider, "model": model]
        if let reasoningEffort { request["reasoningEffort"] = reasoningEffort }
        _ = try await rpc("session/selectModel", arguments: ["request": request])
    }

    /// ACP configuration stays on its own endpoint; it never changes the local model provider.
    func acpConfiguration(sessionID: String) async throws -> [String: Any] {
        try await acpRequest(sessionID: sessionID, body: nil)
    }

    func configureACP(sessionID: String, configID: String, value: String) async throws -> [String: Any] {
        try await acpRequest(sessionID: sessionID, body: ["configId": configID, "value": value])
    }

    func respondToApproval(interactionID: String, allow: Bool) async throws {
        guard interactions[interactionID]?.kind == .approval else { throw DSHClientError.staleInteraction }
        try await answer(interactionID: interactionID, value: allow ? "allowed-once" : "rejected")
    }

    func respondToQuestions(interactionID: String, answers: [DSHQuestionAnswer]) async throws {
        guard interactions[interactionID]?.kind == .questions else { throw DSHClientError.staleInteraction }
        let values: [[String: Any]] = answers.map { answer in
            var value: [String: Any] = ["id": answer.id, "selected": answer.selected]
            if let custom = answer.custom { value["custom"] = custom }
            return value
        }
        try await answer(interactionID: interactionID, value: ["answers": values])
    }

    private func answer(interactionID: String, value: Any) async throws {
        guard state == .connected, let client = eventsClientID,
              eventGeneration[interactionID] == generation, interactions[interactionID] != nil,
              !answeredInteractions.contains(interactionID) else { throw DSHClientError.staleInteraction }
        // A lost response may already have reached the Host. Do not offer the same stale action again.
        answeredInteractions.insert(interactionID)
        interactions.removeValue(forKey: interactionID)
        publish()
        _ = try await rpc("$events/result", arguments: ["clientId": client, "eventId": interactionID,
                                                       "outcome": ["kind": "result", "value": value]],
                          allowReauthentication: false)
    }

    private func authenticate() async throws {
        guard ["http", "https"].contains(baseURL.scheme?.lowercased() ?? ""), baseURL.host != nil,
              baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil else {
            throw DSHClientError.invalidAddress
        }
        guard !token.isEmpty else { throw DSHClientError.unauthorized }
        var components = URLComponents(url: endpoint("connect"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "token", value: token), URLQueryItem(name: "interactions", value: "answer")]
        guard let url = components?.url else { throw DSHClientError.invalidAddress }
        let (_, response) = try await session.data(for: URLRequest(url: url))
        guard let response = response as? HTTPURLResponse else { throw DSHClientError.invalidResponse }
        guard response.statusCode == 302 else { throw DSHClientError.unauthorized }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, item in
            if let key = item.key as? String, let value = item.value as? String { result[key] = value }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
        guard !cookies.isEmpty else { throw DSHClientError.unauthorized }
        let value = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        try persistCookie(value, baseURL)
        cookie = value
    }

    private func rpc(_ method: String, arguments: [String: Any], allowReauthentication: Bool = true) async throws -> Any {
        if cookie == nil {
            guard allowReauthentication else { throw DSHClientError.staleInteraction }
            try await authenticate()
        }
        do { return try await rawRPC(method, arguments: arguments) }
        catch DSHClientError.unauthorized {
            // Interaction IDs belong to the delivering Peer, so a new credential
            // requires a fresh events handshake before the user may answer again.
            guard allowReauthentication else { throw DSHClientError.staleInteraction }
            // An HTTP 401 rejects admission before the requested method runs.
            cookie = nil
            try await authenticate()
            return try await rawRPC(method, arguments: arguments)
        }
    }

    private func rawRPC(_ method: String, arguments: [String: Any]) async throws -> Any {
        let requestID = UUID().uuidString
        var request = authorizedRequest(endpoint("api/" + method))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try DSHWire.data(["type": "client-request", "rpcId": requestID,
                                           "method": method, "payload": ["args": arguments]])
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return try DSHWire.response(data, requestID: requestID)
    }

    private func acpRequest(sessionID: String, body: [String: Any]?) async throws -> [String: Any] {
        if cookie == nil { try await authenticate() }
        var components = URLComponents(url: endpoint("api/1agents-acp/session"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "id", value: sessionID)]
        guard let url = components?.url else { throw DSHClientError.invalidAddress }
        var request = authorizedRequest(url)
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try DSHWire.data(body)
        }
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return try DSHWire.decode(data)
    }

    private func endpoint(_ path: String) -> URL { baseURL.appendingPathComponent(path) }

    private func authorizedRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        var origin = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        origin?.path = ""
        request.setValue(origin?.string, forHTTPHeaderField: "Origin")
        return request
    }

    private func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw DSHClientError.invalidResponse }
        if response.statusCode == 401 { throw DSHClientError.unauthorized }
        guard (200..<300).contains(response.statusCode) else {
            throw DSHClientError.remote("http/\(response.statusCode)", NSLocalizedString("远程服务请求失败", comment: "DSH remote chat"))
        }
    }

    private func publish() {
        if let reducer {
            continuation?.yield(reducer.snapshot(state: state, interactions: interactions.values.sorted { $0.id < $1.id }))
        }
    }

    private func observe(sessionID: String, lifetime: UUID) async {
        var retries = 0
        while !Task.isCancelled, generation == lifetime {
            do {
                // /connect v2 cookies name one process-local API Peer. A Peer owns at most
                // one socket and is retired when that socket closes, so every physical
                // observation gets its own credential rather than sharing another chat's.
                try await authenticate()
                try Task.checkCancellation()
                guard generation == lifetime else { return }
                var url = URLComponents(url: endpoint("api/remote.mux"), resolvingAgainstBaseURL: false)!
                url.scheme = baseURL.scheme == "https" ? "wss" : "ws"
                let task = session.webSocketTask(with: authorizedRequest(url.url!))
                task.maximumMessageSize = 16 * 1024 * 1024
                socket = task
                task.resume()
                eventsClientID = nil
                interactions.removeAll()
                answeredInteractions.removeAll()
                eventGeneration.removeAll()
                connectionEpoch = UUID()
                reducer?.beginConnection()
                try await sendFrame(DSHWire.open(streamID: "events", endpoint: "$events", arguments: [:]), on: task)
                while !Task.isCancelled, generation == lifetime {
                    let message = try await task.receive()
                    guard !Task.isCancelled, generation == lifetime else { return }
                    let data: Data
                    switch message {
                    case .data(let bytes): data = bytes
                    case .string(let string): data = Data(string.utf8)
                    @unknown default: throw DSHClientError.invalidResponse
                    }
                    let frame = try DSHWire.decode(data)
                    guard let streamID = frame["streamId"] as? String, let type = frame["type"] as? String else {
                        throw DSHClientError.invalidResponse
                    }
                    if type == "error" {
                        let error = DSHWire.object(frame["error"])
                        throw DSHClientError.remote(error["code"] as? String ?? "gateway/internal",
                                                   NSLocalizedString("远程会话订阅失败", comment: "DSH remote chat"))
                    }
                    if type == "end" { throw DSHClientError.invalidResponse }
                    guard type == "item", let value = frame["value"] as? [String: Any] else {
                        throw DSHClientError.invalidResponse
                    }
                    if streamID == "events", value["type"] as? String == "ready" {
                        guard eventsClientID == nil, let client = value["clientId"] as? String else {
                            throw DSHClientError.invalidResponse
                        }
                        eventsClientID = client
                        try await sendFrame(DSHWire.open(streamID: "follow", endpoint: "session/follow", arguments: [
                            "request": ["address": ["kind": "session", "sessionId": sessionID],
                                        "assistantStream": true, "maxMessages": 100]]), on: task)
                        try await sendFrame(DSHWire.open(streamID: "control", endpoint: "session/control", arguments: [:]), on: task)
                    } else if streamID == "events" {
                        try await applyRemoteEvent(value, lifetime: lifetime)
                    } else if streamID == "follow" {
                        try reducer?.apply(value)
                        if value["type"] as? String == "snapshot" { state = .connected; retries = 0 }
                    } else if streamID == "control" {
                        applyControl(value, sessionID: sessionID)
                    }
                    publish()
                }
                return
            } catch {
                guard !Task.isCancelled, generation == lifetime else { return }
                socket?.cancel(with: .goingAway, reason: nil)
                socket = nil
                interactions.removeAll()
                eventGeneration.removeAll()
                eventsClientID = nil
                if let failure = error as? DSHClientError {
                    switch failure {
                    case .historyGap: break
                    default:
                        state = .disconnected
                        publish()
                        continuation?.finish(throwing: failure)
                        return
                    }
                }
                retries += 1
                guard retries <= 6 else {
                    state = .disconnected
                    publish()
                    continuation?.finish(throwing: URLError(.networkConnectionLost))
                    return
                }
                state = .reconnecting
                publish()
                do { try await Task.sleep(nanoseconds: UInt64(min(15, 1 << (retries - 1))) * 1_000_000_000) }
                catch { return }
            }
        }
    }

    private func sendFrame(_ value: [String: Any], on socket: URLSessionWebSocketTask) async throws {
        let bytes = try DSHWire.data(value)
        guard let string = String(data: bytes, encoding: .utf8) else { throw DSHClientError.invalidResponse }
        try await socket.send(.string(string))
    }

    private func applyControl(_ value: [String: Any], sessionID: String) {
        if value["type"] as? String == "baseline" {
            let entry = DSHWire.object(DSHWire.object(DSHWire.object(value["value"])["projections"])[sessionID])
            if let seq = entry["asOfSeq"] as? Int {
                reducer?.setProjectionValues(DSHWire.object(entry["values"]), at: seq)
            }
        } else if value["type"] as? String == "projection", value["sessionId"] as? String == sessionID,
                  let key = value["key"] as? String, let seq = value["seq"] as? Int {
            reducer?.setProjection(key: key, value: value["value"] ?? NSNull(), at: seq)
        }
    }

    private func applyRemoteEvent(_ value: [String: Any], lifetime: UUID) async throws {
        if value["type"] as? String == "cancel", let id = value["eventId"] as? String {
            interactions.removeValue(forKey: id)
            eventGeneration.removeValue(forKey: id)
            return
        }
        if value["type"] as? String == "emit" { return }
        guard value["type"] as? String == "waterfall", let id = value["eventId"] as? String,
              let event = value["event"] as? String, let sessionID = value["agentId"] as? String else {
            throw DSHClientError.invalidResponse
        }
        let request = DSHWire.object(value["request"])
        if event == "approval/request" {
            interactions[id] = DSHInteraction(id: id, sessionID: sessionID, kind: .approval,
                title: request["toolName"] as? String ?? NSLocalizedString("工具请求", comment: "DSH remote chat"), detail: request["displayReason"] as? String ?? request["reason"] as? String ?? "", questions: [])
        } else if event == "user-questions/request" {
            let questions = DSHWire.array(request["questions"]).compactMap { item -> DSHQuestion? in
                guard let id = item["id"] as? String, let prompt = item["question"] as? String else { return nil }
                let options = DSHWire.array(item["options"]).compactMap { option -> DSHQuestionOption? in
                    guard let label = option["label"] as? String else { return nil }
                    return DSHQuestionOption(label: label, detail: option["description"] as? String ?? "")
                }
                return DSHQuestion(id: id, prompt: prompt, detail: item["detail"] as? String ?? "",
                                   options: options, allowsMultiple: item["multiSelect"] as? Bool ?? false)
            }
            guard !questions.isEmpty else { throw DSHClientError.invalidResponse }
            interactions[id] = DSHInteraction(id: id, sessionID: sessionID, kind: .questions,
                                              title: NSLocalizedString("需要你的回答", comment: "DSH remote chat"), detail: "", questions: questions)
        } else if let client = eventsClientID {
            _ = try await rpc("$events/result", arguments: ["clientId": client, "eventId": id,
                                                            "outcome": ["kind": "next"]], allowReauthentication: false)
            return
        }
        eventGeneration[id] = lifetime
    }
}
