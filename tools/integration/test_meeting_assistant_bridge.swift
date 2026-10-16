import Foundation
import SwiftUI

@MainActor final class MeetingFixture {
    let bridge = MeetingAssistantBridge()
    var sample: Int64 = 0
    var recordingID = UUID()
    var generationID: UUID?
    var boundary: Int64 = 0
    var requests: [MeetingAssistantBridge.Request] = []
    var readyIDs: [UUID] = []
    var cueCount = 0
    var stopCount = 0
    var openedSession: String?
    let segmentID = UUID()
    let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

    init() {
        bridge.install(submit: { [unowned self] in requests.append($0) },
                       stopSpeech: { [unowned self] in stopCount += 1 },
                       openSession: { [unowned self] in openedSession = $0 },
                       permissions: { AnyView(EmptyView()) }, unavailableReason: { nil },
                       ready: { [unowned self] in readyIDs.append($0) },
                       wakeFeedback: { [unowned self] in cueCount += 1 })
        bridge.installWakeCapture { [unowned self] generation, afterSample in
            generationID = generation
            boundary = afterSample
        }
        capture(true)
    }
    func capture(_ active: Bool) {
        bridge.updateCapture(recordingID: recordingID, capturing: active, sample: { [unowned self] in sample })
    }
    func enable() {
        bridge.setEnabled(true, unavailableReason: nil)
        ready()
    }
    func ready() {
        if let generationID { bridge.wakeReady(generationID: generationID) }
    }
    func wake() {
        bridge.receiveWake(recordingID: recordingID, generationID: generationID!)
    }
    func reserve() -> UUID {
        let id = bridge.beginVoiceCommand(recordingID: recordingID, generationID: generationID!,
                                         startSample: max(sample, boundary), endSample: max(sample, boundary) + 16_000)!
        precondition(generationID == nil, "Busy ASR immediately stops wake capture")
        return id
    }
    func submit(_ id: UUID, text: String = "小兰同学，查询今天的日程。") {
        bridge.submitVoiceCommand(requestID: id, recordingID: recordingID, title: "本场会议",
                                  text: text, transcriptSegments: [
                                    .init(id: segmentID, startSample: 0, endSample: 16_000,
                                          text: "已提交的本场文稿", speaker: "发言人一")
                                  ], recordingStartedAt: startedAt,
                                  startSample: sample, endSample: sample + 16_000)
    }
    func finish(_ id: UUID) {
        bridge.finish(requestID: id)
        ready()
    }
}

