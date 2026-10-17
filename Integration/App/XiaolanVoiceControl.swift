import SwiftUI
import VoiceRecording

struct XiaolanVoiceMenu<LabelContent: View>: View {
    @ViewBuilder let label: () -> LabelContent
    @EnvironmentObject private var recordings: VoiceRecordingWorkspace
    @ObservedObject private var voice = XiaolanVoiceController.shared
    @State private var recordingConflict = false
    @State private var failure: String?
    @State private var enabling = false

    var body: some View {
        Group {
            if voice.isEnabled {
                Menu {
                    Section { Text(voice.status) }
                    if voice.isPaused {
                        Button("继续语音模式", systemImage: "mic") { activate(resuming: true) }
                    } else {
                        Button("点击说话", systemImage: "mic") { voice.beginCommand() }
                            .disabled(voice.isBusy || voice.isSpeaking)
                        Button("暂停语音模式", systemImage: "pause") { voice.pause() }
                    }
                    if voice.isSpeaking {
                        Button("停止播报", systemImage: "speaker.slash") { voice.stopSpeaking() }
                    }
                    if let error = voice.error { Text(error) }
                    Button("关闭语音模式", systemImage: "mic.slash") { voice.disable() }
                } label: { label() }
            } else {
                Button { activate(resuming: false) } label: { label() }
                    .disabled(enabling)
            }
        }
        .alert(recordingConflict ? "请先关闭录音" : "语音模式暂不可用", isPresented: Binding(
            get: { recordingConflict || failure != nil },
            set: { if !$0 { recordingConflict = false; failure = nil } }
        )) {
            if recordingConflict {
                Button("前往当前录音") {
                    guard let id = recordings.activeRecordingID else { return }
                    NotificationCenter.default.post(name: Notification.Name("Yima.openCurrentRecording"), object: nil,
                                                    userInfo: ["recordingID": id.uuidString])
                }
                .disabled(recordings.activeRecordingID == nil)
                Button("取消", role: .cancel) {}
            } else {
                Button("好", role: .cancel) { failure = nil }
            }
        } message: {
            Text(recordingConflict ? "当前有一条未结束的录音。请先结束录音，再开启语音模式。" : failure ?? "")
        }
    }

    private func activate(resuming: Bool) {
        guard !enabling else { return }
        guard !recordings.hasUnfinishedRecording else { recordingConflict = true; return }
        enabling = true
        Task { @MainActor in
            defer { enabling = false }
            do {
                if resuming { try await voice.resume(recordings: recordings) }
                else { try await voice.enable(recordings: recordings) }
            } catch {
                if recordings.hasUnfinishedRecording { recordingConflict = true }
                else { failure = error.localizedDescription }
            }
        }
    }
}

extension View {
    /// Forms and permission/source sheets require direct, deliberate interaction.
    func pausesXiaolanVoice(while presented: Bool) -> some View {
        modifier(XiaolanVoiceModalModifier(presented: presented))
    }
}

private struct XiaolanVoiceModalModifier: ViewModifier {
    let presented: Bool
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content.onChange(of: presented) { _, showing in
            if showing {
                XiaolanVoiceController.shared.pause()
                let navigation = AppNavigationCenter.shared
                if let route = navigation.state.routeID { navigation.unmount(routeID: route, params: navigation.state.params) }
            }
            NotificationCenter.default.post(name: Notification.Name("Yima.voiceFormChanged"), object: nil,
                                            userInfo: ["token": token, "active": showing])
        }
    }
}
