import Foundation

/// Explicitly delivers one public answer for one active meeting request.
/// Plain assistant text and reasoning never enter this path.
@MainActor
enum MeetingAnswerUserTool {
    static let definition = AgentToolDefinition(
        name: "answer_user",
        description: "Deliver one public response for the current voice turn: a brief acknowledgement of a verified task-start receipt, a verified completion result, or a necessary question. Starting a task is not completing it; later background completion gets a separate delivery turn. Only the explicit text argument is displayed and spoken by the host; ordinary assistant text and reasoning are not delivered. Keep it brief, factual and in the user's language. A delivered/already_delivered/in_progress receipt must not trigger another answer or repeat business operations. A stale receipt means the voice request is no longer available; do not retry its actions.",
        parameters: [
            "text": AgentToolParam(type: .string, description: "The public answer only: 1–2000 characters, usually one to three brief sentences. No internal reasoning or tool plans.")
        ],
        required: ["text"]
    )

    private struct Binding {
        let requestID: UUID
        let deliver: @MainActor (String) async -> Bool
        var claimed = false
        var inFlight = false
        var delivered = false
    }
    private static var bindings: [String: Binding] = [:]

    static func bind(sessionID: String, requestID: UUID,
                     deliver: @escaping @MainActor (String) async -> Bool) {
        // Rebinding the same request cannot reset its once-only delivery claim.
        guard bindings[sessionID]?.requestID != requestID else { return }
        bindings[sessionID] = Binding(requestID: requestID, deliver: deliver)
    }

    /// A typed turn in a voice session owns its own request; its answer is shown
    /// in the chat only. Returns nil while a voice request already owns the session.
    static func bindTypedTurn(sessionID: String) -> UUID? {
        guard bindings[sessionID] == nil else { return nil }
        let requestID = UUID()
        bindings[sessionID] = Binding(requestID: requestID, deliver: { _ in true })
        return requestID
    }

    static func unbind(sessionID: String, requestID: UUID) {
        guard bindings[sessionID]?.requestID == requestID else { return }
        bindings.removeValue(forKey: sessionID)
    }

    static func didDeliver(sessionID: String, requestID: UUID) -> Bool {
        guard let binding = bindings[sessionID], binding.requestID == requestID else { return false }
        return binding.delivered
    }

    static func didDeliver(sessionID: String?) -> Bool {
        guard !Task.isCancelled, let sessionID else { return false }
        return bindings[sessionID]?.delivered == true
    }

    /// Business tools must belong to the live request and finish before its answer.
    static func activeRequestID(sessionID: String) -> UUID? {
        guard !Task.isCancelled, let binding = bindings[sessionID], !binding.claimed else { return nil }
        return binding.requestID
    }

    /// A missing tool call may get one delivery-only round. Never retry a
    /// claimed answer, including an in-flight or rejected/stale delivery.
    static func canRequestDelivery(sessionID: String?) -> Bool {
        guard !Task.isCancelled, let sessionID, let binding = bindings[sessionID] else { return false }
        return !binding.claimed
    }

    static let deliveryReminder = """
        <system-reminder>
        [meeting-answer-delivery]
        本回合尚未实际调用 answer_user 工具交付公开答复，普通文字或写出工具名都不算交付。这是唯一一次补交付机会，不是新任务。
        只根据本回合已有的已验证工具结果，调用一次 answer_user，参数只传 text。简短告知真实结果、已确认的任务启动状态或必要的问题，不包含思考过程。
        不得重新查询、重复创建/修改事项、重派子任务或调用其他工具。未确认的结果不能声称成功；如任务失败或资料不足，直接用 answer_user 如实告知。
        </system-reminder>
        """

    static func execute(_ args: [String: Any], sessionID: String?, sessionSource: String?) async
        -> (output: String, success: Bool) {
        guard AgentRuntimePolicies.policy(for: sessionSource).replyDelivery?.definition.name == definition.name, let sessionID else {
            return receipt("wrong_session", success: false, message: "This interaction has no configured public-answer delivery capability.")
        }
        guard args.count == 1, let raw = args["text"] as? String,
              raw.count <= 2_000 else {
            return receipt("invalid_arguments", success: false, message: "Pass only text: a non-empty string of at most 2000 characters.")
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return receipt("invalid_arguments", success: false, message: "text must not be empty or whitespace.")
        }
        guard !Task.isCancelled, var binding = bindings[sessionID] else {
            return receipt("stale", success: false, message: "No active voice request. Do not repeat its business operations.")
        }
        if binding.claimed {
            if binding.delivered {
                return receipt("already_delivered", success: true, requestID: binding.requestID,
                               message: "The public answer is already delivered. Do not resend or repeat business operations.")
            }
            return receipt(binding.inFlight ? "in_progress" : "stale", success: binding.inFlight,
                           requestID: binding.requestID,
                           message: "This request's answer has already been claimed. Do not resend or repeat business operations.")
        }
        // Claim before suspension so parallel calls can never deliver twice.
        binding.claimed = true
        binding.inFlight = true
        bindings[sessionID] = binding
        let delivered = await binding.deliver(text)
        if var current = bindings[sessionID], current.requestID == binding.requestID {
            current.inFlight = false
            current.delivered = delivered
            bindings[sessionID] = current
        }
        // The callback reports public text delivery, independently of TTS.
        // Closing after it was displayed must not turn delivery into a retry.
        return receipt(delivered ? "delivered" : "stale", success: delivered,
                       requestID: binding.requestID,
                       message: delivered
                        ? "Public answer delivered. Speech is handled by the host; a speech failure does not undo text delivery. Do not resend or repeat business operations."
                        : "The request no longer accepts an answer. Do not repeat its business operations.")
    }

    private static func receipt(_ status: String, success: Bool, requestID: UUID? = nil,
                                message: String) -> (output: String, success: Bool) {
        var data: [String: String] = ["status": status, "message": message]
        if let requestID { data["request_id"] = requestID.uuidString }
        let json = try! JSONSerialization.data(withJSONObject: data, options: [.sortedKeys])
        return (String(decoding: json, as: UTF8.self), success)
    }
}
