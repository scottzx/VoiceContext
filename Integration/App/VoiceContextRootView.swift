import SwiftUI
import VoiceRecording

struct VoiceContextRootView: View {
    private enum Tab: String { case chat, meetings, reminders, extensions }
    @SceneStorage("voiceContext.selectedTab") private var savedSelection: Tab = .chat
    @State private var selection: Tab = .chat
    @State private var restoredSelection = false
    @ObservedObject var recordings: VoiceRecordingWorkspace
    @ObservedObject private var lock = SessionLockStore.shared
    @StateObject private var items = YimaItemsStore.shared
    @State private var localItem: YimaItemRequest?
    @State private var startingMeeting = false
    @State private var startRecording = false
    @State private var stopRecording = false
    @State private var workspaceError: String?
    @State private var results: RecordingResultsRequest?
    @State private var modelSetupNeeded = false
    @State private var modelSettings = false
    @State private var transcriptionModelDownload = false
    @StateObject private var browserPool = BrowserTabPool()
    @Environment(\.scenePhase) private var phase

    var body: some View {
        TabView(selection: $selection) {
            ContentView(browserPool: browserPool)
                .tabItem { Label("聊天", systemImage: "bubble.left.and.bubble.right") }
                .tag(Tab.chat)
            recordings.meetings(start: $startRecording, stop: $stopRecording)
                .tabItem { Label("记录", systemImage: "waveform") }
                .tag(Tab.meetings)
            SystemRemindersView()
                .tabItem { Label("提醒", systemImage: "checklist") }
                .tag(Tab.reminders)
            VoiceContextExtensionsView(browserPool: browserPool)
                .tabItem { Label("拓展", systemImage: "square.grid.2x2") }
                .tag(Tab.extensions)
        }
        .environmentObject(recordings)
        .tint(YimaDesign.Color.ink)
        .onAppear {
            if !restoredSelection {
                selection = savedSelection
                restoredSelection = true
            }
            presentPendingItem()
            if UserDefaults.standard.string(forKey: "pendingSettingsReopen") != nil,
               UserDefaults.standard.string(forKey: "settingsPresentationOwner") == "meeting-model-setup" {
                DispatchQueue.main.async { modelSettings = true }
            }
        }
        .onChange(of: selection) { _, tab in savedSelection = tab }
        .overlay { recordings.recordingEdge() }
        .onChange(of: phase, initial: true) { _, newValue in
            recordings.sceneChanged(newValue)
            MeetingAssistantBridge.shared.setForeground(newValue == .active && !lock.appIsLocked)
            if newValue == .active { Task { await MeetingWorkspaceBridge.shared.refresh() } }
        }
        .onOpenURL { url in
            guard url.scheme == AgentBuildIdentity.recordingURLScheme else { return }
            if let item = YimaItemLink(url: url, scheme: AgentBuildIdentity.recordingURLScheme) {
                items.pendingItem = item
                return
            }
            selection = .meetings
            if url.host == "start-recording" { startRecording = true }
            if url.host == "stop-recording" { stopRecording = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newChatRequested)) { _ in selection = .chat }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("Yima.openTranscriptionModels"))) { _ in
            transcriptionModelDownload = true
        }
        .sheet(isPresented: $transcriptionModelDownload) {
            NavigationStack {
                TranscriptionModelDownloadView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("关闭") { transcriptionModelDownload = false }
                        }
                    }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("VoiceContext.openResults"))) { note in
            guard let id = note.userInfo?["recordingID"] as? String, UUID(uuidString: id) != nil else { return }
            results = RecordingResultsRequest(id: id)
        }
        .sheet(item: $results) { request in RecordingAgentResults(recordingID: request.id) }
        .protectedYimaSheet(item: $localItem, onDismiss: YimaItemSheet.didDismiss) { YimaItemSheet(store: items, request: $0).environmentObject(recordings) }
        .onChange(of: lock.appIsLocked) { _, locked in
            MeetingAssistantBridge.shared.setForeground(!locked && phase == .active)
            if locked { items.recordingMeetingInProgress = nil }
            else { presentPendingItem() }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("Yima.itemSheetDismissed"))) { _ in
            guard !lock.appIsLocked, !startingMeeting, let meetingID = items.recordingMeetingInProgress,
                  let meeting = items.meeting(meetingID), let event = items.event(meeting.eventID) else { return }
            startingMeeting = true; selection = .meetings
            Task {
                defer { startingMeeting = false; items.recordingMeetingInProgress = nil; migrateMeetings() }
                do {
                    let id = try await recordings.startMeeting(title: event.title)
                    do { try items.linkRecording(id, meetingID: meetingID) }
                    catch { throw YimaItemsError.invalid("录音已开始，但关联未保存。录音 ID：\(id)。\(error.localizedDescription)") }
                } catch { workspaceError = error.localizedDescription }
            }
        }
        .onChange(of: items.pendingItem) { _, _ in presentPendingItem() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("Yima.openSourceChat"))) { note in
            guard let id = note.userInfo?["sessionID"] as? String else { return }
            selection = .chat; localItem = nil
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .openSessionFromIntent, object: nil, userInfo: ["sessionId": id])
            }
        }
        .sheet(isPresented: $modelSettings) {
            NavigationStack {
                ModelsAndServicesView()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(AppLocalized("Done")) { modelSettings = false }
                        }
                    }
            }
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
                    "voiceContextPrompt": "请基于录音 \(id) 帮我整理重点和下一步。先读取 /var/minis/shared/VoiceContext/README.md，再查找 Source/Transcripts/\(id).json；核对文稿 state，缺失或处理中时据实说明，仅基于已有文字整理。结果保存到 /var/minis/shared/VoiceContext/Generated/\(id)/ 并标注来源 recordingID、revision 和时间位置。先给行动建议，只有我明确确认具体事项后才使用 yima_items 创建 Yima 本地待办，并关联对应 meeting_id；先查询已有会议，创建用稳定 request_id，重试复用同一请求。未明确时间不要猜日期。成功后报告本地 ID、列表、到期时间并提供打开链接。未接入系统，不宣称系统已创建；到期日期不代表定时通知。"
                ])
            }
        }
        .task {
            MeetingAssistantController.shared.install()
            await recordings.prepare()
            migrateMeetings()
            MeetingWorkspaceBridge.installSkill()
            await MeetingWorkspaceBridge.shared.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("VoiceContext.documentsChanged"))) { _ in
            Task { @MainActor in
                migrateMeetings()
                await MeetingWorkspaceBridge.shared.refresh()
            }
        }
        .alert("会议资料暂不可用", isPresented: Binding(get: { workspaceError != nil }, set: { if !$0 { workspaceError = nil } })) {
            Button("好", role: .cancel) { workspaceError = nil }
        } message: { Text(workspaceError ?? "") }
    }
    private func presentPendingItem() {
        guard !lock.appIsLocked, let item = items.pendingItem else { return }
        items.pendingItem = nil
        openLocalItem(id: item.id, kind: item.kind)
    }

    private func openLocalItem(id: String, kind: YimaItemRequest.Kind) {
        guard (kind == .event ? items.event(id) != nil : items.todo(id) != nil) else {
            workspaceError = "事项已删除或不存在。"; return
        }
        localItem = YimaItemRequest(id: id, kind: kind)
    }

    private func migrateMeetings() {
        items.knownRecordingIDs = recordings.recordingIDs
        guard items.available, items.recordingMeetingInProgress == nil else { return }
        do {
            for recording in recordings.meetingRecords {
                try items.migrateRecording(id: recording.id, title: recording.title, recordedAt: recording.recordedAt)
            }
        } catch { workspaceError = "录音资料已保留，会议安排补充失败：" + error.localizedDescription }
    }

}

