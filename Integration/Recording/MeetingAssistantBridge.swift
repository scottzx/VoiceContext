import Combine
import Foundation
import SwiftUI

/// Acoustic wake events authorize bounded commands; the host owns Agent and TTS.
@MainActor
public final class MeetingAssistantBridge: ObservableObject {
    public static let shared = MeetingAssistantBridge()
    public static let readyAnnouncement = "我已入会，有事叫小蓝同学"

    public struct Message: Identifiable, Sendable {
        public enum Kind: Equatable, Sendable { case user, assistant, status }
        public let id = UUID()
        public let kind: Kind
        public let text: String
        public let isError: Bool
    }

    public struct TranscriptSegment: Codable, Equatable, Sendable {
        public let id: UUID
        public let startSample: Int64
        public let endSample: Int64
        public let text: String
        public let speaker: String?
    }

    public struct Request: Sendable {
        public let id: UUID
        public let recordingID: UUID
        public let title: String
        public let command: String
        public let transcriptSegments: [TranscriptSegment]?
        public let recordingStartedAt: Date?
        public let startSample: Int64
        public let endSample: Int64
    }

    @Published public private(set) var enabled = false
    @Published public private(set) var isBusy = false
    @Published public private(set) var isSpeaking = false
    @Published public private(set) var speechOutputLevel: Float = 0
    @Published public private(set) var status = "说“小蓝同学”后交代任务"
    @Published public private(set) var lastCommand = ""
    @Published public private(set) var result = ""
    @Published public private(set) var speechNotice = ""
    @Published public private(set) var sessionID: String?
    @Published public private(set) var messages: [Message] = []
    public private(set) var responseGeneration = UUID()

    private var recordingID: UUID?
    private var capturing = false
    private var foreground = true
    private var isListeningForCommand = false
    private var currentRequestID: UUID?
    private var submittedRequestID: UUID?
    private var readySpeechID: UUID?
    private var readyWasAnnounced = false
    private var actualSpeechID: UUID?
    private var speechStart: Int64?
    private var speechSuppressedThrough: Int64 = 0
    private var wakeGenerationID: UUID?
    private var wakeIsReady = false
    private var wakeCaptureHandler: ((UUID?, Int64) -> Void)?
    private var wakeFeedbackHandler: (() -> Void)?
    private var sampleProvider: (() -> Int64)?
    private var submit: ((Request) -> Void)?
    private var stopSpeechHandler: (() -> Void)?
    private var openSessionHandler: ((String) -> Void)?
    private var unavailableReason: (() -> String?)?
    private var readyHandler: ((UUID) -> Void)?
    private var replyIdleHandler: (() -> Void)?
    private var lastResultRequestID: UUID?
    private var lastResultWasError = false
    var permissions: (() -> AnyView)?

    public func install(
        submit: @escaping @MainActor (Request) -> Void,
        stopSpeech: @escaping @MainActor () -> Void,
        openSession: @escaping @MainActor (String) -> Void,
        permissions: @escaping @MainActor () -> AnyView,
        unavailableReason: @escaping @MainActor () -> String?,
        ready: @escaping @MainActor (UUID) -> Void = { _ in },
        wakeFeedback: @escaping @MainActor () -> Void = {}
    ) {
        self.submit = submit
        stopSpeechHandler = stopSpeech
        openSessionHandler = openSession
        self.permissions = permissions
        self.unavailableReason = unavailableReason
        readyHandler = ready
        wakeFeedbackHandler = wakeFeedback
    }

    func installWakeCapture(_ handler: @escaping @MainActor (UUID?, Int64) -> Void) {
        wakeCaptureHandler = handler
        reconcileWakeCapture(forceReset: true)
    }

    public func installReplyIdleHandler(_ handler: @escaping @MainActor () -> Void) {
        replyIdleHandler = handler
    }

    func updateCapture(recordingID: UUID?, capturing: Bool, sample: @escaping () -> Int64) {
        let changed = self.recordingID != recordingID || self.capturing != capturing
        if self.recordingID != recordingID {
            responseGeneration = UUID()
            isListeningForCommand = false
            stopSpeech()
            enabled = false
            isBusy = false
            currentRequestID = nil
            speechSuppressedThrough = 0
            lastCommand = ""
            result = ""
            speechNotice = ""
            sessionID = nil
            messages.removeAll()
            lastResultRequestID = nil
        }
        self.recordingID = recordingID
        sampleProvider = sample
        self.capturing = capturing
        if !capturing { invalidateResponse() }
        if recordingID == nil { enabled = false }
        reconcileWakeCapture(forceReset: changed)
        updateWaitingStatus()
    }

