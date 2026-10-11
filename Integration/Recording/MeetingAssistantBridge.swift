import Combine
import Foundation
import SwiftUI

/// The recorder publishes committed text; the host owns Agent and TTS execution.
@MainActor
public final class MeetingAssistantBridge: ObservableObject {
    public static let shared = MeetingAssistantBridge()

    public struct Request: Sendable {
        public let id: UUID
        public let recordingID: UUID
        public let title: String
        public let command: String
        public let context: String
        public let startSample: Int64
        public let endSample: Int64
    }

    @Published public private(set) var enabled = false
    @Published public private(set) var isBusy = false
    @Published public private(set) var isSpeaking = false
    @Published public private(set) var status = "说“小蓝同学”后交代任务"
    @Published public private(set) var lastCommand = ""
    @Published public private(set) var result = ""
    @Published public private(set) var speechNotice = ""
    @Published public private(set) var sessionID: String?

    private var recordingID: UUID?
    private var capturing = false
    private var foreground = true
    private var currentRequestID: UUID?
    private var speechStart: Int64?
    private var speechSuppressedThrough: Int64 = 0
    private var detector = MeetingWakeCommandDetector()
    private var sampleProvider: (() -> Int64)?
    private var submit: ((Request) -> Void)?
    private var stopSpeechHandler: (() -> Void)?
    private var openSessionHandler: ((String) -> Void)?
    private var unavailableReason: (() -> String?)?
    var permissions: (() -> AnyView)?

    public func install(
        submit: @escaping @MainActor (Request) -> Void,
        stopSpeech: @escaping @MainActor () -> Void,
        openSession: @escaping @MainActor (String) -> Void,
        permissions: @escaping @MainActor () -> AnyView,
        unavailableReason: @escaping @MainActor () -> String?
    ) {
        self.submit = submit
        stopSpeechHandler = stopSpeech
        openSessionHandler = openSession
        self.permissions = permissions
        self.unavailableReason = unavailableReason
    }

    func updateCapture(recordingID: UUID?, capturing: Bool, sample: @escaping () -> Int64) {
        if self.recordingID != recordingID {
            stopSpeech()
            enabled = false
            isBusy = false
            currentRequestID = nil
            speechSuppressedThrough = 0
            lastCommand = ""
            result = ""
            speechNotice = ""
            sessionID = nil
        }
        self.recordingID = recordingID
        sampleProvider = sample
        if self.capturing != capturing || recordingID == nil {
            detector.reset(afterSample: max(sample(), speechSuppressedThrough))
        }
        self.capturing = capturing
        if !capturing { stopSpeech() }
        if recordingID == nil { enabled = false }
        updateWaitingStatus()
    }

    public func setForeground(_ foreground: Bool) {
        self.foreground = foreground
        detector.reset(afterSample: max(sampleProvider?() ?? 0, speechSuppressedThrough))
        if !foreground { stopSpeech() }
        updateWaitingStatus()
    }

    func setEnabled(_ enabled: Bool, unavailableReason: String?) {
        if enabled, let reason = unavailableReason ?? self.unavailableReason?() {
            status = reason
            return
        }
        guard !enabled || (capturing && foreground && recordingID != nil && submit != nil) else {
            status = "请在前台会议录音中开启会中助手"
            return
        }
        self.enabled = enabled
        detector.reset(afterSample: max(sampleProvider?() ?? 0, speechSuppressedThrough))
        if !enabled { stopSpeech() }
        updateWaitingStatus()
    }

    func receive(recordingID: UUID, chunkID: UUID, title: String,
                 segments: [MeetingWakeCommandDetector.Segment], context: String) {
        guard enabled, capturing, foreground, self.recordingID == recordingID,
              !isBusy, !isSpeaking, let submit else { return }
        guard let command = detector.consume(chunkID: chunkID, segments: segments),
              let first = segments.first, let last = segments.last else { return }
        let request = Request(id: UUID(), recordingID: recordingID, title: title,
                              command: command, context: context,
                              startSample: first.startSample, endSample: last.endSample)
        currentRequestID = request.id
        lastCommand = command
        result = ""
        speechNotice = ""
        sessionID = nil
        isBusy = true
        status = "已识别指令，正在接单"
        submit(request)
    }

    public func markAccepted(requestID: UUID, sessionID: String) {
        guard currentRequestID == requestID else { return }
        self.sessionID = sessionID
        status = "收到，正在执行；完成后可继续唤起"
    }

