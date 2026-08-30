import AVFoundation
import Combine
import SwiftUI
import UniformTypeIdentifiers
import PhotosUI


private struct RecordingDayGroup: Identifiable {
    let date: Date
    let recordings: [Recording]
    var id: Date { date }
}

@MainActor
final class RecordingAudioTimelinePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var playbackRate: Float = 1
    @Published private(set) var playbackError: String?

    private struct Item {
        let url: URL
        let duration: TimeInterval
        let timelineStart: TimeInterval
        let timelineEnd: TimeInterval
    }

    private var items: [Item] = []
    private var player: AVAudioPlayer?
    private var currentIndex = 0
    private var currentItemOffset: TimeInterval = 0
    private var timer: Timer?

    var loadedItemCount: Int { items.count }
    var residentPlayerCount: Int { player == nil ? 0 : 1 }

    deinit { timer?.invalidate() }

    func load(chunks: [AudioChunk], rootURL: URL) {
        stop()
        playbackError = nil
        let sortedChunks = chunks.sorted { $0.startSample < $1.startSample }
        items = sortedChunks.compactMap { chunk in
            let url = rootURL.appendingPathComponent(chunk.relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let sampleCount = max(0, chunk.endSample - chunk.startSample)
            let itemDuration = Double(sampleCount) / AACSegmentRecorder.targetSampleRate
            let start = Double(chunk.startSample) / AACSegmentRecorder.targetSampleRate
            let end = Double(chunk.endSample) / AACSegmentRecorder.targetSampleRate
            return Item(
                url: url,
                duration: itemDuration,
                timelineStart: start,
                timelineEnd: max(start + itemDuration, end)
            )
        }
        duration = items.last?.timelineEnd ?? 0
        currentTime = items.first?.timelineStart ?? 0
    }

    /// Continuous timeline for one Files-imported private asset.
    func load(assetURL: URL, durationSeconds: TimeInterval) {
        stop()
        playbackError = nil
        guard FileManager.default.fileExists(atPath: assetURL.path) else {
            items = []
            duration = 0
            currentTime = 0
            playbackError = "导入音频暂不可用。"
            return
        }
        let dur = max(0, durationSeconds)
        items = [Item(url: assetURL, duration: dur, timelineStart: 0, timelineEnd: dur)]
        duration = dur
        currentTime = 0
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard !items.isEmpty else {
            playbackError = "没有可播放的音频分片。"
            return
        }
        if currentTime >= duration { seek(to: items.first?.timelineStart ?? 0) }
        playbackError = nil

        // Recording leaves the shared session in the .record category, where
        // AVAudioPlayer refuses to start without throwing. Switch to playback
        // before the first player so a valid chunk is not silently ignored.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)

        var skipped = 0
        while currentIndex < items.count {
            do {
                let activePlayer = try prepareCurrentPlayer()
                activePlayer.rate = playbackRate
                if activePlayer.play() {
                    isPlaying = true
                    startTimer()
                    if skipped > 0 {
                        playbackError = "已跳过 \(skipped) 个无法读取的分片。"
                    }
                    return
                }
                // play() reports refusal through its return value rather than
                // an exception. Treat it like a load failure so the user sees
                // a readable state instead of silent unresponsiveness.
                throw PlaybackFailure.couldNotStart
            } catch {
                skipped += 1
                player = nil
            }
            currentIndex += 1
            currentItemOffset = 0
            if currentIndex < items.count {
                currentTime = items[currentIndex].timelineStart
            }
        }
        isPlaying = false
        stopTimer()
        playbackError = skipped > 0
            ? "音频无法播放：所有分片都不可读。"
            : "音频无法播放。"
    }

    func pause() {
        guard isPlaying else { return }
        player?.pause()
        currentItemOffset = player?.currentTime ?? currentItemOffset
        isPlaying = false
        stopTimer()
        updateCurrentTime()
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        currentIndex = 0
        currentItemOffset = 0
        currentTime = items.first?.timelineStart ?? 0
        stopTimer()
    }

    func seek(by offset: TimeInterval) {
        seek(to: min(max(0, currentTime + offset), duration))
    }

    func seek(to time: TimeInterval) {
        guard !items.isEmpty else { return }
        let wasPlaying = isPlaying
        player?.pause()
        player = nil
        let target = min(max(0, time), duration)

        if let index = items.firstIndex(where: { target >= $0.timelineStart && target < $0.timelineEnd }) {
            currentIndex = index
            currentItemOffset = min(target - items[index].timelineStart, items[index].duration)
            currentTime = target
        } else if let nextIndex = items.firstIndex(where: { $0.timelineStart > target }) {
            // Gap detected: smart skip silence forward to next speech chunk start!
            currentIndex = nextIndex
            currentItemOffset = 0
            currentTime = items[nextIndex].timelineStart
        } else {
            currentIndex = items.count - 1
            currentItemOffset = items[currentIndex].duration
            currentTime = duration
        }

        if wasPlaying { play() }
    }

    func setRate(_ rate: Float) {
        playbackRate = rate
        player?.rate = rate
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === self.player else { return }
        self.player = nil
        currentItemOffset = 0
        guard currentIndex < items.count - 1 else {
            finishPlayback()
            return
        }
        currentIndex += 1
        // Smart skip silence: instant jump to next chunk's start!
        currentTime = items[currentIndex].timelineStart
        if isPlaying { play() }
    }

    private func prepareCurrentPlayer() throws -> AVAudioPlayer {
        if let player { return player }
        let nextPlayer = try AVAudioPlayer(contentsOf: items[currentIndex].url)
        nextPlayer.delegate = self
        nextPlayer.enableRate = true
        nextPlayer.prepareToPlay()
        nextPlayer.currentTime = min(currentItemOffset, nextPlayer.duration)
        player = nextPlayer
        return nextPlayer
    }

    private func finishPlayback() {
        player = nil
        isPlaying = false
        currentTime = duration
        stopTimer()
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateCurrentTime()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func updateCurrentTime() {
        guard !items.isEmpty, currentIndex < items.count else { return }
        currentItemOffset = player?.currentTime ?? currentItemOffset
        let item = items[currentIndex]
        currentTime = min(duration, item.timelineStart + currentItemOffset)
    }
}

/// Playback refused to start without throwing; surfaced as a readable state
/// rather than being treated as a completed timeline.
private enum PlaybackFailure: Error {
    case couldNotStart
}

private enum ProcessingModeTarget {
    case recording
    case importedFile(URL)
    case pickedVideo
}

/// The product-facing recording workspace. Its state is deliberately read
/// from `RecordingCoreModel`, which in turn refreshes its snapshots from the
/// journal/SQLite repository; this view never creates a parallel UI state
/// machine for capture.
struct ContentView: View {
    private static var didPrepareRecordingDetailFixtureRoot = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: RecordingCoreModel
    @State private var modelError: String?
    @State private var filterCriteria = RecordingFilterCriteria()
    @State private var isFilterSheetPresented = false
    @State private var isTranscriptionCenterPresented = false
    @State private var isClientManagerPresented = false
    @State private var isNewFolderAlertPresented = false
    @State private var newFolderNameInput = ""
    @State private var searchQuery = ""
    @State private var searchHits: [TranscriptSearchHit] = []
    @State private var isSearching = false
    @State private var isFolderManagerPresented = false
    @State private var moveRecordingID: UUID?
    @State private var isImportPickerPresented = false
    @State private var isPhotosPickerPresented = false
    @State private var selectedPhotoVideoItem: PhotosPickerItem?
    @State private var processingModeTarget: ProcessingModeTarget?
    @State private var isProcessingModeDialogPresented = false
    @State private var pendingRecordingIsMeeting: Bool?
    @State private var isSettingsPresented = false
    @State private var isRecordingScreenPresented = false
    @State private var isMultiSelectMode = false
    @State private var selectedRecordingIDs: Set<UUID> = []
    @State private var deletingTargetRecording: Recording? = nil
    @State private var isBatchDeleteAlertPresented = false
    @State private var editingRecording: Recording? = nil
    @State private var editingRecordingTitleInput = ""
    @State private var isDateJumpSheetPresented = false
    @State private var jumpTargetDate: Date? = nil
    @State private var currentFocusedDate: Date? = nil
    @State private var isFirstTimeLocationPromptPresented = false
    /// Set by the home-screen Record Widget deep link (`voicecontext://start-recording`).
    @Binding private var openStartRecording: Bool
    /// Set by the lock-screen Live Activity stop button deep link (`voicecontext://stop-recording`).
    @Binding private var openStopRecording: Bool
    private let isRecordingDetailFixtureEnabled: Bool

    init(
        openStartRecording: Binding<Bool> = .constant(false),
        openStopRecording: Binding<Bool> = .constant(false)
    ) {
        _openStartRecording = openStartRecording
        _openStopRecording = openStopRecording
        isRecordingDetailFixtureEnabled = ProcessInfo.processInfo.arguments.contains("-uiTestingSeedRecordingDetail")
        if isRecordingDetailFixtureEnabled {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let fixtureRoot = documents.appendingPathComponent("VoiceContext-uiTesting", isDirectory: true)
            if !Self.didPrepareRecordingDetailFixtureRoot {
                try? FileManager.default.removeItem(at: fixtureRoot)
                Self.didPrepareRecordingDetailFixtureRoot = true
            }
            do {
                _model = State(initialValue: try RecordingCoreModel(rootURL: fixtureRoot))
            } catch {
                _modelError = State(initialValue: error.localizedDescription)
                _model = State(initialValue: RecordingCoreModel.makePlaceholder())
            }
            return
        }
        do {
            _model = State(initialValue: try RecordingCoreModel())
        } catch {
            _modelError = State(initialValue: error.localizedDescription)
            _model = State(initialValue: RecordingCoreModel.makePlaceholder())
        }
    }

    var body: some View {
        Group {
            if let modelError {
                startupFailure(modelError)
            } else if model.trialEntitlement.isPurchaseLocked {
                NavigationStack {
                    ExpiredPaywallView(trial: model.trialEntitlement)
                }
            } else {
                workspace
            }
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(to: ScenePhaseLike(phase))
        }
        .onChange(of: model.captureIsActive) { _, isActive in
            if isActive, !model.trialEntitlement.isPurchaseLocked {
                isRecordingScreenPresented = true
            }
        }
        .task {
            if isRecordingDetailFixtureEnabled {
                await installRecordingDetailFixture()
            }
            await model.recoverOnLaunch()
            if openStartRecording {
                handleWidgetStartRecording()
            }
            if openStopRecording {
                handleWidgetStopRecording()
            }
        }
        .onChange(of: openStartRecording) { _, shouldOpen in
            guard shouldOpen else { return }
            handleWidgetStartRecording()
        }
        .onChange(of: openStopRecording) { _, shouldStop in
            guard shouldStop else { return }
            handleWidgetStopRecording()
        }
    }

    /// Widget / deep-link entry into the start-recording flow.
    private func handleWidgetStartRecording() {
        openStartRecording = false
        if modelError != nil || model.trialEntitlement.isPurchaseLocked { return }
        if model.captureIsActive || model.presentation == .stopping {
            isRecordingScreenPresented = true
            return
        }
        processingModeTarget = .recording
        isProcessingModeDialogPresented = true
    }

    /// Live Activity / lock-screen deep-link entry to safely stop recording.
    private func handleWidgetStopRecording() {
        openStopRecording = false
        guard model.captureIsActive else { return }
        Task {
            await model.stop()
        }
    }

    private func requestStartRecording(isMeeting: Bool = false) {
        if !LocationAccess.hasPromptedLocationRecording {
            pendingRecordingIsMeeting = isMeeting
            isFirstTimeLocationPromptPresented = true
        } else {
            triggerStartRecording(isMeeting: isMeeting)
        }
    }

    private func triggerStartRecording(isMeeting: Bool = false) {
        Task {
            await model.start(title: "", isMeeting: isMeeting)
            if model.captureIsActive {
                isRecordingScreenPresented = true
            }
        }
    }

    private var workspace: some View {
        NavigationStack {
            recordsScreen
                .navigationTitle(folderNavigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Section("个人中心") {
                                Button {
                                    isSettingsPresented = true
                                } label: {
                                    Label("我的", systemImage: "person.circle")
                                }
                            }
                            Section("转写与调度") {
                                Button {
                                    isTranscriptionCenterPresented = true
                                } label: {
                                    Label("转写任务中心", systemImage: "waveform.badge.magnifyingglass")
                                }
                            }
                            Section("管理") {
                                Button {
                                    isClientManagerPresented = true
                                } label: {
                                    Label("客户档案与声纹", systemImage: "person.2")
                                }
                                Button {
                                    isFolderManagerPresented = true
                                } label: {
                                    Label("文件夹管理", systemImage: "folder")
                                }
                            }
                            Section("导入") {
                                Button {
                                    isImportPickerPresented = true
                                } label: {
                                    Label("导入音频文件…", systemImage: "waveform")
                                }
                                Button {
                                    isPhotosPickerPresented = true
                                } label: {
                                    Label("导入相册视频…", systemImage: "photo.on.rectangle")
                                }
                            }
                        } label: {
                            Image(systemName: "line.3.horizontal")
                                .font(.body.weight(.medium))
                        }
                        .accessibilityLabel("功能菜单")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        let micHeld = model.captureIsActive || model.presentation == .stopping
                        Button {
                            if micHeld {
                                isRecordingScreenPresented = true
                            } else {
                                processingModeTarget = .recording
                                isProcessingModeDialogPresented = true
                            }
                        } label: {
                            Image(systemName: micHeld ? "waveform.circle.fill" : "mic.circle.fill")
                                .font(.system(size: 22, weight: .medium))
                                .foregroundStyle(Color.red)
                                .symbolEffect(.pulse, isActive: !reduceMotion && micHeld)
                        }
                        .accessibilityLabel(micHeld ? "录音进行中，轻点查看" : "开始录音")
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        if let activity = model.importActivity {
                            ImportActivityBanner(activity: activity)
                        } else if let notice = model.notice,
                                  notice.hasPrefix("导入")
                                    || notice.hasPrefix("已导入")
                                    || notice.hasPrefix("已有导入") {
                            ImportNoticeBanner(text: notice)
                        }
                    }
                }
        }
        .sheet(isPresented: $isFilterSheetPresented) {
            RecordingFilterSheet(model: model, criteria: $filterCriteria)
        }
        .sheet(isPresented: $isClientManagerPresented) {
            ClientManagementScreen(model: model)
        }
        .sheet(isPresented: $isTranscriptionCenterPresented) {
            TranscriptionCenterView(model: model)
        }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsScreen(model: model, reduceMotion: reduceMotion)
        }
        .confirmationDialog(
            "选择记录类型",
            isPresented: $isProcessingModeDialogPresented,
            titleVisibility: .visible
        ) {
            Button("个人记录（仅转为文字）") {
                applyProcessingMode(isMeeting: false)
            }
            Button("多人会议（识别说话人）") {
                applyProcessingMode(isMeeting: true)
            }
            Button("取消", role: .cancel) {
                cancelProcessingModeSelection()
            }
        } message: {
            Text("多人会议会在转写后继续提取声纹；个人记录会跳过这一步。")
        }
        .alert("记录录音地点", isPresented: $isFirstTimeLocationPromptPresented) {
            Button("允许并记录") {
                LocationAccess.hasPromptedLocationRecording = true
                LocationAccess.isAutoRecordLocationEnabled = true
                Task {
                    _ = await LocationAccess.requestPermissionIfNeeded()
                    let isMeeting = pendingRecordingIsMeeting ?? false
                    pendingRecordingIsMeeting = nil
                    triggerStartRecording(isMeeting: isMeeting)
                }
            }
            Button("暂不需要", role: .cancel) {
                LocationAccess.hasPromptedLocationRecording = true
                LocationAccess.isAutoRecordLocationEnabled = false
                let isMeeting = pendingRecordingIsMeeting ?? false
                pendingRecordingIsMeeting = nil
                triggerStartRecording(isMeeting: isMeeting)
            }
        } message: {
            Text("是否允许 VoiceContext 在录音时自动记录当前发生的地理位置与地址？你也可以稍后在「设置」中随时更改。")
        }
        .alert("新建文件夹", isPresented: $isNewFolderAlertPresented) {
            TextField("文件夹名称", text: $newFolderNameInput)
            Button("取消", role: .cancel) {}
            Button("创建") {
                let name = newFolderNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                Task {
                    _ = try? await model.createFolder(named: name)
                }
            }
        }
        .fileImporter(
            isPresented: $isImportPickerPresented,
            allowedContentTypes: ImportAudioSupportedTypes.contentTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                processingModeTarget = .importedFile(url)
                isProcessingModeDialogPresented = true
            case let .failure(error):
                model.presentNotice("选择文件失败：\(error.localizedDescription)")
            }
        }
        .photosPicker(
            isPresented: $isPhotosPickerPresented,
            selection: $selectedPhotoVideoItem,
            matching: .videos,
            photoLibrary: .shared()
        )
        .onChange(of: selectedPhotoVideoItem) { _, item in
            guard let item else { return }
            processingModeTarget = .pickedVideo
            isProcessingModeDialogPresented = true
        }
        .onChange(of: model.captureIsActive) { wasActive, isActive in
            if wasActive && !isActive && isRecordingScreenPresented {
                isRecordingScreenPresented = false
            }
        }
        .sheet(isPresented: $isRecordingScreenPresented) {
            if let activeID = model.activeRecordingID {
                NavigationStack {
                    RecordingDetailScreen(
                        model: model,
                        recordingID: activeID
                    )
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("最小化") {
                                isRecordingScreenPresented = false
                            }
                        }
                    }
                }
            }
        }
    }

    private var recordsScreen: some View {
        VStack(spacing: 0) {
            // Search bar + Filter + Multi-Select header
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索转写内容与标签…", text: $searchQuery)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("搜索转写内容")
                        .accessibilityIdentifier("transcript-search-field")
                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                            searchHits = []
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清除搜索")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))

                // Filter icon button
                Button {
                    isFilterSheetPresented = true
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: filterCriteria.isFiltered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                            .font(.system(size: 20))
                            .frame(width: 38, height: 38)
                        if filterCriteria.isFiltered {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 6, height: 6)
                                .offset(x: 2, y: -2)
                        }
                    }
                    .background(filterCriteria.isFiltered ? Color.primary.opacity(0.08) : Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(filterCriteria.isFiltered ? Color.primary : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("筛选记录")
                .accessibilityIdentifier("recording-filter-button")

                // Multi-select icon button
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isMultiSelectMode.toggle()
                        if !isMultiSelectMode {
                            selectedRecordingIDs.removeAll()
                        }
                    }
                } label: {
                    Image(systemName: isMultiSelectMode ? "checkmark.circle.fill" : "checkmark.circle")
                        .font(.system(size: 20))
                        .frame(width: 38, height: 38)
                        .background(isMultiSelectMode ? Color.accentColor.opacity(0.15) : Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(isMultiSelectMode ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("多选模式")
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 8)

            // Active filter chips
            if filterCriteria.isFiltered {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if filterCriteria.timePreset != .all {
                            filterChip(
                                title: filterCriteria.timePreset == .custom
                                    ? "\(filterCriteria.customStartDate.formatted(date: .numeric, time: .omitted)) ~ \(filterCriteria.customEndDate.formatted(date: .numeric, time: .omitted))"
                                    : filterCriteria.timePreset.title
                            ) {
                                filterCriteria.timePreset = .all
                            }
                        }
                        if filterCriteria.folderFilter != .all {
                            filterChip(title: folderFilterName(filterCriteria.folderFilter)) {
                                filterCriteria.folderFilter = .all
                            }
                        }
                        if filterCriteria.originFilter != .all {
                            filterChip(title: filterCriteria.originFilter.title) {
                                filterCriteria.originFilter = .all
                            }
                        }
                        Button("重置") {
                            filterCriteria = RecordingFilterCriteria()
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 6)
                }
            }

            if !trimmedSearchQuery.isEmpty {
                ScrollView {
                    searchResultsSection
                }
            } else if recordingGroups.isEmpty {
                ContentUnavailableView {
                    Label(emptyListTitle, systemImage: "waveform")
                } description: {
                    Text(emptyListDescription)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 32)
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(recordingGroups) { group in
                            Section {
                                ForEach(group.recordings) { recording in
                                    recordingRowItem(recording)
                                }
                            } header: {
                                Button {
                                    currentFocusedDate = group.date
                                    isDateJumpSheetPresented = true
                                } label: {
                                    HStack(spacing: 6) {
                                        Text(formattedDateHeader(group.date))
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.primary)
                                        Image(systemName: "chevron.up.chevron.down")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text("\(group.recordings.count) 条记录")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                                .id(group.id)
                                .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 4, trailing: 20))
                                .listRowBackground(Color(uiColor: .systemBackground))
                            }
                        }
                    }
                    .listStyle(.plain)
                    .environment(\.defaultMinListHeaderHeight, 0)
                    .scrollContentBackground(.hidden)
                    .contentMargins(.top, 0, for: .scrollContent)
                    .onChange(of: jumpTargetDate) { _, targetDate in
                        guard let targetDate else { return }
                        withAnimation(.easeInOut(duration: 0.35)) {
                            proxy.scrollTo(targetDate, anchor: .top)
                        }
                        jumpTargetDate = nil
                    }
                }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .safeAreaInset(edge: .bottom) {
            if isMultiSelectMode {
                VStack(spacing: 0) {
                    Divider()
                    HStack(spacing: 16) {
                        Button {
                            let allIDs = Set(filteredRecordings.map(\.id))
                            if selectedRecordingIDs.count == allIDs.count {
                                selectedRecordingIDs.removeAll()
                            } else {
                                selectedRecordingIDs = allIDs
                            }
                        } label: {
                            Text(selectedRecordingIDs.count == filteredRecordings.count ? "取消全选" : "全选")
                                .font(.subheadline.weight(.medium))
                        }

                        Spacer()

                        Text("已选择 \(selectedRecordingIDs.count) 条")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button(role: .destructive) {
                            isBatchDeleteAlertPresented = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "trash")
                                Text("删除(\(selectedRecordingIDs.count))")
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(selectedRecordingIDs.isEmpty ? Color.secondary : Color.red)
                        }
                        .disabled(selectedRecordingIDs.isEmpty)

                        Button("完成") {
                            withAnimation {
                                isMultiSelectMode = false
                                selectedRecordingIDs.removeAll()
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(.bar)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onChange(of: searchQuery) { _, _ in
            Task { await refreshSearchHits() }
        }
        .onChange(of: filterCriteria) { _, _ in
            Task { await refreshSearchHits() }
        }
        .onChange(of: model.recordings) { _, _ in
            Task { await refreshSearchHits() }
        }
        .onChange(of: model.folderCatalog) { _, _ in
            Task { await refreshSearchHits() }
        }
        .task(id: trimmedSearchQuery) {
            await refreshSearchHits()
        }
        .sheet(isPresented: $isFolderManagerPresented) {
            FolderManagerSheet(model: model, folderFilter: $filterCriteria.folderFilter)
        }
        .sheet(isPresented: Binding(
            get: { moveRecordingID != nil },
            set: { if !$0 { moveRecordingID = nil } }
        )) {
            if let moveRecordingID {
                MoveToFolderSheet(model: model, recordingID: moveRecordingID)
            }
        }
        .sheet(isPresented: $isDateJumpSheetPresented) {
            QuickDateJumpSheet(
                recordingGroups: recordingGroups,
                initialDate: currentFocusedDate
            ) { targetDate in
                jumpTargetDate = targetDate
            }
        }
        .alert("删除录音", isPresented: Binding(
            get: { deletingTargetRecording != nil },
            set: { if !$0 { deletingTargetRecording = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let recording = deletingTargetRecording {
                    Task {
                        await model.deleteRecording(id: recording.id)
                        deletingTargetRecording = nil
                    }
                }
            }
            Button("取消", role: .cancel) {
                deletingTargetRecording = nil
            }
        } message: {
            Text("确定要彻底删除「\(deletingTargetRecording?.title?.isEmpty == false ? deletingTargetRecording!.title! : "此录音")」吗？此操作将同时删除本地音频文件和已转写文稿，且无法恢复。")
        }
        .alert("批量删除录音", isPresented: $isBatchDeleteAlertPresented) {
            Button("删除 \(selectedRecordingIDs.count) 条记录", role: .destructive) {
                let targets = selectedRecordingIDs
                Task {
                    await model.deleteRecordings(ids: targets)
                    selectedRecordingIDs.removeAll()
                    isMultiSelectMode = false
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("确定要删除选中的 \(selectedRecordingIDs.count) 条录音吗？将同时清除关联的本地音频文件与转写文稿，且无法恢复。")
        }
        .alert("编辑录音名称", isPresented: Binding(
            get: { editingRecording != nil },
            set: { if !$0 { editingRecording = nil } }
        )) {
            TextField("输入录音名称", text: $editingRecordingTitleInput)
            Button("保存") {
                if let recording = editingRecording {
                    let newTitle = editingRecordingTitleInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        try? await model.saveRecordingMetadata(recordingID: recording.id, title: newTitle)
                        editingRecording = nil
                    }
                }
            }
            Button("取消", role: .cancel) {
                editingRecording = nil
            }
        } message: {
            Text("请输入新的录音标题")
        }
    }

    private func formattedDateHeader(_ date: Date) -> String {
        let isChinese = AppLanguageCenter.shared.isChinese ||
            Locale.preferredLanguages.contains(where: { $0.hasPrefix("zh") }) ||
            Locale.current.identifier.hasPrefix("zh") ||
            AppLanguageCenter.shared.selectedLanguage != .english
        if isChinese {
            let calendar = Calendar.current
            let y = calendar.component(.year, from: date)
            let m = String(format: "%02d", calendar.component(.month, from: date))
            let d = String(format: "%02d", calendar.component(.day, from: date))
            let weekday = calendar.component(.weekday, from: date)
            let weekdays = ["", "周日", "周一", "周二", "周三", "周四", "周五", "周六"]
            let wStr = (weekday >= 1 && weekday <= 7) ? weekdays[weekday] : ""
            return "\(y)-\(m)-\(d), \(wStr)"
        } else {
            return date.formatted(date: .complete, time: .omitted)
        }
    }

    @ViewBuilder
    private func recordingRowItem(_ recording: Recording) -> some View {
        if isMultiSelectMode {
            Button {
                if selectedRecordingIDs.contains(recording.id) {
                    selectedRecordingIDs.remove(recording.id)
                } else {
                    selectedRecordingIDs.insert(recording.id)
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: selectedRecordingIDs.contains(recording.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selectedRecordingIDs.contains(recording.id) ? Color.accentColor : Color.secondary)
                        .animation(.easeInOut(duration: 0.15), value: selectedRecordingIDs.contains(recording.id))

                    RecordingRow(
                        recording: recording,
                        folderName: model.folderName(for: recording.id),
                        audioDuration: model.audioDuration(for: recording.id)
                    )
                }
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            .listRowSeparator(.visible)
        } else {
            NavigationLink {
                RecordingDetailScreen(model: model, recordingID: recording.id)
            } label: {
                RecordingRow(
                    recording: recording,
                    folderName: model.folderName(for: recording.id),
                    audioDuration: model.audioDuration(for: recording.id)
                )
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            .listRowSeparator(.visible)
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    deletingTargetRecording = recording
                } label: {
                    Label("删除", systemImage: "trash.fill")
                }
                .tint(.red)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button {
                    editingRecording = recording
                    editingRecordingTitleInput = recording.title ?? ""
                } label: {
                    Label("编辑名称", systemImage: "pencil")
                }
                .tint(.blue)
            }
            .contextMenu {
                Button {
                    editingRecording = recording
                    editingRecordingTitleInput = recording.title ?? ""
                } label: {
                    Label("编辑名称", systemImage: "pencil")
                }
                Button {
                    moveRecordingID = recording.id
                } label: {
                    Label("移动到文件夹", systemImage: "folder")
                }
                Button(role: .destructive) {
                    deletingTargetRecording = recording
                } label: {
                    Label("删除录音", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private func filterChip(title: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption.weight(.medium))
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.08))
        .clipShape(Capsule())
    }

    private func folderFilterName(_ filter: RecordingFolderFilter) -> String {
        switch filter {
        case .all: "全部文件夹"
        case .uncategorized: "未分类"
        case .folder(let id): model.folders.first(where: { $0.id == id })?.name ?? "文件夹"
        }
    }

    @ViewBuilder
    private var searchResultsSection: some View {
        if isSearching && searchHits.isEmpty {
            ProgressView("正在搜索…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
        } else if filteredSearchHits.isEmpty {
            ContentUnavailableView {
                Label("没有找到相关转写", systemImage: "magnifyingglass")
            } description: {
                Text("试试其他关键词，或清空搜索查看全部记录。")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
            .accessibilityIdentifier("transcript-search-empty")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(filteredSearchHits.count) 条结果")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 4)
                ForEach(filteredSearchHits) { hit in
                    NavigationLink {
                        RecordingDetailScreen(
                            model: model,
                            recordingID: hit.recordingID,
                            highlightQuery: trimmedSearchQuery,
                            scrollToSegmentID: hit.firstMatchingSegmentID
                        )
                    } label: {
                        TranscriptSearchResultRow(hit: hit)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("search-hit-\(hit.recordingID.uuidString)")
                    Divider().padding(.leading, 20)
                }
            }
        }
    }

    private var captureDock: some View {
        let micHeld = model.captureIsActive || model.presentation == .stopping
        return VStack(spacing: 6) {
            Button {
                if micHeld {
                    isRecordingScreenPresented = true
                } else {
                    processingModeTarget = .recording
                    isProcessingModeDialogPresented = true
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(micHeld ? Color.red.opacity(0.85) : Color.red)
                        .frame(width: 64, height: 64)
                    Image(systemName: micHeld ? "waveform" : "mic.fill")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.white)
                        .symbolEffect(.pulse, isActive: !reduceMotion && micHeld)
                }
                .frame(width: 72, height: 72)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.impact(weight: .medium), trigger: micHeld)
            .accessibilityLabel(micHeld ? "录音进行中，轻点查看" : "开始录音")

            Text(micHeld ? "录音中 · 轻点查看" : "开始录音")
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .accessibilityIdentifier("capture-dock")
    }

    private func applyProcessingMode(isMeeting: Bool) {
        let target = processingModeTarget
        processingModeTarget = nil
        switch target {
        case .recording:
            requestStartRecording(isMeeting: isMeeting)
        case let .importedFile(url):
            Task { _ = await model.importAudio(from: url, isMeeting: isMeeting) }
        case .pickedVideo:
            guard let item = selectedPhotoVideoItem else { return }
            Task {
                await importPickedPhotoVideo(item, isMeeting: isMeeting)
                selectedPhotoVideoItem = nil
            }
        case nil:
            break
        }
    }

    private func cancelProcessingModeSelection() {
        processingModeTarget = nil
        selectedPhotoVideoItem = nil
    }

    private func importPickedPhotoVideo(_ item: PhotosPickerItem, isMeeting: Bool) async {
        do {
            guard let movie = try await item.loadTransferable(type: ImportPickedMovie.self) else {
                model.presentNotice("导入失败：无法读取所选视频")
                return
            }
            let base = (movie.url.lastPathComponent as NSString).deletingPathExtension
            let suggested = base.isEmpty ? "相册视频.mov" : "\(base).mov"
            _ = await model.importVideoAudio(
                from: movie.url,
                sourceFilename: suggested,
                isMeeting: isMeeting
            )
        } catch {
            model.presentNotice("导入失败：\(error.localizedDescription)")
        }
    }

    private var trimmedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredSearchHits: [TranscriptSearchHit] {
        let byTime = Dictionary(uniqueKeysWithValues: model.recordings.map { ($0.id, $0) })
        return searchHits.filter { hit in
            guard let recording = byTime[hit.recordingID] else { return false }
            return filterCriteria.matches(recording: recording, folderID: model.folderID(for: recording.id))
        }
    }

    private var filteredRecordings: [Recording] {
        model.recordings.filter {
            filterCriteria.matches(recording: $0, folderID: model.folderID(for: $0.id))
        }
    }

    @MainActor
    private func refreshSearchHits() async {
        let query = trimmedSearchQuery
        guard !query.isEmpty else {
            searchHits = []
            isSearching = false
            return
        }
        isSearching = true
        do {
            let hits = try await model.searchTranscripts(query: query)
            guard query == trimmedSearchQuery else { return }
            searchHits = hits
        } catch {
            guard query == trimmedSearchQuery else { return }
            searchHits = []
            model.presentNotice("搜索失败：\(error.localizedDescription)")
        }
        isSearching = false
    }

    private var folderNavigationTitle: String {
        switch filterCriteria.folderFilter {
        case .all:
            return "全部录音"
        case .uncategorized:
            return "未分类"
        case .folder(let id):
            return model.folders.first(where: { $0.id == id })?.name ?? "文件夹"
        }
    }

    private var emptyListTitle: String {
        if model.recordings.isEmpty {
            return "还没有记录"
        }
        return "没有符合筛选的记录"
    }

    private var emptyListDescription: String {
        if model.recordings.isEmpty {
            return "开始录音，保存一个念头或一次对话。也可从左上角导入文件或相册视频。"
        }
        return "换一个时间范围或筛选条件，或开始一条新录音。"
    }

    private var recordingGroups: [RecordingDayGroup] {
        let calendar = Calendar.current
        let filtered = filteredRecordings.sorted { $0.startedAt > $1.startedAt }
        let grouped = Dictionary(grouping: filtered) {
            calendar.startOfDay(for: $0.startedAt)
        }
        return grouped.keys.sorted(by: >).map { date in
            RecordingDayGroup(date: date, recordings: grouped[date] ?? [])
        }
    }

    private func startupFailure(_ message: String) -> some View {
        ContentUnavailableView {
            Label("记录空间未能打开", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        }
        .foregroundStyle(.primary)
    }

    private func installRecordingDetailFixture() async {
        guard (try? await model.repository.recordings().isEmpty) == true else { return }
        let startedAt = Date()
        let recording = Recording(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000042")!,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(13),
            title: "测试详情录音",
            state: .failed,
            updatedAt: startedAt.addingTimeInterval(13)
        )
        let chunk = AudioChunk(
            recordingID: recording.id,
            relativePath: "Recordings/fixture.m4a",
            startSample: 0,
            endSample: 208_000,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(13)
        )
        let job = RecordingJob(
            id: UUID(),
            recordingID: recording.id,
            kind: .transcription,
            state: .failed,
            attemptCount: 1,
            lastError: "Silero VAD 未形成语音片段",
            createdAt: startedAt,
            updatedAt: startedAt.addingTimeInterval(13)
        )
        do {
            try await model.repository.createRecording(recording, at: startedAt)
            try await model.repository.addChunk(chunk, at: chunk.endedAt)
            try await model.repository.upsertJob(job, at: job.updatedAt)
        } catch {
            modelError = "无法建立详情测试数据：\(error.localizedDescription)"
        }
    }
}

/// Optional day filter above the all-recordings list. Default selection is
/// 「全部」 so the calendar never owns the home mental model (FR-ADD-IA-002).
private struct CalendarStrip: View {
    @Binding var selectedDate: Date?
    let recordings: [Recording]

    private let calendar = Calendar.current

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("按日期过滤")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .accessibilityHidden(true)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    allDaysChip

                    ForEach(days, id: \.self) { day in
                        let isSelected = selectedDate.map { calendar.isDate(day, inSameDayAs: $0) } ?? false
                        let count = recordings.filter { calendar.isDate($0.startedAt, inSameDayAs: day) }.count
                        Button {
                            if isSelected {
                                selectedDate = nil
                            } else {
                                selectedDate = day
                            }
                        } label: {
                            VStack(spacing: 4) {
                                Text(day.formatted(.dateTime.weekday(.narrow)))
                                    .font(.caption.weight(.medium))
                                Text(day.formatted(.dateTime.day()))
                                    .font(.headline.monospacedDigit())
                                Text(count == 0 ? " " : "\(count) 条")
                                    .font(.caption2)
                                    .lineLimit(1)
                            }
                            .frame(width: 48, height: 68)
                            .foregroundStyle(isSelected ? .white : .primary)
                            .background {
                                if isSelected {
                                    Capsule().fill(.primary)
                                } else if calendar.isDateInToday(day) {
                                    Capsule().stroke(Color.secondary, lineWidth: 1)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(day.formatted(.dateTime.year().month().day().weekday(.wide)))
                        .accessibilityValue(count == 0 ? "没有记录" : "\(count) 条记录")
                        .accessibilityHint(isSelected ? "再次点击可清除日期过滤" : "过滤到这一天")
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendar-day-filter")
    }

    private var allDaysChip: some View {
        let isSelected = selectedDate == nil
        return Button {
            selectedDate = nil
        } label: {
            VStack(spacing: 4) {
                Text("全部")
                    .font(.caption.weight(.semibold))
                Text("\(recordings.count)")
                    .font(.headline.monospacedDigit())
                Text("条")
                    .font(.caption2)
            }
            .frame(width: 48, height: 68)
            .foregroundStyle(isSelected ? .white : .primary)
            .background {
                if isSelected {
                    Capsule().fill(.primary)
                } else {
                    Capsule().stroke(Color.secondary, lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("全部日期")
        .accessibilityValue("\(recordings.count) 条记录")
        .accessibilityHint("清除日期过滤，显示全部录音列表")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("calendar-filter-all")
    }

    private var days: [Date] {
        let today = calendar.startOfDay(for: Date())
        return (-3...3).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
    }
}

private struct RecordingRow: View {
    let recording: Recording
    var folderName: String? = nil
    var audioDuration: Double = 0

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(recording.title?.isEmpty == false ? recording.title! : defaultTitle)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                
                HStack(spacing: 8) {
                    Text(metadata)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    
                    if recording.state != .complete {
                        statusIndicator
                    }
                }

                if let location = recording.locationName, !location.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.caption2)
                        Text(location)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(recording.title?.isEmpty == false ? recording.title! : defaultTitle)，\(metadata)\(recording.locationName.map { "，地点：\($0)" } ?? "")，\(RecordingStatusStyle.text(for: recording.state))")
    }

    @ViewBuilder
    private var statusIndicator: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 6, height: 6)
            Text(statusText)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(indicatorColor)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(indicatorColor.opacity(0.12), in: Capsule())
    }

    private var indicatorColor: Color {
        switch recording.state {
        case .recording, .failed:
            return .red
        case .interrupted, .processing, .paused:
            return .orange
        case .stopping, .complete:
            return .secondary
        }
    }

    private var statusText: String {
        switch recording.state {
        case .recording: "录音中"
        case .paused: "已暂停"
        case .interrupted: "中断需注意"
        case .stopping: "正在停止"
        case .processing: "正在处理"
        case .complete: "已完成"
        case .failed: "转写异常"
        }
    }

    private var defaultTitle: String {
        if recording.origin == .importedAudio {
            return recording.sourceFilename.map {
                ($0 as NSString).deletingPathExtension
            } ?? "导入音频"
        }
        return recording.isMeeting ? "未命名会议" : "未命名录音"
    }

    private var metadata: String {
        let time = recording.startedAt.standardTimeString
        let duration: String
        if audioDuration > 0 {
            duration = Self.duration(audioDuration)
        } else if let endedAt = recording.endedAt {
            duration = Self.duration(endedAt.timeIntervalSince(recording.startedAt))
        } else {
            duration = "录制中"
        }
        let folderSuffix: String
        if let folderName, !folderName.isEmpty {
            folderSuffix = " · \(folderName)"
        } else {
            folderSuffix = ""
        }
        if recording.origin == .importedAudio {
            let source = recording.sourceFilename ?? "导入音频"
            return "\(time) · \(duration) · 导入 · \(source)\(folderSuffix)"
        }
        return "\(time) · \(duration)\(folderSuffix)"
    }

    fileprivate static func duration(_ interval: TimeInterval) -> String {
        RecordingStatusStyle.formatDuration(interval)
    }
}

private struct TranscriptSearchResultRow: View {
    let hit: TranscriptSearchHit

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "text.magnifyingglass")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(hit.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(hit.excerpt)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(hit.title)，\(hit.excerpt)")
    }
}

struct RecordingBar: View {
    let model: RecordingCoreModel
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: RecordingStatusStyle.symbolName(for: model.presentation))
                .foregroundStyle(RecordingStatusStyle.color(for: model.presentation))
                .symbolEffect(
                    .pulse,
                    isActive: !reduceMotion && model.presentation == .recording
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(RecordingStatusStyle.barTitle(for: model.presentation))
                    .font(.subheadline.weight(.semibold))
                Text("\(elapsedText) · \(statusDetailText)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(RecordingStatusStyle.barTitle(for: model.presentation))，已录制 \(elapsedAccessibility)，\(statusDetailText)"
            )

            Spacer(minLength: 4)

            if showsStopControl {
                Button(role: .destructive) {
                    Task { await model.stop() }
                } label: {
                    Label(model.presentation == .stopping ? "停止中" : "停止", systemImage: "stop.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(minWidth: 54, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(model.presentation == .stopping)
                .accessibilityLabel(
                    model.presentation == .stopping ? "正在安全停止" : "停止录音"
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(barBackground)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityIdentifier("global-recording-bar")
    }

    private var showsStopControl: Bool {
        switch model.presentation {
        case .recording, .paused, .interrupted, .stopping:
            true
        case .processing, .idle, .failed:
            false
        }
    }

    private var barBackground: Color {
        switch model.presentation {
        case .recording, .paused, .interrupted:
            Color.red.opacity(0.08)
        case .stopping:
            Color.orange.opacity(0.10)
        case .processing, .idle, .failed:
            Color(uiColor: .secondarySystemBackground)
        }
    }

    private var statusDetailText: String {
        if let progress = model.sessionProgress {
            return RecordingStatusStyle.progressDetailText(
                for: progress,
                isInBackground: model.isInBackground
            )
        }
        return switch model.presentation {
        case .stopping:
            "正在安全保存"
        case .recording, .paused, .interrupted:
            model.isInBackground ? "录音继续，转写待前台处理" : "分钟级增量转写"
        case .processing, .idle, .failed:
            "可返回记录查看进度"
        }
    }

    private var elapsedText: String {
        if let activeID = model.activeRecordingID {
            let duration = model.audioDuration(for: activeID)
            if duration > 0 {
                return RecordingStatusStyle.formatDuration(duration)
            }
        }
        guard let recording = model.snapshot.recording else {
            if let active = model.recordings.first(where: {
                $0.state == .processing || $0.state == .stopping
            }) {
                let duration = model.audioDuration(for: active.id)
                if duration > 0 {
                    return RecordingStatusStyle.formatDuration(duration)
                }
                let end = active.endedAt ?? Date()
                return RecordingStatusStyle.formatDuration(end.timeIntervalSince(active.startedAt))
            }
            return "00:00"
        }
        let duration = model.audioDuration(for: recording.id)
        if duration > 0 {
            return RecordingStatusStyle.formatDuration(duration)
        }
        let end = recording.endedAt ?? Date()
        return RecordingStatusStyle.formatDuration(end.timeIntervalSince(recording.startedAt))
    }

    private var elapsedAccessibility: String {
        let seconds: Int
        if let activeID = model.activeRecordingID {
            let duration = model.audioDuration(for: activeID)
            seconds = max(0, Int(duration))
        } else if let recording = model.snapshot.recording {
            let duration = model.audioDuration(for: recording.id)
            seconds = max(0, Int(duration))
        } else {
            return "0 分 0 秒"
        }
        return "\(seconds / 60) 分 \(seconds % 60) 秒"
    }
}


private struct ImportActivityBanner: View {
    let activity: ImportActivity

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.statusText)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                Text("导入在后台处理，不影响麦克风录音")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("import-activity-banner")
    }
}

private struct ImportNoticeBanner: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: text.hasPrefix("导入失败") || text.hasPrefix("已有导入")
                  ? "exclamationmark.triangle"
                  : "checkmark.circle")
                .foregroundStyle(text.hasPrefix("导入失败") ? Color.orange : Color.secondary)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .accessibilityIdentifier("import-notice-banner")
    }
}

private struct SettingsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(OnboardingPreferences.documentSyncKey) private var documentSyncEnabled = false
    @AppStorage(OnboardingPreferences.encryptedVoiceprintSyncKey) private var encryptedVoiceprintSyncEnabled = false
    @AppStorage(TranscriptionLanguageMode.preferenceKey) private var languageModeRaw =
        TranscriptionLanguageMode.default.rawValue
    @AppStorage(BackgroundTranscriptionPreferences.enabledKey) private var backgroundTranscriptionEnabled = false
    @AppStorage(ExportPackagePreferences.includesOriginalAudioKey) private var exportPackageIncludesOriginalAudio = false
    @State private var syncStatus = DocumentSyncStatusCenter.shared
    let model: RecordingCoreModel
    let reduceMotion: Bool

    private var languageModeBinding: Binding<TranscriptionLanguageMode> {
        Binding(
            get: { TranscriptionLanguageMode(rawValue: languageModeRaw) ?? .default },
            set: { languageModeRaw = $0.rawValue }
        )
    }

    var body: some View {
        NavigationStack {
            List {
                if TrialQuotaLedger.isManualTrialEnabled {
                    TrialQuotaSettingsSection(trial: model.trialEntitlement)
                }

                Section("界面语言") {
                    Picker("语言 / Language", selection: Binding(
                        get: { AppLanguageCenter.shared.selectedLanguage },
                        set: { AppLanguageCenter.shared.selectedLanguage = $0 }
                    )) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    .accessibilityIdentifier("settings-app-language")
                }

                Section("转写") {
                    Picker("语言模式", selection: languageModeBinding) {
                        ForEach(TranscriptionLanguageMode.allCases) { mode in
                            Text(mode.settingsTitle).tag(mode)
                        }
                    }
                    .accessibilityIdentifier("settings-language-mode")
                    Text("默认为中文。自动识别会让模型在中文、粤语、英语、日语和韩语之间判断。仅影响之后开始的新录音与新导入；已完成文稿不会自动重跑。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if #available(iOS 26.0, *) {
                        Toggle("允许转写在后台继续", isOn: $backgroundTranscriptionEnabled)
                            .accessibilityIdentifier("settings-background-transcription")
                        Text("仅在你停止录音、导入或手动重试后申请。语音仍在本机处理；系统可因电量、发热或你的取消操作中止，之后回到应用会继续。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("iOS 26 以上可允许长转写在后台继续；当前系统会在回到应用后自动续跑。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("同步") {
                    if let attention = syncStatus.attention {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(attention.title, systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color(red: 1.0, green: 0.62, blue: 0.04))
                                .accessibilityIdentifier("sync-needs-attention")
                            Text(attention.message)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            if !attention.conflictRelativePaths.isEmpty {
                                Text(attention.conflictRelativePaths.joined(separator: "\n"))
                                    .font(.system(.caption2, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                            Text("状态：\(DocumentSyncAttention.needsAttentionState)。本地录音不受影响。")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Button("清除提示") {
                                syncStatus.clearAttention()
                            }
                            .font(.footnote)
                        }
                        .padding(.vertical, 4)
                    }
                    Toggle("同步 Markdown 与 JSON 文档", isOn: $documentSyncEnabled)
                    Text("公开 VoiceContext 文档（含文件夹归类元数据）；原始音频与明文声纹永不进入公开目录。iCloud 不可用时仍保存在本机。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Toggle("同步加密的已确认声纹档案", isOn: $encryptedVoiceprintSyncEnabled)
                    Text("AES-GCM 加密后写入私有 iCloud 路径；关闭同步时不保留云端档案。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("任务与调度") {
                    NavigationLink {
                        TranscriptionCenterView(model: model)
                    } label: {
                        Label("转写任务中心", systemImage: "waveform.badge.magnifyingglass")
                    }
                    Text("实时监控后台转写队列、分片推理状态与异常排障。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Codex Skill") {
                    NavigationLink {
                        CodexSkillSettingsView(model: model)
                    } label: {
                        Label("会议纪要 Skill", systemImage: "sparkles")
                    }
                    Text("仅 complete 会议可生成纪要；Skill 与模板写入本机 VoiceContext，iCloud 可用时再镜像。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("导入") {
                    Label("文件：选择 m4a / wav / mp3 等音频", systemImage: "folder")
                    Label("照片与视频：抽取视频音轨后导入", systemImage: "photo.on.rectangle")
                    Text("语音备忘录请先「存储到文件」，再通过「导入 → 文件」选择。v1 不含 Share Extension。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("长视频无产品时长上限；导入与转写排队进行，不阻塞新的麦克风录音。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("导出") {
                    Toggle("资料包包含原始录音", isOn: $exportPackageIncludesOriginalAudio)
                        .accessibilityIdentifier("settings-export-package-audio")
                    Text("默认关闭。开启后，新生成的 ZIP 资料包会尝试加入原始录音，会显著增加文件大小和准备时间。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("隐私与许可") {
                    Label("录音和文稿默认保存在本机", systemImage: "lock")

                    NavigationLink {
                        PrivacyAndPermissionsView()
                    } label: {
                        Label("隐私与权限", systemImage: "hand.raised")
                    }

                    NavigationLink {
                        ThirdPartyLicensesView()
                    } label: {
                        Label("第三方许可与归因", systemImage: "doc.text")
                    }
                }

                Section {
                    LabeledContent("音频保留") {
                        Text("默认 7 天")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("记录数") {
                        Text("\(model.recordings.count)")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("记录")
                }

                #if DEBUG
                Section("开发验证") {
                    NavigationLink {
                        RecordingCoreValidationScreen(model: model)
                    } label: {
                        Label("录音核心验证", systemImage: "stethoscope")
                    }
                }
                #endif
            }
            .navigationTitle("我的")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onChange(of: encryptedVoiceprintSyncEnabled) { _, enabled in
                guard !enabled else { return }
                // Acceptance: 关闭同步无云档案 — remove private cloud copy promptly.
                Task.detached {
                    guard let url = try? VoiceprintArchiveStorage.defaultURL() else { return }
                    let result = EncryptedVoiceprintiCloudMirror.publish(
                        localEncryptedURL: url,
                        configuration: EncryptedVoiceprintiCloudMirror.Configuration(
                            isEncryptedVoiceprintSyncEnabled: { false }
                        )
                    )
                    await MainActor.run {
                        DocumentSyncStatusCenter.shared.record(voiceprint: result)
                    }
                }
            }
            .onChange(of: backgroundTranscriptionEnabled) { _, _ in
                Task { await model.backgroundTranscriptionPreferenceChanged() }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if model.showsSessionChrome {
                    RecordingBar(model: model, reduceMotion: reduceMotion)
                }
            }
        }
    }
}

private struct CodexSkillSettingsView: View {
    let model: RecordingCoreModel
    @State private var statusMessage: String?
    @State private var isSeeding = false

    var body: some View {
        List {
            Section("本机公开目录") {
                Text("Skill 与默认模板导出到 Documents/VoiceContext（文件 App → 我的 iPhone → VoiceContext）。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                LabeledContent("Skill") {
                    Text("Skill/generate-meeting-minutes")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                LabeledContent("模板") {
                    Text("Templates/default-meeting-minutes.md")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            Section("操作") {
                Button {
                    Task {
                        isSeeding = true
                        defer { isSeeding = false }
                        do {
                            let result = try await model.seedSkillPack()
                            let mirrorNote: String
                            if let mirror = result.iCloudMirror {
                                switch mirror.destination {
                                case .iCloud:
                                    mirrorNote = "；已尝试镜像到 iCloud Documents"
                                case .localOnly:
                                    mirrorNote = "；iCloud 未就绪，仅本机"
                                case .skipped:
                                    mirrorNote = "；本次跳过 iCloud"
                                }
                            } else {
                                mirrorNote = ""
                            }
                            statusMessage = "已导出 \(result.copiedFileCount) 个文件到 VoiceContext\(mirrorNote)"
                        } catch {
                            statusMessage = "导出失败：\(error.localizedDescription)"
                        }
                    }
                } label: {
                    if isSeeding {
                        ProgressView()
                    } else {
                        Label("导出 / 刷新 Skill 与模板", systemImage: "square.and.arrow.down")
                    }
                }
                .disabled(isSeeding)
                .accessibilityIdentifier("seed-skill-pack")
            }

            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Mac Codex") {
                Text("在 Mac 上指向 VoiceContext/Skill/generate-meeting-minutes，或复制该目录到 Codex skills。详见 docs/features/generate-meeting-minutes-skill.md。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Codex Skill")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Kept out of the production navigation tree, but connected to the exact
/// model used by the product screens so the remaining #19 device checks can
/// inspect journal/SQLite evidence without reviving the old main UI.
#if DEBUG
private struct RecordingCoreValidationScreen: View {
    let model: RecordingCoreModel

    var body: some View {
        List {
            Section("会话") {
                LabeledContent("状态") {
                    Label(validationStateText, systemImage: validationStateSymbol)
                        .foregroundStyle(validationStateColor)
                }
                LabeledContent("状态事件") {
                    Text("\(model.snapshot.appliedEventCount)")
                        .monospacedDigit()
                }

                Button(model.captureIsActive ? "停止录音" : "开始录音") {
                    Task {
                        if model.captureIsActive {
                            await model.stop()
                        } else {
                            await model.start(title: "验证录音")
                        }
                    }
                }
                .tint(model.captureIsActive ? .red : .primary)

                if model.captureIsActive {
                    Button(model.presentation == .paused ? "继续" : "暂停") {
                        Task { await model.pauseOrResume() }
                    }
                    .disabled(model.presentation == .interrupted)
                }
            }

            Section("分片与缺口") {
                LabeledContent("已关闭分片") {
                    Text("\(model.snapshot.chunks.count)")
                }
                LabeledContent("显式 gap") {
                    Text("\(model.snapshot.gaps.count)")
                }
                ForEach(model.snapshot.gaps) { gap in
                    Label(validationGapText(gap), systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
            }

            Section("恢复与完整性") {
                Button("再次运行恢复（幂等检查）") {
                    Task { await model.runRecoveryAgain() }
                }
                Button("运行完整性诊断") {
                    Task { await model.runDiagnostics() }
                }
                Button("生成验证报告") {
                    Task { await model.makeReport() }
                }

                if let issues = model.integrityIssues {
                    Label(
                        issues.isEmpty ? "无完整性问题" : "发现 \(issues.count) 个完整性问题",
                        systemImage: issues.isEmpty ? "checkmark.circle" : "exclamationmark.triangle"
                    )
                    .foregroundStyle(issues.isEmpty ? .green : .orange)
                }

                if let reportURL = model.reportURL {
                    ShareLink(item: reportURL) {
                        Label("分享验证报告", systemImage: "square.and.arrow.up")
                    }
                }
            }

            if let notice = model.notice {
                Section {
                    Text(notice)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("录音核心验证")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var validationStateText: String {
        switch model.presentation {
        case .idle: "未开始"
        case let .failed(message): "失败：\(message)"
        default: RecordingStatusStyle.text(for: model.presentation)
        }
    }

    private var validationStateSymbol: String {
        switch model.presentation {
        case .idle: "circle.dashed"
        case .failed: "xmark.octagon.fill"
        default: RecordingStatusStyle.symbolName(for: model.presentation)
        }
    }

    private var validationStateColor: Color {
        RecordingStatusStyle.color(for: model.presentation)
    }

    private func validationGapText(_ gap: RecordingGap) -> String {
        let end = gap.endSample.map(String.init) ?? "未关闭"
        return "\(gap.reason.rawValue)：\(gap.startSample) → \(end)"
    }
}
#endif

private extension ScenePhaseLike {
    init(_ phase: ScenePhase) {
        switch phase {
        case .active: self = .active
        case .inactive: self = .inactive
        case .background: self = .background
        @unknown default: self = .inactive
        }
    }
}

#Preview {
    ContentView()
}

private struct FolderManagerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: RecordingCoreModel
    @Binding var folderFilter: FolderListFilter
    @State private var newFolderName = ""
    @State private var renameTarget: RecordingFolder?
    @State private var renameText = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section("新建文件夹") {
                    HStack {
                        TextField("文件夹名称", text: $newFolderName)
                            .accessibilityIdentifier("folder-create-field")
                        Button("创建") {
                            Task { await createFolder() }
                        }
                        .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("folder-create-button")
                    }
                }

                Section("已有文件夹") {
                    if model.folders.isEmpty {
                        Text("还没有文件夹")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.folders) { folder in
                            HStack {
                                Button {
                                    folderFilter = .folder(folder.id)
                                    dismiss()
                                } label: {
                                    Label(folder.name, systemImage: "folder")
                                }
                                Spacer()
                                Button("重命名") {
                                    renameTarget = folder
                                    renameText = folder.name
                                }
                                .font(.footnote)
                            }
                            .accessibilityIdentifier("folder-row-\(folder.id.uuidString)")
                        }
                        .onDelete { indexSet in
                            Task { await deleteFolders(at: indexSet) }
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.orange)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("文件夹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .alert(
                "重命名文件夹",
                isPresented: Binding(
                    get: { renameTarget != nil },
                    set: { if !$0 { renameTarget = nil } }
                )
            ) {
                TextField("名称", text: $renameText)
                Button("取消", role: .cancel) { renameTarget = nil }
                Button("保存") {
                    Task { await renameFolder() }
                }
            } message: {
                Text("删除文件夹不会删除录音，记录会回到未分类。")
            }
        }
    }

    @MainActor
    private func createFolder() async {
        do {
            _ = try await model.createFolder(named: newFolderName)
            newFolderName = ""
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func renameFolder() async {
        guard let renameTarget else { return }
        do {
            _ = try await model.renameFolder(id: renameTarget.id, to: renameText)
            self.renameTarget = nil
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func deleteFolders(at offsets: IndexSet) async {
        for index in offsets {
            let folder = model.folders[index]
            do {
                _ = try await model.deleteFolder(id: folder.id)
                if case .folder(let id) = folderFilter, id == folder.id {
                    folderFilter = .all
                }
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct MoveToFolderSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: RecordingCoreModel
    let recordingID: UUID
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Button {
                    Task { await move(to: nil) }
                } label: {
                    Label("未分类", systemImage: "tray")
                }
                .accessibilityIdentifier("move-to-uncategorized")

                ForEach(model.folders) { folder in
                    Button {
                        Task { await move(to: folder.id) }
                    } label: {
                        Label(folder.name, systemImage: "folder")
                    }
                    .accessibilityIdentifier("move-to-\(folder.id.uuidString)")
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
            }
            .navigationTitle("移动到文件夹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    @MainActor
    private func move(to folderID: UUID?) async {
        do {
            _ = try await model.moveRecording(recordingID, toFolder: folderID)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct QuickDateJumpSheet: View {
    let recordingGroups: [RecordingDayGroup]
    var initialDate: Date? = nil
    let onSelectDate: (Date) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var selectedYear: Int = 0
    @State private var selectedMonth: Int = 0
    @State private var selectedDay: Int = 0

    private let calendar = Calendar.current

    private var availableYears: [Int] {
        Array(Set(recordingGroups.map { calendar.component(.year, from: $0.date) })).sorted(by: >)
    }

    private var availableMonths: [Int] {
        Array(Set(recordingGroups.filter {
            calendar.component(.year, from: $0.date) == selectedYear
        }.map {
            calendar.component(.month, from: $0.date)
        })).sorted(by: >)
    }

    private var availableDays: [Int] {
        Array(Set(recordingGroups.filter {
            calendar.component(.year, from: $0.date) == selectedYear &&
            calendar.component(.month, from: $0.date) == selectedMonth
        }.map {
            calendar.component(.day, from: $0.date)
        })).sorted(by: >)
    }

    private var matchedGroup: RecordingDayGroup? {
        recordingGroups.first {
            calendar.component(.year, from: $0.date) == selectedYear &&
            calendar.component(.month, from: $0.date) == selectedMonth &&
            calendar.component(.day, from: $0.date) == selectedDay
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if availableYears.isEmpty {
                    ContentUnavailableView("暂无可用录音日期", systemImage: "calendar.badge.exclamationmark")
                } else {
                    Text("选择已有录音记录的年月日快速定位")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)

                    HStack(spacing: 0) {
                        // Year Wheel
                        Picker("年", selection: $selectedYear) {
                            ForEach(availableYears, id: \.self) { year in
                                Text("\(String(year))年").tag(year)
                            }
                        }
                        .pickerStyle(.wheel)
                        .clipped()
                        .frame(maxWidth: .infinity)
                        .onChange(of: selectedYear) { _, newYear in
                            revalidateMonthAndDay(year: newYear)
                        }

                        // Month Wheel
                        Picker("月", selection: $selectedMonth) {
                            ForEach(availableMonths, id: \.self) { month in
                                Text("\(month)月").tag(month)
                            }
                        }
                        .pickerStyle(.wheel)
                        .clipped()
                        .frame(maxWidth: .infinity)
                        .onChange(of: selectedMonth) { _, newMonth in
                            revalidateDay(month: newMonth)
                        }

                        // Day Wheel
                        Picker("日", selection: $selectedDay) {
                            ForEach(availableDays, id: \.self) { day in
                                Text("\(day)日").tag(day)
                            }
                        }
                        .pickerStyle(.wheel)
                        .clipped()
                        .frame(maxWidth: .infinity)
                    }
                    .frame(height: 160)

                    if let group = matchedGroup {
                        HStack(spacing: 6) {
                            Image(systemName: "waveform")
                                .foregroundStyle(Color.accentColor)
                            Text("该日期共有 \(group.recordings.count) 条录音")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .navigationTitle("快速跳转日期")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("跳转") {
                        if let group = matchedGroup {
                            onSelectDate(group.date)
                        }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(matchedGroup == nil)
                }
            }
            .onAppear {
                initializeSelection()
            }
        }
        .presentationDetents([.height(320)])
        .presentationDragIndicator(.visible)
    }

    private func initializeSelection() {
        let target = initialDate ?? recordingGroups.first?.date ?? Date()
        let targetYear = calendar.component(.year, from: target)
        if availableYears.contains(targetYear) {
            selectedYear = targetYear
        } else {
            selectedYear = availableYears.first ?? targetYear
        }

        let months = Array(Set(recordingGroups.filter {
            calendar.component(.year, from: $0.date) == selectedYear
        }.map {
            calendar.component(.month, from: $0.date)
        })).sorted(by: >)

        let targetMonth = calendar.component(.month, from: target)
        if months.contains(targetMonth) {
            selectedMonth = targetMonth
        } else {
            selectedMonth = months.first ?? 1
        }

        let days = Array(Set(recordingGroups.filter {
            calendar.component(.year, from: $0.date) == selectedYear &&
            calendar.component(.month, from: $0.date) == selectedMonth
        }.map {
            calendar.component(.day, from: $0.date)
        })).sorted(by: >)

        let targetDay = calendar.component(.day, from: target)
        if days.contains(targetDay) {
            selectedDay = targetDay
        } else {
            selectedDay = days.first ?? 1
        }
    }

    private func revalidateMonthAndDay(year: Int) {
        let months = Array(Set(recordingGroups.filter {
            calendar.component(.year, from: $0.date) == year
        }.map {
            calendar.component(.month, from: $0.date)
        })).sorted(by: >)

        if !months.contains(selectedMonth) {
            selectedMonth = months.first ?? 1
        }
        revalidateDay(month: selectedMonth)
    }

    private func revalidateDay(month: Int) {
        let days = Array(Set(recordingGroups.filter {
            calendar.component(.year, from: $0.date) == selectedYear &&
            calendar.component(.month, from: $0.date) == month
        }.map {
            calendar.component(.day, from: $0.date)
        })).sorted(by: >)

        if !days.contains(selectedDay) {
            selectedDay = days.first ?? 1
        }
    }
}
