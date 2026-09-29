import SwiftUI
import VoiceRecording

struct VoiceContextRootView: View {
    private enum Tab: Hashable { case chat, meetings, reminders, extensions }
    @State private var selection: Tab = .chat
    @ObservedObject var recordings: VoiceRecordingWorkspace
    @State private var startRecording = false
    @State private var stopRecording = false
    @State private var workspaceError: String?
    @State private var results: RecordingResultsRequest?
    @Environment(\.scenePhase) private var phase

    var body: some View {
        TabView(selection: $selection) {
            ContentView()
                .tabItem { Label("聊天", systemImage: "bubble.left.and.bubble.right") }
                .tag(Tab.chat)
            recordings.meetings(start: $startRecording, stop: $stopRecording)
                .tabItem { Label("会议", systemImage: "waveform") }
                .tag(Tab.meetings)
            SystemRemindersView()
                .tabItem { Label("待办事项", systemImage: "checklist") }
                .tag(Tab.reminders)
            VoiceContextExtensionsView(recordings: recordings)
                .tabItem { Label("拓展", systemImage: "square.grid.2x2") }
                .tag(Tab.extensions)
        }
        .tint(.primary)
        .safeAreaInset(edge: .top, spacing: 0) {
            if selection != .meetings && recordings.showsRecording {
                recordings.recordingBar()
            }
        }
        .onChange(of: phase) { newValue in
            recordings.sceneChanged(newValue)
            if newValue == .active { Task { await MeetingWorkspaceBridge.shared.refresh() } }
        }
        .onOpenURL { url in
            guard url.scheme == "voicecontext" else { return }
            selection = .meetings
            if url.host == "start-recording" { startRecording = true }
            if url.host == "stop-recording" { stopRecording = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newChatRequested)) { _ in selection = .chat }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("VoiceContext.openResults"))) { note in
            guard let id = note.userInfo?["recordingID"] as? String, UUID(uuidString: id) != nil else { return }
            results = RecordingResultsRequest(id: id)
        }
        .sheet(item: $results) { request in RecordingAgentResults(recordingID: request.id) }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("VoiceContext.openAgent"))) { note in
            guard let id = note.userInfo?["recordingID"] as? String, UUID(uuidString: id) != nil else { return }
            Task {
                if let error = await MeetingWorkspaceBridge.shared.refresh() {
                    workspaceError = error
                    return
                }
                selection = .chat
                await Task.yield()
                NotificationCenter.default.post(name: .newChatRequested, object: nil, userInfo: [
                    "voiceContextPrompt": "请基于录音 \(id) 帮我整理重点和下一步。先读取 /var/minis/shared/VoiceContext/README.md，再查找 Source/Transcripts/\(id).json；结果保存到 /var/minis/shared/VoiceContext/Generated/\(id)/ 并标注来源 revision。涉及创建系统提醒事项时，先与我确认具体事项。"
                ])
            }
        }
        .task {
            await recordings.prepare()
            MeetingWorkspaceBridge.installSkill()
            await MeetingWorkspaceBridge.shared.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("VoiceContext.documentsChanged"))) { _ in
            Task { await MeetingWorkspaceBridge.shared.refresh() }
        }
        .alert("会议资料暂不可用", isPresented: Binding(get: { workspaceError != nil }, set: { if !$0 { workspaceError = nil } })) {
            Button("好", role: .cancel) { workspaceError = nil }
        } message: { Text(workspaceError ?? "") }
    }
}

private struct RecordingResultsRequest: Identifiable { let id: String }

private struct VoiceContextExtensionsView: View {
    @ObservedObject var recordings: VoiceRecordingWorkspace
    @State private var recordingSettings = false
    @State private var agentSettings = false
    @State private var terminal = false
    @StateObject private var browserPool = BrowserTabPool()

    var body: some View {
        NavigationStack {
            List {
                Section("智能体能力") {
                    NavigationLink { SkillsManagementView() } label: { Label("Skills", systemImage: "book.closed") }
                    NavigationLink { ProviderInstancesView() } label: { Label("模型与服务", systemImage: "cpu") }
                    NavigationLink { BrowserManagementView(pool: browserPool) } label: {
                        Label("浏览器", systemImage: "globe")
                    }
                    Button { terminal = true } label: { Label("终端", systemImage: "terminal") }
                    NavigationLink { AgentListView() } label: { Label("智能体", systemImage: "person.2") }
                }
                Section("我的与设置") {
                    Button { recordingSettings = true } label: { Label("录音与我的设置", systemImage: "waveform") }
                    Button { agentSettings = true } label: { Label("智能体设置", systemImage: "gearshape") }
                }
            }
            .navigationTitle("拓展")
        }
        .sheet(isPresented: $recordingSettings) { recordings.settings() }
        .sheet(isPresented: $agentSettings) { SettingsSheet(showTerminal: $terminal) }
        .sheet(isPresented: $terminal) { ISHTerminalView(showCloseButton: true) }
    }
}