@main struct MeetingAssistantBridgeChecks {
    @MainActor static func main() {
        let f = MeetingFixture()
        let b = f.bridge
        precondition(f.generationID == nil)
        b.setEnabled(true, unavailableReason: nil)
        let loadingGeneration = f.generationID!
        precondition(b.status == "正在准备唤醒模型")
        precondition(b.beginVoiceCommand(recordingID: f.recordingID, generationID: loadingGeneration,
                                        startSample: 0, endSample: 16_000) == nil)
        f.ready()
        let readyID = f.readyIDs[0]
        precondition(b.canSpeak(to: readyID) && !b.canRespond(to: readyID))
        precondition(!b.isSpeaking && f.generationID != nil, "Synthesis waiting leaves wake capture available")
        b.setEnabled(true, unavailableReason: nil)
        precondition(f.readyIDs.count == 1)
        f.wake()
        precondition(f.cueCount == 1 && !b.canSpeak(to: readyID))
        precondition(b.messages.last?.text == "已唤醒，正在听；请说出任务")
        let first = f.reserve()
        f.submit(first)
        precondition(f.requests.count == 1 && f.requests[0].command == "查询今天的日程。")
        precondition(f.requests[0].transcriptSegments?.first?.text == "已提交的本场文稿")
        precondition(f.requests[0].transcriptSegments?.first?.id == f.segmentID)
        precondition(f.requests[0].recordingStartedAt == f.startedAt)
        f.submit(first)
        precondition(f.requests.count == 1, "Repeated ASR delivery cannot execute twice")
        b.markAccepted(requestID: first, sessionID: "session-a")
        b.openSession()
        precondition(f.openedSession == "session-a")
        b.showResult(requestID: first, text: "有两项日程", isError: false)
        let count = b.messages.count
        b.showResult(requestID: first, text: "有两项日程", isError: false)
        precondition(b.messages.count == count)
        precondition(b.beginSpeech(requestID: first))
        b.updateSpeechOutputLevel(0.7, requestID: first)
        precondition(b.speechOutputLevel == 0.7)
        b.updateSpeechOutputLevel(1, requestID: UUID())
        precondition(b.speechOutputLevel == 0.7, "Stale output meters cannot animate a newer reply")
        b.updateSpeechOutputLevel(.infinity, requestID: first)
        precondition(b.speechOutputLevel == 0)
        b.updateSpeechOutputLevel(2, requestID: first)
        precondition(b.speechOutputLevel == 1)
        precondition(!b.beginSpeech(requestID: first) && f.generationID == nil)
        b.endSpeech(requestID: UUID())
        precondition(b.isSpeaking)
        f.sample = 32_000
        b.endSpeech(requestID: first)
        precondition(b.speechOutputLevel == 0)
        b.updateSpeechOutputLevel(0.5, requestID: first)
        precondition(b.speechOutputLevel == 0)
        f.finish(first)
        precondition(f.boundary == 40_000, "Half-second playback tail remains suppressed")
        precondition(!b.canRespond(to: first) && !b.beginSpeech(requestID: first))
        let nextGeneration = f.generationID!
        b.receiveWake(recordingID: f.recordingID, generationID: loadingGeneration)
        precondition(f.cueCount == 1, "Old generation wake callbacks are ignored")
        precondition(b.beginVoiceCommand(recordingID: f.recordingID, generationID: nextGeneration,
                                        startSample: 39_999, endSample: 50_000) == nil)
        f.wake()
        let empty = f.reserve()
        f.submit(empty, text: "小，兰 同学。")
        precondition(f.requests.count == 1 && !b.isBusy, "An isolated keyword is never a task")
        f.ready()
        f.wake()
        let second = f.reserve()
        f.submit(second, text: "查一下待办")
        precondition(f.requests.count == 2 && f.requests[1].command == "查一下待办")
        precondition(b.sessionID == "session-a", "Submitting another command keeps this recording's chat link")
        b.setForeground(false)
        precondition(!b.canRespond(to: second) && f.generationID == nil && !b.isBusy)
        f.sample = 64_000
        b.setForeground(true)
        f.ready()
        f.submit(second, text: "迟到的旧指令")
        precondition(f.requests.count == 2 && !b.canSpeak(to: second))
        f.wake()
        let paused = f.reserve()
        f.capture(false)
        f.capture(true)
        f.ready()
        precondition(b.sessionID == "session-a", "Pause/resume keeps this recording's chat link")
        f.submit(paused)
        precondition(f.requests.count == 2 && !b.canRespond(to: paused))
        f.wake()
        let disabled = f.reserve()
        b.setEnabled(false, unavailableReason: nil)
        f.enable()
        precondition(b.sessionID == "session-a", "Disabling/re-enabling keeps this recording's chat link")
        f.submit(disabled)
        precondition(f.requests.count == 2 && f.readyIDs.count == 2)
        f.wake()
        let oldRecording = f.reserve()
        let oldID = f.recordingID
        f.recordingID = UUID()
        f.sample = 0
        f.capture(true)
        precondition(!b.enabled && b.messages.isEmpty && b.sessionID == nil)
        f.enable()
        b.submitVoiceCommand(requestID: oldRecording, recordingID: oldID, title: "旧会议",
                             text: "旧命令", transcriptSegments: nil, recordingStartedAt: nil,
                             startSample: 0, endSample: 1)
        precondition(f.requests.count == 2)
        f.wake()
        let current = f.reserve()
        f.submit(current)
        b.finish(requestID: oldRecording)
        precondition(b.isBusy && b.canRespond(to: current))
        f.finish(current)
        precondition(f.boundary == 0, "A different recording clears playback tail")
        let liveGeneration = f.generationID!
        f.wake()
        b.wakeTimedOut(generationID: liveGeneration)
        precondition(b.status.contains("等待"))
        b.setEnabled(false, unavailableReason: nil)
        b.setEnabled(true, unavailableReason: "预装唤醒模型缺失或损坏，请重新安装应用")
        precondition(!b.enabled && b.messages.last?.isError == true)
        b.setEnabled(true, unavailableReason: nil)
        b.wakeFailed(generationID: f.generationID!, text: "无法加载预装唤醒词模型。")
        precondition(!b.enabled && f.generationID == nil)
        print("Acoustic authorization, homophones, single delivery, readiness, lifecycle and TTS tail passed")
    }
}
