import SwiftUI
import VoiceRecording

struct VoiceContextRootView: View {
    private enum Tab: String { case chat, meetings, reminders, extensions }
    @SceneStorage("voiceContext.selectedTab") private var selection: Tab = .chat
    @ObservedObject var recordings: VoiceRecordingWorkspace
    @State private var startRecording = false
    @State private var stopRecording = false
    @State private var workspaceError: String?
    @State private var results: RecordingResultsRequest?
    @State private var modelSetupNeeded = false
    @State private var modelSettings = false
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
            VoiceContextExtensionsView()
                .tabItem { Label("拓展", systemImage: "square.grid.2x2") }
                .tag(Tab.extensions)
        }
        .environmentObject(recordings)
        .tint(.primary)
        .onAppear {
            if UserDefaults.standard.string(forKey: "pendingSettingsReopen") != nil,
               UserDefaults.standard.string(forKey: "settingsPresentationOwner") == "meeting-model-setup" {
                DispatchQueue.main.async { modelSettings = true }
            }
        }
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
            guard url.scheme == AgentBuildIdentity.recordingURLScheme else { return }
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
        .sheet(isPresented: $modelSettings) {
            SettingsSheet(showTerminal: .constant(false), presentationOwner: "meeting-model-setup")
        }
        .confirmationDialog("尚无可用聊天模型", isPresented: $modelSetupNeeded, titleVisibility: .visible) {
            Button("配置模型与服务") { modelSettings = true }
            Button("取消", role: .cancel) {}
        } message: { Text("请先配置模型服务并选择聊天模型，然后重新整理文稿。录音与回听仍可使用。") }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("VoiceContext.openAgent"))) { note in
            guard let id = note.userInfo?["recordingID"] as? String, UUID(uuidString: id) != nil else { return }
            let providers = ProviderConfigStore.shared
            guard let groupID = providers.defaultPrimaryGroupId,
                  let group = providers.group(for: groupID),
                  ModelGroupRouter.resolve(group: group, sessionId: id, store: providers) != nil
            else { modelSetupNeeded = true; return }
            Task {
                if let error = await MeetingWorkspaceBridge.shared.refresh() {
                    workspaceError = error
                    return
                }
                selection = .chat
                await Task.yield()
                NotificationCenter.default.post(name: .newChatRequested, object: nil, userInfo: [
                    "voiceContextPrompt": "请基于录音 \(id) 帮我整理重点和下一步。先读取 /var/minis/shared/VoiceContext/README.md，再查找 Source/Transcripts/\(id).json；核对文稿 state，缺失或处理中时据实说明，仅基于已有文字整理。结果保存到 /var/minis/shared/VoiceContext/Generated/\(id)/ 并标注来源 recordingID、revision 和时间位置。先给行动建议，只有我明确确认具体事项后才创建系统提醒事项；未明确时间时不要猜日期。先查看 apple-reminders --help；成功后报告可查询的系统事项 ID、标题、列表、到期时间和实际提醒设置。取消、权限拒绝或工具失败不能报告已创建；结果不明时先查询，不盲目重复创建。--due 只代表到期日期，不能据此宣称有通知。"
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
    @State private var settings = false
    @State private var terminal = false
    @StateObject private var browserPool = BrowserTabPool()

    var body: some View {
        NavigationStack {
            List {
                Section("工具") {
                    NavigationLink { SkillsManagementView() } label: { Label("Skills", systemImage: "book.closed") }
                    NavigationLink { ProviderInstancesView() } label: { Label("模型与服务", systemImage: "cpu") }
                    NavigationLink { BrowserManagementView(pool: browserPool) } label: {
                        Label("浏览器", systemImage: "globe")
                    }
                    Button { terminal = true } label: { Label("终端", systemImage: "terminal") }
                }
                Section("我的与设置") {
                    Button { settings = true } label: { Label("设置", systemImage: "gearshape") }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemBackground))
            .environment(\.defaultMinListRowHeight, 52)
            .navigationTitle("拓展")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            if UserDefaults.standard.string(forKey: "pendingSettingsReopen") != nil,
               UserDefaults.standard.string(forKey: "settingsPresentationOwner") == "extensions" {
                DispatchQueue.main.async { settings = true }
            }
        }
        .sheet(isPresented: $settings) {
            SettingsSheet(showTerminal: $terminal, presentationOwner: "extensions")
        }
        .sheet(isPresented: $terminal) { ISHTerminalView(showCloseButton: true) }
    }
}