    public func setForeground(_ foreground: Bool) {
        self.foreground = foreground
        if !foreground { invalidateResponse() }
        reconcileWakeCapture(forceReset: true)
        updateWaitingStatus()
    }

    func setEnabled(_ enabled: Bool, unavailableReason: String?) {
        guard self.enabled != enabled else { return }
        if enabled, let reason = unavailableReason ?? self.unavailableReason?() {
            status = reason
            appendMessage(.status, text: reason, isError: true)
            return
        }
        guard !enabled || (capturing && foreground && recordingID != nil && submit != nil) else {
            status = "请在前台会议录音中开启会中助手"
            appendMessage(.status, text: status, isError: true)
            return
        }
        self.enabled = enabled
        if !enabled { invalidateResponse() }
        reconcileWakeCapture(forceReset: true)
        updateWaitingStatus()
        if enabled {
            let id = UUID()
            readySpeechID = id
            readyWasAnnounced = false
            speechNotice = ""
        }
    }

    func wakeReady(generationID: UUID) {
        guard wakeGenerationID == generationID else { return }
        wakeIsReady = true
        updateWaitingStatus()
        if let id = readySpeechID, !readyWasAnnounced {
            readyWasAnnounced = true
            appendMessage(.assistant, text: Self.readyAnnouncement)
            readyHandler?(id)
        }
    }

    func receiveWake(recordingID: UUID, generationID: UUID) {
        guard self.recordingID == recordingID, wakeGenerationID == generationID,
              wakeIsReady else { return }
        // A wake during remote synthesis cancels the pending greeting. Only
        // actual playback suppresses microphone commands.
        stopSpeech()
        isListeningForCommand = true
        status = "已唤醒，正在听；请说出任务"
        appendMessage(.status, text: status)
        wakeFeedbackHandler?()
    }

    func wakeTimedOut(generationID: UUID) {
        guard wakeGenerationID == generationID else { return }
        isListeningForCommand = false
        updateWaitingStatus()
        replyIdleHandler?()
    }

    func wakeFailed(generationID: UUID, text: String, fatal: Bool = false) {
        guard wakeGenerationID == generationID else { return }
        isListeningForCommand = false
        if fatal || !wakeIsReady { setEnabled(false, unavailableReason: nil) }
        status = text
        appendMessage(.status, text: text, isError: true)
        replyIdleHandler?()
    }

    func beginVoiceCommand(recordingID: UUID, generationID: UUID,
                           startSample: Int64, endSample: Int64) -> UUID? {
        guard self.recordingID == recordingID, wakeGenerationID == generationID,
              wakeIsReady, endSample > startSample,
              startSample >= speechSuppressedThrough else { return nil }
        isListeningForCommand = false
        let id = UUID()
        currentRequestID = id
        isBusy = true
        status = "正在识别指令"
        appendMessage(.status, text: status)
        reconcileWakeCapture()
        return id
    }

    func submitVoiceCommand(requestID: UUID, recordingID: UUID, title: String,
                            text: String, transcriptSegments: [TranscriptSegment]?,
                            recordingStartedAt: Date?,
                            startSample: Int64, endSample: Int64) {
        guard canRespond(to: requestID), submittedRequestID != requestID,
              self.recordingID == recordingID, let submit else { return }
        let command = MeetingWakeCommandText.command(from: text)
        guard !command.isEmpty else {
            showStatus(requestID: requestID, text: "没有听到任务，请叫“小蓝同学”后再说一次")
            finish(requestID: requestID)
            return
        }
        let request = Request(id: requestID, recordingID: recordingID, title: title,
                              command: command, transcriptSegments: transcriptSegments,
                              recordingStartedAt: recordingStartedAt,
                              startSample: startSample, endSample: endSample)
        submittedRequestID = requestID
        readySpeechID = nil
        lastCommand = command
        result = ""
        speechNotice = ""
        status = "已识别指令，正在接单"
        appendMessage(.user, text: command)
        appendMessage(.status, text: status)
        submit(request)
    }