    public func showStatus(requestID: UUID, text: String) {
        guard currentRequestID == requestID else { return }
        status = text
    }

    public func showResult(requestID: UUID, text: String, isError: Bool) {
        guard currentRequestID == requestID else { return }
        result = text
        status = isError ? "任务需要注意" : "已收到执行回复"
    }

    public func showSpeechNotice(requestID: UUID, text: String) {
        guard currentRequestID == requestID else { return }
        speechNotice = text
    }

    public func finish(requestID: UUID) {
        guard currentRequestID == requestID else { return }
        endSpeech(requestID: requestID)
        currentRequestID = nil
        isBusy = false
        detector.reset(afterSample: max(sampleProvider?() ?? 0, speechSuppressedThrough))
        updateWaitingStatus()
    }

    public func canRespond(to requestID: UUID) -> Bool {
        currentRequestID == requestID && enabled && capturing && foreground
    }

    public func beginSpeech(requestID: UUID) -> Bool {
        guard canRespond(to: requestID) else { return false }
        speechStart = sampleProvider?()
        isSpeaking = true
        return true
    }

    public func endSpeech(requestID: UUID) {
        guard currentRequestID == requestID else { return }
        if let start = speechStart {
            speechSuppressedThrough = max(speechSuppressedThrough, (sampleProvider?() ?? start) + 8_000)
            detector.suppress(from: start, to: speechSuppressedThrough)
        }
        speechStart = nil
        isSpeaking = false
    }

    func stopSpeech() {
        stopSpeechHandler?()
        if let id = currentRequestID { endSpeech(requestID: id) }
    }

    func openSession() {
        if let sessionID { openSessionHandler?(sessionID) }
    }

    private func updateWaitingStatus() {
        guard !isBusy else { return }
        if !enabled { status = "说“小蓝同学”后交代任务" }
        else if !foreground { status = "已暂停唤醒，返回前台后继续" }
        else if !capturing { status = "录音已暂停，助手等待继续" }
        else { status = "等待“小蓝同学”；说完稍作停顿" }
    }
}

struct MeetingAssistantPanel: View {
    let model: RecordingCoreModel
    @ObservedObject private var assistant = MeetingAssistantBridge.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: YimaDesign.Space.sm) {
            Toggle("会中助手", isOn: Binding(
                get: { assistant.enabled },
                set: { model.setMeetingAssistantEnabled($0) }
            ))
            .tint(YimaDesign.Color.ink)
            .font(YimaDesign.Typography.metadata)
            .frame(minHeight: YimaDesign.Layout.hitTarget)
            Text(LocalizedStringKey(assistant.status))
                .font(YimaDesign.Typography.compactMetadata)
                .foregroundStyle(YimaDesign.Color.muted)
            if assistant.enabled {
                Text("本场文字将交给已配置的智能体处理；外放回复可能进入录音。")
                    .font(YimaDesign.Typography.compactMetadata)
                    .foregroundStyle(YimaDesign.Color.muted)
            }
            if !assistant.lastCommand.isEmpty {
                Text(assistant.lastCommand)
                    .font(YimaDesign.Typography.metadata)
                    .lineLimit(2)
            }
            if !assistant.result.isEmpty {
                Text(assistant.result)
                    .font(YimaDesign.Typography.metadata)
                    .lineLimit(3)
            }
            if !assistant.speechNotice.isEmpty {
                Text(LocalizedStringKey(assistant.speechNotice))
                    .font(YimaDesign.Typography.compactMetadata)
                    .foregroundStyle(YimaDesign.Color.muted)
            }
            if assistant.sessionID != nil || assistant.isSpeaking {
                HStack {
                    if assistant.sessionID != nil {
                        Button {
                            dismiss()
                            DispatchQueue.main.async { assistant.openSession() }
                        } label: {
                            Text("查看对话")
                                .frame(minHeight: YimaDesign.Layout.hitTarget)
                                .contentShape(Rectangle())
                        }
                    }
                    Spacer()
                    if assistant.isSpeaking {
                        Button { assistant.stopSpeech() } label: {
                            Text("停止播报")
                                .frame(minHeight: YimaDesign.Layout.hitTarget)
                                .contentShape(Rectangle())
                        }
                    }
                }
                .font(YimaDesign.Typography.metadata)
                .buttonStyle(.plain)
                .frame(minHeight: YimaDesign.Layout.hitTarget)
            }
        }
        .padding(.horizontal, YimaDesign.Layout.pageInset)
        .background { if let permissions = assistant.permissions { permissions() } }
    }
}
