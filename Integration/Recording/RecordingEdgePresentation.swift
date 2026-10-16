import SwiftUI

/// Native controls live in each page's header; the edge never captures touches
/// or reserves space above a conversation.
public struct VoiceRecordingStatusControl: View {
    @EnvironmentObject private var workspace: VoiceRecordingWorkspace

    public init() {}

    public var body: some View { workspace.recordingControl() }
}

struct RecordingEdgePresentation: View {
    private enum MeterSource { case inactive, microphone, assistant }

    let model: RecordingCoreModel
    @ObservedObject private var assistant = MeetingAssistantBridge.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    @State private var level: CGFloat = 0

    var body: some View {
        Group {
            if model.presentation == .recording {
                let response = reduceMotion ? 0 : level
                let color = assistant.isSpeaking ? YimaDesign.Color.info : YimaDesign.Color.recording
                let shape = RoundedRectangle(cornerRadius: 44, style: .continuous)
                ZStack {
                    shape.strokeBorder(color.opacity(0.14 + response * 0.16), lineWidth: 6 + response * 6)
                        .blur(radius: 5 + response * 3)
                    shape.strokeBorder(color.opacity(0.24 + response * 0.28), lineWidth: 1.5 + response)
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: level)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: meterSource) {
            let source = meterSource
            level = 0
            guard source != .inactive else { return }
            // During TTS only the output meter animates blue. Its microphone
            // echo cannot switch the edge to red or drive the speech animation.
            // Read meters outside body so audio packets do not redraw the page.
            while !Task.isCancelled {
                let next: CGFloat
                switch source {
                case .microphone:
                    let input = CGFloat(model.inputLevel ?? 0)
                    next = min(1, max(0, (input - 0.25) / 0.6))
                case .assistant:
                    next = min(1, max(0, CGFloat(assistant.speechOutputLevel)))
                case .inactive:
                    return
                }
                level = (next * 20).rounded() / 20
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
            }
        }
    }

    private var meterSource: MeterSource {
        guard model.presentation == .recording && phase == .active && !reduceMotion else { return .inactive }
        return assistant.isSpeaking ? .assistant : .microphone
    }
}

struct RecordingSessionMenu: View {
    let model: RecordingCoreModel
    @State private var openedRecordingID: UUID?

    var body: some View {
        if model.showsSessionChrome {
            Menu {
                Section {
                    Text(RecordingStatusStyle.barTitle(for: model.presentation))
                    Text("已录制 \(durationText)")
                    Text(progressText)
                }
                Button {
                    openedRecordingID = model.activeRecordingID
                } label: {
                    Label("返回当前录音", systemImage: "waveform")
                }
                .disabled(model.activeRecordingID == nil)
                Button(role: .destructive) {
                    Task { await model.stop() }
                } label: {
                    Label(model.presentation == .stopping ? "正在安全停止" : "停止录音", systemImage: "stop.fill")
                }
                .disabled(model.presentation == .stopping)
            } label: {
                Image(systemName: RecordingStatusStyle.symbolName(for: model.presentation))
                    .font(.body.weight(.medium))
                    .foregroundStyle(RecordingStatusStyle.color(for: model.presentation))
                    .frame(minWidth: YimaDesign.Layout.hitTarget, minHeight: YimaDesign.Layout.hitTarget)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(RecordingStatusStyle.barTitle(for: model.presentation))
            .accessibilityValue("已录制 \(durationAccessibility)，\(progressText)")
            .accessibilityHint("打开录音控制，可查看当前录音或停止")
            .accessibilityIdentifier("global-recording-control")
            .sheet(isPresented: Binding(get: { openedRecordingID != nil }, set: { if !$0 { openedRecordingID = nil } })) {
                if let id = openedRecordingID {
                    NavigationStack {
                        RecordingDetailScreen(model: model, recordingID: id)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("关闭") { openedRecordingID = nil }
                                }
                            }
                    }
                }
            }
        }
    }

    private var duration: TimeInterval {
        guard let id = model.activeRecordingID else { return 0 }
        return max(0, model.audioDuration(for: id))
    }

    private var durationText: String { RecordingStatusStyle.formatDuration(duration) }

    private var durationAccessibility: String {
        let seconds = Int(duration)
        return "\(seconds / 60) 分 \(seconds % 60) 秒"
    }

    private var progressText: String {
        if let progress = model.sessionProgress {
            return RecordingStatusStyle.progressDetailText(for: progress, isInBackground: model.isInBackground)
        }
        return switch model.presentation {
        case .recording: L("分钟级增量转写")
        case .paused: L("录音已暂停")
        case .interrupted: L("可点继续恢复")
        case .stopping: L("正在安全保存")
        case .processing, .idle, .failed: L("录音已结束")
        }
    }
}
