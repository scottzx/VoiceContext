import Foundation

/// Holds the server journal separately from local ChatStore and never invokes local tools.
struct DSHChatReducer {
    private(set) var sessionID: String
    private(set) var cursor = -1
    private(set) var hasMore = false
    private(set) var header: [String: Any] = [:]
    private var events: [Int: [String: Any]] = [:]
    private var projections: [String: Any] = [:]
    private var projectionCursor = -1
    private var activeAttempt: String?
    private var activeTurn: Int?
    private var activeStep: Int?
    private var activeStartedAfterSequence = -1
    private var settlementIdentities: [Int: String] = [:]
    private var nextChunkIndex = 0
    private var streamRevision = 0
    private var blocks: [Int: [String: Any]] = [:]
    private var streamSettled = false

    init(sessionID: String) { self.sessionID = sessionID }

    var oldestSequence: Int? { events.keys.min() }

    mutating func apply(_ value: [String: Any]) throws {
        switch value["type"] as? String {
        case "snapshot":
            let nextHeader = DSHWire.object(value["header"])
            guard nextHeader["id"] as? String == sessionID,
                  let nextCursor = value["cursor"] as? Int,
                  let records = value["records"] as? [[String: Any]],
                  let more = value["hasMore"] as? Bool else { throw DSHClientError.invalidResponse }
            // DSH V4 carries message content and the compact assistant stream used below.
            guard nextHeader["version"] as? Int == 4 else { throw DSHClientError.unsupportedVersion }
            header = nextHeader
            events.removeAll()
            insert(records)
            cursor = nextCursor
            hasMore = more
            let baseline = DSHWire.object(value["projections"])
            setProjectionValues(DSHWire.object(baseline["values"]), at: baseline["asOfSeq"] as? Int ?? nextCursor)
            clearAttempt()
            let stream = DSHWire.object(value["assistantStream"])
            streamRevision = stream["revision"] as? Int ?? 0
            let attempt = DSHWire.object(stream["activeAttempt"])
            if let id = attempt["attemptId"] as? String {
                activeAttempt = id
                activeTurn = attempt["turn"] as? Int
                activeStep = attempt["step"] as? Int
                activeStartedAfterSequence = attempt["startedAfterSeq"] as? Int ?? nextCursor
                nextChunkIndex = attempt["nextIndex"] as? Int ?? 0
                for record in DSHWire.array(attempt["stream"]) { applyCompactRecord(record) }
            }
        case "event":
            let event = DSHWire.object(value["event"])
            guard let sequence = event["seq"] as? Int else { throw DSHClientError.invalidResponse }
            if sequence <= cursor { return }
            guard sequence == cursor + 1 else { throw DSHClientError.historyGap }
            if isActiveSettlement(event), let attempt = activeAttempt {
                settlementIdentities[sequence] = "live-" + attempt
            }
            events[sequence] = event
            cursor = sequence
            if event["type"] as? String == "step/end" { clearAttempt() }
            if event["type"] as? String == "turn/end" { clearAttempt() }
        case "assistant-stream":
            try applyStream(DSHWire.object(value["frame"]))
        default: throw DSHClientError.invalidResponse
        }
    }

    mutating func prepend(_ page: [String: Any]) throws {
        guard let records = page["records"] as? [[String: Any]], let more = page["hasMore"] as? Bool else {
            throw DSHClientError.invalidResponse
        }
        let previous = oldestSequence
        insert(records)
        hasMore = more
        if more && previous == oldestSequence { throw DSHClientError.historyGap }
    }

    mutating func beginConnection() { projectionCursor = -1 }
    mutating func setProjectionValues(_ value: [String: Any], at sequence: Int) {
        guard sequence >= projectionCursor else { return }
        projectionCursor = sequence
        projections = value
    }
    mutating func setProjection(key: String, value: Any, at sequence: Int) {
        guard sequence >= projectionCursor else { return }
        projectionCursor = sequence
        projections[key] = value
    }

