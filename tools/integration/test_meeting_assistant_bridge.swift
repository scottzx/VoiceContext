import Foundation
import SwiftUI

@main
struct MeetingAssistantBridgeChecks {
    @MainActor static func main() {
        let bridge = MeetingAssistantBridge()
        var sample: Int64 = 0
        var activeRecordingID = UUID()
        let recordingA = activeRecordingID
        var requests: [MeetingAssistantBridge.Request] = []
        var stopCount = 0
        var openedSession: String?
        var unavailableReason: String?
        bridge.install(
            submit: { requests.append($0) },
            stopSpeech: { stopCount += 1 },
            openSession: { openedSession = $0 },
            permissions: { AnyView(EmptyView()) },
            unavailableReason: { unavailableReason }
        )
        func receive(_ text: String, _ start: Double, _ end: Double,
                     recordingID: UUID? = nil, chunkID: UUID = UUID()) {
            let source = recordingID ?? activeRecordingID
            let startSample = Int64(start * 16_000)
            let endSample = Int64(end * 16_000)
            if source == activeRecordingID { sample = max(sample, endSample) }
            bridge.receive(recordingID: source, chunkID: chunkID, title: "本场会议",
                           segments: [.init(text: text, startSample: startSample, endSample: endSample)],
                           context: "本场已提交的会议文字")
        }
        func updateCapture(_ capturing: Bool) {
            bridge.updateCapture(recordingID: activeRecordingID, capturing: capturing, sample: { sample })
        }

        updateCapture(true)
        receive("小蓝同学，尚未开启的指令。", 0, 1)
        precondition(requests.isEmpty)
        bridge.setEnabled(true, unavailableReason: nil)
        receive("小蓝同学，启用前的迟到指令。", 0, 1)
        precondition(requests.isEmpty)
        let firstChunk = UUID()
        receive("小蓝同学，查今天的待办。", 1, 2, chunkID: firstChunk)
        precondition(requests.count == 1 && bridge.isBusy)
        let first = requests[0]
        precondition(first.recordingID == recordingA && first.command == "查今天的待办。")
        precondition(first.context == "本场已提交的会议文字" && first.title == "本场会议")
        precondition(first.startSample == 16_000 && first.endSample == 32_000)
        bridge.markAccepted(requestID: first.id, sessionID: "session-a")
        bridge.openSession()
        precondition(openedSession == "session-a")
        bridge.showResult(requestID: first.id, text: "还有两件待办", isError: false)
        precondition(bridge.result == "还有两件待办")
        bridge.showSpeechNotice(requestID: first.id, text: "播报失败，请查看文字结果")
        receive("小蓝同学，执行中又来一个请求。", 2, 3)
        precondition(requests.count == 1, "Busy execution must not submit another task")

        precondition(bridge.beginSpeech(requestID: first.id))
        sample = 4 * 16_000
        bridge.endSpeech(requestID: first.id)
        bridge.finish(requestID: first.id)
        precondition(!bridge.isBusy && !bridge.isSpeaking)
        precondition(bridge.speechNotice == "播报失败，请查看文字结果", "Finishing keeps the speech failure notice visible")
        precondition(!bridge.canRespond(to: first.id) && !bridge.beginSpeech(requestID: first.id), "A finished request cannot start a late TTS response")
        bridge.showResult(requestID: first.id, text: "迟到的结果", isError: true)
        precondition(bridge.result == "还有两件待办", "Finishing preserves the result and ignores late callbacks")
        receive("小蓝同学，重复的指令。", 1, 2, chunkID: firstChunk)
        precondition(requests.count == 1)
        receive("小蓝同学，播报尾音。", 4, 4.4)
        receive("小蓝同学，跨越尾音边界。", 4.4, 4.6)
        precondition(requests.count == 1, "Finishing must preserve the extra half-second TTS suppression window")
        receive("小蓝同学，查询明天的日程。", 4.6, 5)
        precondition(requests.count == 2, "Accept new commands after the suppression window")
        precondition(bridge.speechNotice.isEmpty, "A new request clears the previous speech notice")
        let second = requests[1]
        bridge.finish(requestID: second.id)

        bridge.setForeground(false)
        precondition(!bridge.canRespond(to: second.id) && !bridge.beginSpeech(requestID: second.id))
        receive("小蓝同学，后台发言。", 6, 7)
        precondition(requests.count == 2)
        sample = 9 * 16_000
        bridge.setForeground(true)
        receive("小蓝同学，返回前台前的迟到转写。", 7, 8)
        precondition(requests.count == 2)
        receive("小蓝同学，前台的新指令。", 9, 10)
        precondition(requests.count == 3)
        bridge.finish(requestID: requests[2].id)

        sample = 11 * 16_000
        updateCapture(false)
        receive("小蓝同学，暂停后的迟到转写。", 10, 11)
        precondition(requests.count == 3)
        sample = 13 * 16_000
        updateCapture(true)
        receive("小蓝同学，恢复前的迟到转写。", 12, 13)
        precondition(requests.count == 3)
        receive("小蓝同学，恢复后的新指令。", 13, 14)
        precondition(requests.count == 4)
        let fourth = requests[3]
        precondition(bridge.beginSpeech(requestID: fourth.id))
        sample = 15 * 16_000
        let stopsBeforeDisable = stopCount
        bridge.setEnabled(false, unavailableReason: nil)
        precondition(stopCount == stopsBeforeDisable + 1 && !bridge.isSpeaking)
        precondition(!bridge.canRespond(to: fourth.id) && !bridge.beginSpeech(requestID: fourth.id), "Disabling blocks late TTS responses")
        bridge.finish(requestID: fourth.id)
        receive("小蓝同学，关闭后的指令。", 15, 16)
        precondition(requests.count == 4)
        bridge.setEnabled(true, unavailableReason: nil)
        receive("小蓝同学，重新开启前的指令。", 15, 16)
        precondition(requests.count == 4)
        receive("小蓝同学，重新开启后的指令。", 16, 17)
        precondition(requests.count == 5)
        let oldRequest = requests[4]
        bridge.markAccepted(requestID: oldRequest.id, sessionID: "old-recording-session")
        precondition(bridge.beginSpeech(requestID: oldRequest.id))

        activeRecordingID = UUID()
        sample = 0
        updateCapture(true)
        precondition(!bridge.enabled && !bridge.isBusy && !bridge.isSpeaking)
        precondition(bridge.lastCommand.isEmpty && bridge.result.isEmpty && bridge.sessionID == nil)
        precondition(!bridge.canRespond(to: oldRequest.id) && !bridge.beginSpeech(requestID: oldRequest.id))
        bridge.markAccepted(requestID: oldRequest.id, sessionID: "late-old-session")
        bridge.showStatus(requestID: oldRequest.id, text: "旧任务状态")
        bridge.showResult(requestID: oldRequest.id, text: "旧任务结果", isError: false)
        bridge.finish(requestID: oldRequest.id)
        precondition(bridge.result.isEmpty && bridge.sessionID == nil)
        bridge.setEnabled(true, unavailableReason: nil)
        receive("小蓝同学，另一场会议的迟到结果。", 20, 21, recordingID: recordingA)
        precondition(requests.count == 5)
        receive("小蓝同学，新会议的指令。", 0, 1)
        precondition(requests.count == 6, "A new recording must clear the previous recording's sample baseline and suppression")
        let current = requests[5]
        precondition(current.recordingID == activeRecordingID)
        bridge.finish(requestID: oldRequest.id)
        precondition(bridge.isBusy, "An old request cannot finish a newer recording's task")
        bridge.showResult(requestID: oldRequest.id, text: "旧任务晚到结果", isError: true)
        precondition(bridge.result.isEmpty)
        precondition(bridge.beginSpeech(requestID: current.id))
        sample = 2 * 16_000
        bridge.endSpeech(requestID: current.id)
        bridge.finish(requestID: current.id)

        receive("小蓝同学", 3, 4)
        updateCapture(false)
        sample = 6 * 16_000
        updateCapture(true)
        receive("恢复后的普通会议发言。", 6, 7)
        precondition(requests.count == 6, "Pausing clears a standalone wake word")
        bridge.setEnabled(false, unavailableReason: nil)
        unavailableReason = "请先配置智能体模型"
        bridge.setEnabled(true, unavailableReason: nil)
        precondition(!bridge.enabled && bridge.status == unavailableReason)
        print("Meeting assistant enablement, lifecycle, late results, TTS tail and recording isolation checks passed")
    }
}