    public func markAccepted(requestID: UUID, sessionID: String) {
        guard currentRequestID == requestID else { return }
        self.sessionID = sessionID
        status = "收到，正在执行；完成后可继续唤起"
        appendMessage(.status, text: status)
    }

    public func showStatus(requestID: UUID, text: String) {
        guard currentRequestID == requestID else { return }
        status = text
        appendMessage(.status, text: text)
    }

    public func showResult(requestID: UUID, text: String, isError: Bool) {
        guard currentRequestID == requestID else { return }
        let repeated = lastResultRequestID == requestID && result == text && lastResultWasError == isError
        result = text
        status = isError ? "任务需要注意" : "已收到执行回复"
        if !repeated { appendMessage(.assistant, text: text, isError: isError) }
        lastResultRequestID = requestID
        lastResultWasError = isError
    }

    public func showSpeechNotice(requestID: UUID, text: String) {
        guard currentRequestID == requestID || readySpeechID == requestID else { return }
        speechNotice = text
        if !text.isEmpty { appendMessage(.status, text: text, isError: true) }
    }

    public func finish(requestID: UUID) {
        guard currentRequestID == requestID else { return }
        endSpeech(requestID: requestID)
        currentRequestID = nil
        isBusy = false
        reconcileWakeCapture()
        updateWaitingStatus()
    }

    /// Background work gets its own reply turn without inventing a user message.
    public func beginBackgroundReply(sessionID: String, generation: UUID) -> UUID? {
        guard self.sessionID == sessionID, responseGeneration == generation,
              enabled, capturing, foreground, !isBusy, !isSpeaking,
              !isListeningForCommand, currentRequestID == nil else { return nil }
        let id = UUID()
        currentRequestID = id
        isBusy = true
        status = "正在整理后台任务结果"
        appendMessage(.status, text: status)
        reconcileWakeCapture()
        return id
    }

    public func canRespond(to requestID: UUID) -> Bool {
        currentRequestID == requestID && enabled && capturing && foreground
    }

    public func canSpeak(to id: UUID) -> Bool {
        canRespond(to: id) || (readySpeechID == id && enabled && capturing && foreground)
    }

    public func beginSpeech(requestID: UUID) -> Bool {
        guard canSpeak(to: requestID), actualSpeechID == nil else { return false }
        actualSpeechID = requestID
        speechStart = sampleProvider?()
        speechOutputLevel = 0
        isSpeaking = true
        reconcileWakeCapture()
        return true
    }

    public func updateSpeechOutputLevel(_ level: Float, requestID: UUID) {
        guard actualSpeechID == requestID, isSpeaking else { return }
        speechOutputLevel = level.isFinite ? min(1, max(0, level)) : 0
    }

    public func endSpeech(requestID: UUID) {
        guard actualSpeechID == requestID else { return }
        if let start = speechStart {
            speechSuppressedThrough = max(speechSuppressedThrough, (sampleProvider?() ?? start) + 8_000)
        }
        speechStart = nil
        actualSpeechID = nil
        speechOutputLevel = 0
        isSpeaking = false
        if readySpeechID == requestID { readySpeechID = nil }
        reconcileWakeCapture()
        updateWaitingStatus()
    }

    func stopSpeech() {
        stopSpeechHandler?()
        if let id = actualSpeechID { endSpeech(requestID: id) }
        readySpeechID = nil
    }

    private func invalidateResponse() {
        responseGeneration = UUID()
        isListeningForCommand = false
        stopSpeech()
        currentRequestID = nil
        isBusy = false
    }

    private func reconcileWakeCapture(forceReset: Bool = false) {
        let canListen = enabled && capturing && foreground && !isBusy && !isSpeaking && recordingID != nil
        guard forceReset || canListen != (wakeGenerationID != nil) else { return }
        isListeningForCommand = false
        wakeGenerationID = canListen ? UUID() : nil
        wakeIsReady = false
        wakeCaptureHandler?(wakeGenerationID, max(sampleProvider?() ?? 0, speechSuppressedThrough))
    }

    func openSession() {
        if let sessionID { openSessionHandler?(sessionID) }
    }