    func snapshot(state: DSHConnectionState, interactions: [DSHInteraction]) -> DSHChatSnapshot {
        var result = DSHChatSnapshot(sessionID: sessionID)
        result.connectionState = state
        result.interactions = interactions.filter { $0.sessionID == sessionID }
        result.hasMore = hasMore
        result.agentPreset = header["agentPreset"] as? String
        result.title = projections["title"] as? String ?? ""
        let selection = DSHWire.object(projections["modelSelection"])
        let nextSelection = DSHWire.object(selection["next"])
        let selected = nextSelection.isEmpty ? DSHWire.object(selection["lastUsed"]) : nextSelection
        if let provider = selected["provider"] as? String, let model = selected["model"] as? String {
            result.modelSelection = DSHModelSelection(provider: provider, model: model,
                                                     reasoningEffort: selected["reasoningEffort"] as? String)
        }
        var rows: [(Int, DSHChatEntry)] = []
        var toolResults: [String: DSHChatEntry] = [:]
        var openTurn: Int?
        var committedActiveAttempt = false
        for sequence in events.keys.sorted() {
            guard let event = events[sequence] else { continue }
            let data = DSHWire.object(event["data"])
            let type = event["type"] as? String ?? ""
            if type == "turn/start" { result.isRunning = true; openTurn = data["turn"] as? Int }
            if type == "turn/end" { result.isRunning = false; openTurn = nil }
            if type == "session/title" { result.title = data["title"] as? String ?? result.title }
            if let replacement = event["surfaceOp"] as? [String: Any], replacement["op"] as? String == "replace",
               let start = replacement["startSeq"] as? Int, let end = replacement["endSeq"] as? Int {
                rows.removeAll { $0.0 >= start && $0.0 <= end }
            }
            if type == "user/message" {
                let source = DSHWire.object(data["source"])
                guard ["user", "user-question-reply"].contains(source["kind"] as? String ?? "") else { continue }
                rows.append((sequence, entry(message: data, identity: "event-\(sequence)", role: .user)))
            } else if type == "assistant/message" || type == "assistant/attempt" {
                var message = DSHWire.object(data["message"])
                var indexedContent: [(Int, [String: Any])]?
                if message.isEmpty, let records = data["stream"] as? [[String: Any]] {
                    var partial = DSHChatReducer(sessionID: sessionID)
                    for record in records { partial.applyCompactRecord(record) }
                    indexedContent = partial.blocks.keys.sorted().compactMap { index in
                        partial.blocks[index].map { (index, $0) }
                    }
                    message = ["content": indexedContent?.map { $0.1 } ?? []]
                }
                if !message.isEmpty {
                    let row = entry(message: message, identity: settlementIdentities[sequence] ?? "event-\(sequence)",
                                    role: .assistant, turn: data["turn"] as? Int, step: data["step"] as? Int,
                                    indexedContent: indexedContent)
                    rows.append((sequence, row))
                }
                if isActiveSettlement(event) { committedActiveAttempt = true }
            } else if type == "tool/result" {
                let message = DSHWire.object(data["message"]).isEmpty ? data : DSHWire.object(data["message"])
                var row = entry(message: message, identity: "event-\(sequence)", role: .tool,
                                turn: data["turn"] as? Int ?? openTurn, step: data["step"] as? Int)
                row.toolName = data["toolName"] as? String ?? message["toolCallId"] as? String
                row.toolOutput = row.text
                row.toolStatus = message["isError"] as? Bool == true ? "error" : "completed"
                rows.append((sequence, row))
                if let callID = message["toolCallId"] as? String ?? data["callId"] as? String {
                    toolResults[callID] = row
                }
            }
        }
        let knownCalls = Set(rows.flatMap { $0.1.tools.map(\.id) })
        let attachedResultRows = Set(toolResults.filter { knownCalls.contains($0.key) }.map { $0.value.id })
        result.entries = rows.filter { !attachedResultRows.contains($0.1.id) }.map { _, original in
            var row = original
            row.tools = row.tools.map { originalTool in
                var tool = originalTool
                if let output = toolResults[tool.id] {
                    tool.status = output.toolStatus ?? "completed"
                    tool.output = output.text
                } else if openTurn == nil || row.turn != openTurn {
                    tool.status = "unknown"
                    tool.output = NSLocalizedString("执行结果未确认", comment: "DSH remote chat")
                }
                return tool
            }
            var tools = row.tools.makeIterator()
            row.parts = row.parts.map { originalPart in
                var part = originalPart
                if case .tool = part.kind, let tool = tools.next() {
                    part.kind = .tool(tool)
                }
                return part
            }
            if let first = row.tools.first { row.toolStatus = first.status }
            return row
        }
        if activeAttempt != nil, !committedActiveAttempt {
            let content = blocks.keys.sorted().compactMap { index in blocks[index].map { (index, $0) } }
            var live = entry(message: [:], identity: "live-" + (activeAttempt ?? ""), role: .assistant,
                             turn: activeTurn, step: activeStep, indexedContent: content)
            live.isStreaming = !streamSettled
            result.entries.append(live)
            result.isRunning = true
        }
        return result
    }

    private mutating func insert(_ records: [[String: Any]]) {
        for record in records {
            let event = DSHWire.object(record["event"])
            if record["type"] as? String == "event", let sequence = event["seq"] as? Int { events[sequence] = event }
        }
    }