private struct RecordingResultsRequest: Identifiable { let id: String }

private struct VoiceContextExtensionsView: View {
    private enum Destination: Hashable { case skills, providers, soul, memory, mcp, hardware, terminal, browser, customFunctions }
    @State private var navigationPath: [Destination] = []
    @State private var settings = false
    @State private var terminal = false
    @State private var browser = false
    @State private var addCustomFunction = false
    @State private var openedCustomFunction: CustomExtensionItem?
    @StateObject private var customFunctions = CustomExtensionsStore.shared
    @ObservedObject var browserPool: BrowserTabPool
    private let columns = Array(repeating: GridItem(.flexible(), spacing: YimaDesign.Space.sm, alignment: .top), count: 4)

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: YimaDesign.Layout.sectionGap) {
                    customFunctionsSection
                    extensionSection("助手能力") {
                        destinationTile(.skills, title: AppLocalized("Skills"), symbol: "book.closed")
                        destinationTile(.providers, title: AppLocalized("模型与服务"), symbol: "cpu")
                        destinationTile(.soul, title: AppLocalized("助手设定"), symbol: "person.crop.circle")
                        destinationTile(.memory, title: AppLocalized("Memory"), symbol: "brain.head.profile")
                    }
                    extensionSection("工具连接") {
                        destinationTile(.mcp, title: AppLocalized("MCP Integrations"), symbol: "square.stack.3d.up")
                        destinationTile(.hardware, title: AppLocalized("Hardware Devices"), symbol: "antenna.radiowaves.left.and.right")
                    }
                    extensionSection("工具") {
                        destinationTile(.terminal, title: AppLocalized("终端"), symbol: "terminal")
                        destinationTile(.browser, title: AppLocalized("浏览器"), symbol: "globe")
                    }
                    extensionSection("我的与设置") {
                        Button { settings = true } label: { tile(AppLocalized("设置"), symbol: "gearshape") }
                    }
                }
                .padding(YimaDesign.Layout.pageInset)
            }
            .buttonStyle(.plain)
            .background(YimaDesign.Color.canvas)
            .navigationTitle("拓展")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { VoiceRecordingStatusControl() }
            }
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .skills: SkillsManagementView()
                case .providers: ModelsAndServicesView()
                case .soul: SoulSettingsView()
                case .memory: MemoryManagementView()
                case .mcp: MCPIntegrationsView()
                case .hardware: HardwareBridgeSettingsView()
                case .terminal: terminalPage
                case .browser: browserPage
                case .customFunctions: CustomExtensionsManagementView(store: customFunctions)
                }
            }
        }
        .toolbar(navigationPath.isEmpty ? .visible : .hidden, for: .tabBar)
        .onAppear {
            if UserDefaults.standard.string(forKey: "pendingSettingsReopen") != nil,
               UserDefaults.standard.string(forKey: "settingsPresentationOwner") == "extensions" {
                DispatchQueue.main.async { settings = true }
            }
        }
        .sheet(isPresented: $settings) {
            SettingsSheet(showTerminal: $terminal, presentationOwner: "extensions")
        }
        .fullScreenCover(isPresented: $terminal) {
            NavigationStack { ISHTerminalView(showCloseButton: true) }
        }
        .sheet(isPresented: $browser) { BrowserSheetView(pool: browserPool) }
        .fullScreenCover(item: $openedCustomFunction) { CustomExtensionBrowserView(item: $0) }
        .sheet(isPresented: $addCustomFunction) { CustomExtensionEditor(store: customFunctions) }
    }

    private var customFunctionsSection: some View {
        VStack(alignment: .leading, spacing: YimaDesign.Layout.headingGap) {
            HStack {
                Text("自定义功能").font(YimaDesign.Typography.section).accessibilityAddTraits(.isHeader)
                Spacer()
                if !customFunctions.items.isEmpty {
                    Button("管理") { navigationPath.append(.customFunctions) }
                        .font(YimaDesign.Typography.metadata)
                        .frame(minWidth: YimaDesign.Layout.hitTarget, minHeight: YimaDesign.Layout.hitTarget)
                }
            }
            if let error = customFunctions.readError {
                Text(error).font(YimaDesign.Typography.metadata).foregroundStyle(YimaDesign.Color.muted)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: YimaDesign.Space.lg) {
                ForEach(customFunctions.items) { item in
                    tile(item.name) { CustomExtensionIcon(name: item.name, logoData: item.logoData) }
                    .gesture(LongPressGesture().exclusively(before: TapGesture()).onEnded { gesture in
                        switch gesture {
                        case .first: navigationPath.append(.customFunctions)
                        case .second: openedCustomFunction = item
                        }
                    })
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { openedCustomFunction = item }
                    .accessibilityHint("打开功能；长按可调整顺序与删除")
                    .accessibilityAction(named: Text("调整顺序与删除")) { navigationPath.append(.customFunctions) }
                }
                Button { addCustomFunction = true } label: { tile(AppLocalized("添加"), symbol: "plus") }
                    .disabled(!customFunctions.available)
                    .accessibilityLabel("添加自定义功能")
            }
        }
    }

    private func extensionSection<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: YimaDesign.Layout.headingGap) {
            Text(title).font(YimaDesign.Typography.section).accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: columns, alignment: .leading, spacing: YimaDesign.Space.lg, content: content)
        }
    }

    private func destinationTile(_ destination: Destination, title: String, symbol: String) -> some View {
        NavigationLink(value: destination) { tile(title, symbol: symbol) }
    }

    private func tile(_ title: String, symbol: String) -> some View {
        tile(title) { Image(systemName: symbol).font(.title2) }
    }

    private func tile<Icon: View>(_ title: String, @ViewBuilder icon: () -> Icon) -> some View {
        VStack(spacing: YimaDesign.Space.sm) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { icon().padding(YimaDesign.Space.md) }
                .background(YimaDesign.Color.grouped)
                .clipShape(RoundedRectangle(cornerRadius: YimaDesign.Radius.control))
                .accessibilityHidden(true)
            Text(title)
                .font(YimaDesign.Typography.compactMetadata)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: YimaDesign.Layout.hitTarget, alignment: .top)
        .foregroundStyle(YimaDesign.Color.ink)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(title))
    }

    private var terminalPage: some View {
        List {
            Section {
                Button { terminal = true } label: {
                    Label(AppLocalized("Open Terminal"), systemImage: "terminal")
                }
            }
            Section("运行环境") {
                NavigationLink { RootfsManagementView() } label: {
                    Label("系统镜像", systemImage: "internaldrive")
                }
                NavigationLink { EnvironmentVariablesView() } label: {
                    Label(AppLocalized("Environment Variables"), systemImage: "text.badge.gearshape")
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("终端")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var browserPage: some View {
        List {
            Button { browser = true } label: {
                Label(AppLocalized("Open Browser"), systemImage: "globe")
            }
            NavigationLink { BrowserManagementView(pool: browserPool) } label: {
                Label(AppLocalized("Browser Settings"), systemImage: "gearshape")
            }
        }
        .listStyle(.plain)
        .navigationTitle("浏览器")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ModelsAndServicesView: View {
    @AppStorage(OpenAIProvider.fastModeDefaultsKey) private var fastModeEnabled = false

    var body: some View {
        List {
            Section {
                NavigationLink { ProviderInstancesView() } label: {
                    Label(AppLocalized("Manage Providers"), systemImage: "key")
                }
                NavigationLink { ModelGroupsView() } label: {
                    Label(AppLocalized("Model Groups"), systemImage: "square.stack")
                }
                NavigationLink { UsageStatsView() } label: {
                    Label(AppLocalized("Token Usage"), systemImage: "chart.line.uptrend.xyaxis")
                }
            }
            Section {
                Toggle(isOn: $fastModeEnabled) {
                    Label(AppLocalized("Enable Fast Mode"), systemImage: "bolt")
                }
            } footer: {
                Text("适用于支持快速模式的 GPT 模型。启用后可能增加额度消耗或费用，具体以服务商说明为准。")
            }
        }
        .listStyle(.plain)
        .navigationTitle("模型与服务")
        .navigationBarTitleDisplayMode(.inline)
    }
}