    private func appendMessage(_ kind: Message.Kind, text: String, isError: Bool = false) {
        guard !text.isEmpty else { return }
        if let last = messages.last, last.kind == kind, last.text == text, last.isError == isError { return }
        messages.append(Message(kind: kind, text: text, isError: isError))
        if messages.count > 80 { messages.removeFirst(messages.count - 80) }
    }

    private func updateWaitingStatus() {
        guard !isBusy else { return }
        if !enabled { status = "说“小蓝同学”后交代任务" }
        else if !foreground { status = "已暂停唤醒，返回前台后继续" }
        else if !capturing { status = "录音已暂停，助手等待继续" }
        else if isSpeaking { status = "正在播报；结束后可唤醒" }
        else if !wakeIsReady { status = "正在准备唤醒模型" }
        else { status = "等待“小蓝同学”；说完稍作停顿" }
    }
}

struct MeetingAssistantPanel: View {
    let model: RecordingCoreModel
    @ObservedObject private var assistant = MeetingAssistantBridge.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showDialog = false

    var body: some View {
        VStack(alignment: .leading, spacing: YimaDesign.Space.sm) {
            Toggle("会中助手", isOn: Binding(
                get: { assistant.enabled },
                set: { model.setMeetingAssistantEnabled($0) }
            ))
            .tint(YimaDesign.Color.ink)
            .font(YimaDesign.Typography.metadata)
            .frame(minHeight: YimaDesign.Layout.hitTarget)
            Button { showDialog = true } label: {
                Label("小蓝同学", systemImage: "bubble.left.and.bubble.right")
                    .frame(minHeight: YimaDesign.Layout.hitTarget)
                    .contentShape(Rectangle())
            }
            .font(YimaDesign.Typography.metadata)
            .foregroundStyle(YimaDesign.Color.ink)
            .buttonStyle(.plain)
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
        .sheet(isPresented: $showDialog) {
            MeetingAssistantDialogue(assistant: assistant)
        }
        .background { if !showDialog, let permissions = assistant.permissions { permissions() } }
    }
}

private struct MeetingAssistantDialogue: View {
    @ObservedObject var assistant: MeetingAssistantBridge
    @EnvironmentObject private var workspace: VoiceRecordingWorkspace
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    Section {
                        Text(LocalizedStringKey(assistant.status))
                            .font(YimaDesign.Typography.metadata)
                            .foregroundStyle(YimaDesign.Color.muted)
                    }
                    if assistant.messages.isEmpty {
                        Text("开启会中助手后，这里显示收到的指令和回复。")
                            .font(YimaDesign.Typography.body)
                            .foregroundStyle(YimaDesign.Color.muted)
                    }
                    ForEach(assistant.messages) { message in
                        VStack(alignment: .leading, spacing: YimaDesign.Space.xs) {
                            HStack {
                                Text(role(for: message.kind))
                                if message.isError { Text("需要注意") }
                            }
                            .font(YimaDesign.Typography.compactMetadata)
                            .foregroundStyle(message.isError ? YimaDesign.Color.warningText : YimaDesign.Color.muted)
                            messageText(message)
                                .font(YimaDesign.Typography.body)
                                .foregroundStyle(YimaDesign.Color.ink)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, YimaDesign.Space.xs)
                        .accessibilityElement(children: .combine)
                        .id(message.id)
                    }
                }
                .listStyle(.plain)
                .onAppear { scrollToLatest(using: proxy) }
                .onChange(of: assistant.messages.last?.id) { _ in scrollToLatest(using: proxy) }
            }
            .navigationTitle("小蓝同学")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { VoiceRecordingStatusControl() }
                if assistant.isSpeaking {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("停止播报") { assistant.stopSpeech() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .tint(YimaDesign.Color.ink)
        .overlay { workspace.recordingEdge() }
        .background { if let permissions = assistant.permissions { permissions() } }
    }

    private func role(for kind: MeetingAssistantBridge.Message.Kind) -> LocalizedStringKey {
        switch kind {
        case .user: "你"
        case .assistant: "小蓝同学"
        case .status: "状态"
        }
    }

    private func messageText(_ message: MeetingAssistantBridge.Message) -> Text {
        if message.kind == .status || message.text == MeetingAssistantBridge.readyAnnouncement {
            Text(LocalizedStringKey(message.text))
        } else {
            Text(verbatim: message.text)
        }
    }

    private func scrollToLatest(using proxy: ScrollViewProxy) {
        if let id = assistant.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
    }
}