    private func entry(message: [String: Any], identity: String, role: DSHChatRole,
                       turn: Int? = nil, step: Int? = nil,
                       indexedContent: [(Int, [String: Any])]? = nil) -> DSHChatEntry {
        let indexed = indexedContent ?? DSHWire.array(message["content"]).enumerated().map { ($0.offset, $0.element) }
        let content = indexed.map { $0.1 }
        var row = DSHChatEntry(id: identity, role: role)
        row.sourceMessageID = message["id"] as? String
        row.turn = turn
        row.step = step
        row.text = DSHWire.text(content)
        row.reasoning = content.compactMap { $0["type"] as? String == "reasoning" ? $0["text"] as? String : nil }.joined()
        for (index, block) in indexed {
            let kind: DSHChatPartKind
            switch block["type"] as? String {
            case "text": kind = .text(block["text"] as? String ?? "")
            case "reasoning": kind = .reasoning(block["text"] as? String ?? "")
            case "tool-call":
                guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
                let tool = DSHChatTool(id: id, name: name, arguments: block["arguments"] as? String ?? "")
                row.tools.append(tool)
                kind = .tool(tool)
            default: continue
            }
            row.parts.append(DSHChatPart(id: identity + ":part-\(index)", kind: kind))
        }
        if let tool = row.tools.first {
            row.toolName = tool.name
            row.toolOutput = tool.arguments
            row.toolStatus = "running"
        }
        return row
    }

    private mutating func clearAttempt() {
        activeAttempt = nil
        activeTurn = nil
        activeStep = nil
        activeStartedAfterSequence = -1
        nextChunkIndex = 0
        blocks = [:]
        streamSettled = false
    }

    private mutating func applyStream(_ frame: [String: Any]) throws {
        guard let kind = frame["type"] as? String, let id = frame["attemptId"] as? String,
              let revision = frame["revision"] as? Int else { throw DSHClientError.invalidResponse }
        if kind == "start" {
            clearAttempt()
            activeAttempt = id
            activeTurn = frame["turn"] as? Int
            activeStep = frame["step"] as? Int
            activeStartedAfterSequence = frame["startedAfterSeq"] as? Int ?? cursor
            streamRevision = revision
            return
        }
        // Followers may start after an attempt ended; its durable event remains authoritative.
        guard id == activeAttempt else { return }
        guard let index = frame["index"] as? Int else { throw DSHClientError.invalidResponse }
        if kind == "chunk" && index < nextChunkIndex { return }
        guard index == nextChunkIndex, revision == streamRevision + 1 else { throw DSHClientError.historyGap }
        streamRevision = revision
        if kind == "chunk" {
            applyChunk(DSHWire.object(frame["chunk"]))
            nextChunkIndex += 1
        } else if kind == "end" {
            if DSHWire.object(frame["outcome"])["kind"] as? String == "abandoned" { clearAttempt() }
            else { streamSettled = true }
        } else { throw DSHClientError.invalidResponse }
    }

    private func isActiveSettlement(_ event: [String: Any]) -> Bool {
        guard activeAttempt != nil, let sequence = event["seq"] as? Int,
              sequence > activeStartedAfterSequence,
              ["assistant/message", "assistant/attempt"].contains(event["type"] as? String ?? "") else { return false }
        let data = DSHWire.object(event["data"])
        return data["turn"] as? Int == activeTurn && data["step"] as? Int == activeStep
    }

    private mutating func applyCompactRecord(_ record: [String: Any]) {
        let kind = record["type"] as? String ?? ""
        if kind == "chunk" { applyChunk(DSHWire.object(record["chunk"])); return }
        guard let index = record["index"] as? Int else { return }
        if kind == "text-chunks" || kind == "reasoning-chunks" {
            applyChunk(["type": kind == "text-chunks" ? "text-delta" : "reasoning-delta", "index": index,
                        "text": (record["texts"] as? [String] ?? []).joined()])
        } else if kind == "tool-call-chunks" {
            applyChunk(["type": "tool-call-delta", "index": index, "id": record["id"] ?? "",
                        "name": record["name"] ?? "", "argumentsDelta": (record["args"] as? [String] ?? []).joined()])
        }
    }

    private mutating func applyChunk(_ chunk: [String: Any]) {
        guard let index = chunk["index"] as? Int, let kind = chunk["type"] as? String else { return }
        var block = blocks[index] ?? [:]
        switch kind {
        case "block-start": block = ["type": chunk["blockType"] ?? "text", "text": ""]
        case "block-end": block = DSHWire.object(chunk["block"])
        case "text-delta", "reasoning-delta":
            block["type"] = kind == "text-delta" ? "text" : "reasoning"
            block["text"] = (block["text"] as? String ?? "") + (chunk["text"] as? String ?? "")
        case "tool-call-delta":
            block["type"] = "tool-call"
            block["id"] = chunk["id"]
            if let name = chunk["name"] as? String { block["name"] = name }
            block["arguments"] = (block["arguments"] as? String ?? "") + (chunk["argumentsDelta"] as? String ?? "")
        default: return
        }
        blocks[index] = block
    }
}
