import Foundation
import CoreFoundation

/// The voice assistant selects library IDs; paths and audio session ownership stay native.
@MainActor
enum StoryPlayerTool {
    static let definition = AgentToolDefinition(
        name: "story_player",
        description: "Control the installed children's story extension during the current user-authorized voice request, including its background or locked-screen continuation. Actions: list, status, play, pause, resume, next, stop, seek. Call list before selecting a story and use its exact story_id; never guess IDs or accept file paths/URLs. Match the user's title against real list results; ask which one when no unique match exists. Playback receipts contain the real state. waiting_for_voice means playback is queued until the voice reply finishes, so do not say audio is already playing. Only playing confirms active playback. Natural completion is recorded in the originating conversation with its playback_id; that event is not a new user request. Child executors and completion-notice turns cannot use this tool.",
        parameters: [
            "action": .init(type: .string, description: "Story player action", enumValues: ["list", "status", "play", "pause", "resume", "next", "stop", "seek"]),
            "story_id": .init(type: .string, description: "Exact story_id from list; required only for play"),
            "position_seconds": .init(type: .integer, description: "Whole-second playback position from zero through the current duration; required only for seek")
        ], required: ["action"]
    )

    struct Invocation {
        let action: String
        let storyID: UUID?
        let position: TimeInterval?
    }

    static func invocation(_ args: [String: Any]) throws -> Invocation {
        func invalid(_ message: String) -> NSError {
            NSError(domain: "Yima.StoryPlayer", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        guard let action = args["action"] as? String,
              ["list", "status", "play", "pause", "resume", "next", "stop", "seek"].contains(action) else {
            throw invalid("Unsupported story player action.")
        }
        let allowed: Set<String> = action == "play" ? ["action", "story_id"] : action == "seek" ? ["action", "position_seconds"] : ["action"]
        guard Set(args.keys).isSubset(of: allowed) else { throw invalid("Unexpected story player argument.") }
        var storyID: UUID?
        if action == "play" {
            guard let raw = args["story_id"] as? String, let id = UUID(uuidString: raw) else {
                throw invalid("play requires an exact story_id from list.")
            }
            storyID = id
        }
        var position: TimeInterval?
        if action == "seek" {
            guard let number = args["position_seconds"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                  number.doubleValue >= 0, number.doubleValue.rounded() == number.doubleValue else {
                throw invalid("position_seconds must be a finite non-negative whole number.")
            }
            position = number.doubleValue
        }
        return .init(action: action, storyID: storyID, position: position)
    }

    static func execute(_ args: [String: Any], sessionID: String?, sessionSource: String?,
                        isExecutor: Bool, noticeDriven: Bool, voiceGeneration: UInt64?) -> (output: String, success: Bool) {
        func output(_ body: [String: Any], success: Bool) -> (String, Bool) {
            let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
            return (String(decoding: data, as: UTF8.self), success)
        }
        let policy = AgentRuntimePolicies.policy(for: sessionSource)
        guard !isExecutor, !noticeDriven, sessionSource == "xiaolan_voice",
              policy.allowedToolNames(noticeDriven: false)?.contains(definition.name) == true else {
            return output(["status": "forbidden", "message": "只有当前独立语音主请求可以控制儿童故事机；子任务执行器和完成通知回合不能控制播放。"], success: false)
        }
        guard !Task.isCancelled else {
            return output(["status": "stale", "message": "本次请求已取消，未执行故事机操作。"], success: false)
        }
        guard let sessionID, !sessionID.isEmpty, let voiceGeneration,
              XiaolanVoiceController.shared.executionGeneration(sessionID: sessionID) == voiceGeneration else {
            return output(["status": "stale", "message": "这条语音请求已失效，未执行故事机操作。"], success: false)
        }
        let request: Invocation
        do { request = try invocation(args) }
        catch { return output(["status": "invalid_arguments", "message": error.localizedDescription], success: false) }
        let library = StoryLibraryStore.shared
        let player = StoryPlaybackController.shared
        if request.action == "list" {
            if let error = library.loadError { return output(["status": "failed", "message": error], success: false) }
            return output(["status": "available", "stories": library.stories.map {
                ["story_id": $0.id.uuidString, "title": $0.title, "duration_seconds": $0.duration] as [String: Any]
            }, "state": player.snapshot()], success: true)
        }
        do {
            switch request.action {
            case "play":
                guard let story = library.stories.first(where: { $0.id == request.storyID }) else {
                    return output(["status": "not_found", "message": "故事已不存在。请重新读取故事列表，按真实标题选择；无唯一匹配时询问用户。"], success: false)
                }
                try player.play(story, sourceSessionID: sessionID)
            case "pause": player.pause()
            case "resume": try player.resume(sourceSessionID: sessionID)
            case "next": try player.next(sourceSessionID: sessionID)
            case "stop": player.stop()
            case "seek":
                guard player.currentStoryID != nil, player.duration.isFinite,
                      let position = request.position, position <= player.duration else {
                    return output(["status": "invalid_arguments", "message": "请先查询当前故事状态，跳转位置必须在零到当前时长之间。"], success: false)
                }
                try player.seek(to: position)
            default: break
            }
            let state = player.snapshot()
            let status = state["status"] as? String ?? "available"
            let message: String
            switch status {
            case "waiting_for_voice": message = "播放请求已准备，将在本轮语音回复结束后开始；当前还没有播放出声。"
            case "playing": message = "故事正在播放。"
            case "paused": message = "故事已暂停，保留当前进度。"
            case "stopped": message = "故事已停止。"
            case "finished": message = "当前故事已播放完毕。"
            default: message = "已读取故事机当前状态。"
            }
            return output(["status": status, "action": request.action, "message": message, "state": state], success: true)
        } catch {
            return output(["status": "failed", "message": error.localizedDescription, "state": player.snapshot()], success: false)
        }
    }
}
