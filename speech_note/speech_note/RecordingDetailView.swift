import SwiftUI
import QuickLook
import UniformTypeIdentifiers

private typealias SentenceBubble = RecordingDetailPlaybackPresentation.SentenceBubble
private typealias SpeakerBubbleGroup = RecordingDetailPlaybackPresentation.SpeakerBubbleGroup

/// Redesigned professional Recording & Meeting Detail Screen.
/// Built with Apple Voice Memos-style native utility aesthetics (DESIGN.md).
struct RecordingDetailScreen: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    let model: RecordingCoreModel
    let recordingID: UUID
    /// Optional list-search query used to highlight / scroll to the first hit.
    var highlightQuery: String? = nil
    var scrollToSegmentID: UUID? = nil

    @State private var chunks: [AudioChunk] = []
    @State private var didAutoScrollToHit = false
    @State private var lastScrolledActiveSegmentID: UUID?
    @State private var importedAsset: ImportedAudioAsset?
    @State private var processingRanges: [ProcessingRange] = []
    @State private var progress: RecordingPresentationProgress?
    @State private var transcript: TranscriptDocumentV1?
    @State private var jobs: [RecordingJob] = []
    @State private var loadedPlayableChunkIDs: [UUID] = []
    @State private var loadedAssetURL: URL?
    @State private var speakerBindings: [MeetingSpeakerBinding] = []
    @State private var loadError: String?
    @State private var transcriptError: String?
    @State private var contentTab: DetailContentTab = .transcript
    @StateObject private var timelinePlayer = RecordingAudioTimelinePlayer()

    // Speaker to Client binding state
    @State private var selectedSpeakerForClientBinding: MeetingSpeakerBinding? = nil
    @State private var isNewClientSheetPresented = false
    @State private var speakerForNewClient: MeetingSpeakerBinding? = nil
    @State private var speakerToRename: MeetingSpeakerBinding? = nil
    @State private var newSpeakerName: String = ""
    @State private var isRenameAlertPresented = false
    @State private var isParticipantPickerPresented = false
    @State private var selectedBubbleID: UUID? = nil
    @State private var selectedSpeakerFilter: String? = nil
    @State private var isCopiedToastPresented = false
    @State private var isExportSheetPresented = false
    @State private var isMetadataEditSheetPresented = false
    @State private var editingSegmentRow: RecordingDetailPlaybackPresentation.TimedRow? = nil
    @State private var speakerAssignmentSegmentID: UUID? = nil
    @State private var isDeleteConfirmationPresented = false
    @State private var isSpeakerRecognitionConfirmationPresented = false
    @State private var attachments: [RecordingAttachment] = []
    @State private var isAttachmentPickerPresented = false
    @State private var attachmentPendingDeletion: RecordingAttachment?
    @State private var previewAttachmentURL: URL?
    @State private var attachmentError: String?
    @State private var isAddingAttachments = false

    private struct SpeakerAssignmentOption: Identifiable {
        let speaker: String
        let title: String

        var id: String { speaker }
    }

    private enum DetailContentTab: String, CaseIterable, Identifiable {
        case transcript
        case speakers
        case details

        var id: String { rawValue }

        var title: String {
            switch self {
            case .transcript: "逐字稿"
            case .speakers: "参会人与声纹"
            case .details: "详细信息"
            }
        }
    }

    private var contentSection: some View {
        Group {
            switch contentTab {
            case .transcript:
                transcriptDocumentView
            case .speakers:
                speakersManagementView
            case .details:
                technicalDetailsView
            }
        }
    }

    private var topBarTrailingMenu: some View {
        Menu {
            Section {
                Button {
                    Task {
                        await model.append(recordingID: recordingID)
                    }
                } label: {
                    Label("增录音频…", systemImage: "mic.badge.plus")
                }
                .disabled(model.captureIsActive)

                Button {
                    isMetadataEditSheetPresented = true
                } label: {
                    Label("编辑录音信息…", systemImage: "pencil")
                }

                Button {
                    isExportSheetPresented = true
                } label: {
                    Label("导出与分享…", systemImage: "square.and.arrow.up")
                }
                .disabled(transcript == nil)
            }

            Section {
                Button {
                    if let fullText = transcript?.segments.map(\.text).joined(separator: "\n"), !fullText.isEmpty {
                        UIPasteboard.general.string = fullText
                        withAnimation { isCopiedToastPresented = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation { isCopiedToastPresented = false }
                        }
                    }
                } label: {
                    Label("复制全文逐字稿", systemImage: "doc.on.doc")
                }
                .disabled(transcript == nil || transcript?.segments.isEmpty == true)

                Button {
                    Task {
                        await model.retryTranscription(recordingID: recordingID)
                        await loadDetail()
                    }
                } label: {
                    Label("重新转写 / 分析", systemImage: "arrow.clockwise")
                }

                if !currentRecording.isMeeting {
                    Button {
                        isSpeakerRecognitionConfirmationPresented = true
                    } label: {
                        Label("识别说话人…", systemImage: "person.2.wave.2")
                    }
                    .disabled(transcript == nil)
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body)
        }
        .accessibilityLabel("更多操作")
    }

    @ViewBuilder
    private var copiedToastOverlay: some View {
        if isCopiedToastPresented {
            Text("已复制文本")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.8), in: Capsule())
                .padding(.bottom, 24)
                .transition(.opacity.combined(with: .scale))
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headerCard
                    contentTabsPicker
                    contentSection
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .background(Color(uiColor: .systemBackground))
            .onChange(of: transcript?.revision) { _, _ in
                scrollToSearchHit(using: proxy)
            }
            .onAppear {
                scrollToSearchHit(using: proxy)
            }
            .onChange(of: timelinePlayer.currentTime) { _, _ in
                scrollToActiveSegment(using: proxy)
            }
            .onChange(of: timelinePlayer.isPlaying) { _, playing in
                if playing { scrollToActiveSegment(using: proxy) }
            }
            .navigationTitle(currentRecording.isMeeting ? "会议详情" : "录音详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    topBarTrailingMenu
                }
            }
            .sheet(isPresented: $isExportSheetPresented) {
                NavigationStack {
                    ExportDocumentsDestination(model: model, recordingID: recordingID)
                }
            }
            .sheet(isPresented: $isMetadataEditSheetPresented) {
                EditRecordingMetadataSheet(
                    model: model,
                    recordingID: recordingID,
                    initialTitle: displayTitle,
                    initialTags: transcript?.tags ?? [],
                    initialLocation: currentRecording.locationName
                )
            }
            .alert("启用说话人识别？", isPresented: $isSpeakerRecognitionConfirmationPresented) {
                Button("取消", role: .cancel) {}
                Button("开始识别") {
                    Task {
                        await model.enableSpeakerRecognition(recordingID: recordingID)
                        await loadDetail()
                    }
                }
            } message: {
                Text("将使用现有逐字稿的分句时间戳提取声纹并聚类，原始录音和逐字稿不会被覆盖。")
            }
            .fileImporter(
                isPresented: $isAttachmentPickerPresented,
                allowedContentTypes: [.data],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case let .success(urls):
                    Task { await addAttachments(from: urls) }
                case let .failure(error):
                    attachmentError = error.localizedDescription
                }
            }
            .quickLookPreview($previewAttachmentURL)
            .confirmationDialog(
                "移除相关文件？",
                isPresented: Binding(
                    get: { attachmentPendingDeletion != nil },
                    set: { if !$0 { attachmentPendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("从本录音移除", role: .destructive) {
                    guard let attachment = attachmentPendingDeletion else { return }
                    Task { await removeAttachment(attachment) }
                }
                Button("取消", role: .cancel) { attachmentPendingDeletion = nil }
            } message: {
                Text("只删除 App 中与这条录音关联的副本，不会删除 Files 中的原文件。")
            }
            .sheet(item: $editingSegmentRow) { row in
                EditSegmentTextSheet(
                    model: model,
                    recordingID: recordingID,
                    row: row,
                    onSaved: {
                        await loadDetail()
                    }
                )
            }
            .sheet(item: $selectedSpeakerForClientBinding) { binding in
                SpeakerClientPickerSheet(
                    model: model,
                    binding: binding,
                    onSelectClient: { client in
                        Task {
                            await bindSpeakerToClient(binding: binding, client: client)
                        }
                    },
                    onCreateNew: {
                        speakerForNewClient = binding
                        isNewClientSheetPresented = true
                    }
                )
            }
            .sheet(isPresented: $isNewClientSheetPresented) {
                if let speaker = speakerForNewClient {
                    ClientEditSheet(
                        model: model,
                        existingClient: ClientProfile(
                            name: speaker.chipText.replacingOccurrences(of: SpeakerIdentityLabeling.suspectedPrefix, with: "")
                        )
                    ) { newClient in
                        Task {
                            await createClientAndBindSpeaker(client: newClient, binding: speaker)
                        }
                    }
                }
            }
            .sheet(isPresented: $isParticipantPickerPresented) {
                MeetingParticipantPickerSheet(
                    model: model,
                    existingClientIDs: Set(transcript?.participants.compactMap(\.clientID) ?? []),
                    onAddName: { name in
                        Task { await addMeetingParticipant(name: name) }
                    },
                    onSelectClient: { client in
                        Task { await addMeetingParticipant(client: client) }
                    }
                )
            }
            .alert("修改发言人名称", isPresented: $isRenameAlertPresented) {
                TextField("输入发言人名称", text: $newSpeakerName)
                Button("取消", role: .cancel) {
                    speakerToRename = nil
                    newSpeakerName = ""
                }
                Button("保存") {
                    if let speaker = speakerToRename, !newSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let trimmed = newSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task {
                            _ = try? await model.renameSpeakerIdentity(
                                recordingID: recordingID,
                                temporaryLabel: speaker.temporaryLabel,
                                displayName: trimmed
                            )
                            await loadDetail()
                        }
                    }
                    speakerToRename = nil
                    newSpeakerName = ""
                }
            } message: {
                if let speaker = speakerToRename {
                    Text("修改后，录音中属于「\(speaker.chipText)」的所有气泡将同步更新。")
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if model.showsSessionChrome && model.activeRecordingID != recordingID {
                    RecordingBar(model: model, reduceMotion: reduceMotion)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomControlDock
            }
            .overlay(alignment: .bottom) {
                copiedToastOverlay
            }
            .task(id: recordingID) {
                while !Task.isCancelled {
                    await loadDetail()
                    let hasActiveWork = jobs.contains { job in
                        if job.kind != .transcription { return false }
                        return job.state == .running || job.state == .pending
                    }
                    let processing = progress?.processing
                    let isQueued: Bool
                    switch processing {
                    case .queued, .processing, .speakerFinalization, .deferredUntilForeground:
                        isQueued = true
                    default:
                        isQueued = false
                    }
                    let isActivelyTranscribing = isCapturingThisRecording || hasActiveWork || isQueued

                    if isActivelyTranscribing {
                        try? await Task.sleep(for: .seconds(1))
                    } else {
                        try? await Task.sleep(for: .seconds(3))
                    }
                }
            }
            .onDisappear {
                timelinePlayer.stop()
            }
        }
    }

    // MARK: - Header Card

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(displayTitle)
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)
                .accessibilityIdentifier("detail-title")

            // Meta tags row: 时间、时长、文件夹、状态
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                    Text(currentRecording.startedAt.standardDateTimeString)
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

                Text("·").foregroundStyle(.tertiary)

                HStack(spacing: 4) {
                    Image(systemName: "clock")
                    Text(durationText)
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

                if let folderName = model.folderName(for: currentRecording.id) {
                    Text("·").foregroundStyle(.tertiary)
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                        Text(folderName)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                statusPill
            }

            if progress?.processing == .speakerFinalization {
                Label(
                    RecordingStatusStyle.processingText(for: .speakerFinalization),
                    systemImage: RecordingStatusStyle.processingSymbolName(for: .speakerFinalization)
                )
                .font(.caption)
                .foregroundStyle(RecordingStatusStyle.processingColor(for: .speakerFinalization))
            }

            // 第三行：地理位置（独立一行）
            if let location = currentRecording.locationName, !location.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.caption)
                    Text(location)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .foregroundStyle(.secondary)
            }

            if let transcript, !transcript.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(transcript.tags, id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color(uiColor: .secondarySystemBackground))
                                .clipShape(Capsule())
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var statusPill: some View {
        let processing = progress?.processing ?? .idle
        let capture = progress?.capture ?? (isCapturingThisRecording ? .recording : currentRecording.persistedCaptureState)

        let (title, icon, color): (String, String, Color) = {
            if isCapturingThisRecording || capture == .recording {
                return (model.presentation == .paused ? "已暂停" : "录制中", "circle.fill", .red)
            }
            switch processing {
            case .processing, .queued:
                return ("正在处理", "hourglass", .orange)
            case .speakerFinalization:
                return ("整理说话人", "person.2", .orange)
            case .deferredUntilForeground:
                return ("待恢复", "pause.circle", .orange)
            case .lockedPendingPurchase:
                return ("待解锁", "lock", .orange)
            case .needsAttention:
                return ("注意", "exclamationmark.triangle", .red)
            case .complete:
                return ("已就绪", "checkmark.circle.fill", .green)
            case .idle:
                return (currentRecording.state == .complete ? "已就绪" : "待处理", "checkmark.circle", .secondary)
            }
        }()

        return HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(title)
                .font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.12))
        .foregroundStyle(color)
        .clipShape(Capsule())
    }

    private var durationText: String {
        if isCapturingThisRecording {
            return elapsedText
        }
        if let importedAsset {
            return RecordingStatusStyle.formatDuration(importedAsset.durationSeconds)
        }
        let totalSamples = chunks.reduce(Int64(0)) { $0 + max(0, $1.endSample - $1.startSample) }
        if totalSamples > 0 {
            let durationSeconds = Double(totalSamples) / AACSegmentRecorder.targetSampleRate
            return RecordingStatusStyle.formatDuration(durationSeconds)
        }
        if timelinePlayer.duration > 0 {
            return RecordingStatusStyle.formatDuration(timelinePlayer.duration)
        }
        let modelDuration = model.audioDuration(for: recordingID)
        if modelDuration > 0 {
            return RecordingStatusStyle.formatDuration(modelDuration)
        }
        return currentRecording.endedAt.map {
            RecordingStatusStyle.formatDuration($0.timeIntervalSince(currentRecording.startedAt))
        } ?? "录制中"
    }

    private var elapsedText: String {
        let duration = model.audioDuration(for: recordingID)
        if duration > 0 {
            return RecordingStatusStyle.formatDuration(duration)
        }
        guard let recording = model.snapshot.recording, recording.id == recordingID else {
            let start = currentRecording.startedAt
            let fallbackDuration = max(0, Date().timeIntervalSince(start))
            return RecordingStatusStyle.formatDuration(fallbackDuration)
        }
        let ending = recording.endedAt ?? Date()
        return RecordingStatusStyle.formatDuration(ending.timeIntervalSince(recording.startedAt))
    }

    private var isCapturingThisRecording: Bool {
        model.activeRecordingID == recordingID && (model.captureIsActive || model.presentation == .stopping || model.presentation == .paused || model.presentation == .interrupted)
    }

    // MARK: - Bottom Control Dock (Unified Player & Recorder)

    @ViewBuilder
    private var bottomControlDock: some View {
        VStack(spacing: 0) {
            Divider()
            if isCapturingThisRecording {
                recordingDockContent
            } else {
                playbackDockContent
            }
        }
        .background(.bar)
    }

    private var recordingDockContent: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                LiveWaveformView(
                    inputLevel: model.inputLevel,
                    isRecording: model.presentation == .recording,
                    tintColor: .red,
                    barCount: 24,
                    maxHeight: 28
                )

                Spacer()

                Text(elapsedText)
                    .font(.system(size: 26, weight: .regular, design: .rounded).monospacedDigit())
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 20)

            HStack(spacing: 16) {
                Button {
                    Task { await model.pauseOrResume() }
                } label: {
                    Label(
                        model.presentation == .paused ? "继续" : "暂停",
                        systemImage: model.presentation == .paused ? "play.fill" : "pause.fill"
                    )
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(model.presentation == .interrupted || model.presentation == .stopping)

                Button(role: .destructive) {
                    Task {
                        await model.stop()
                        dismiss()
                    }
                } label: {
                    Label(
                        model.presentation == .stopping ? "停止中" : "完成录音",
                        systemImage: "stop.fill"
                    )
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(model.presentation == .stopping)
            }
            .padding(.horizontal, 20)
        }
        .padding(.top, 10)
        .padding(.bottom, 12)
        .sensoryFeedback(.impact(weight: .medium), trigger: model.presentation)
    }

    private var playbackDockContent: some View {
        VStack(spacing: 8) {
            if hasPlayableAudio {
                HStack(spacing: 12) {
                    Slider(
                        value: Binding(
                            get: { timelinePlayer.currentTime },
                            set: { timelinePlayer.seek(to: $0) }
                        ),
                        in: 0...max(timelinePlayer.duration, 0.01)
                    )
                    .tint(.red)
                    .accessibilityLabel("音频时间轴")

                    Text("-\(RecordingStatusStyle.formatDuration(max(0, timelinePlayer.duration - timelinePlayer.currentTime)))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)

                HStack(spacing: 28) {
                    Spacer()

                    Button {
                        timelinePlayer.seek(by: -15)
                    } label: {
                        Image(systemName: "gobackward.15")
                            .font(.body)
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("快退 15 秒")

                    Button {
                        timelinePlayer.togglePlayback()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.primary)
                                .frame(width: 44, height: 44)
                            Image(systemName: timelinePlayer.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title3)
                                .foregroundStyle(Color(uiColor: .systemBackground))
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(timelinePlayer.isPlaying ? "暂停" : "播放")

                    Button {
                        timelinePlayer.seek(by: 15)
                    } label: {
                        Image(systemName: "goforward.15")
                            .font(.body)
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("快进 15 秒")

                    Menu {
                        ForEach([Float(0.75), 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                            Button("\(rate, specifier: "%.2g")×") {
                                timelinePlayer.setRate(rate)
                            }
                        }
                    } label: {
                        Text("\(timelinePlayer.playbackRate, specifier: "%.2g")×")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(uiColor: .secondarySystemBackground))
                            .clipShape(Capsule())
                    }

                    Spacer()
                }
                .padding(.horizontal, 20)
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "waveform.slash")
                        .foregroundStyle(.secondary)
                    Text(transcript?.audio.availableOnThisDevice == false
                         ? "音频已在设备上清理"
                         : "暂无音频")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    // MARK: - Content Tabs Picker

    private var contentTabsPicker: some View {
        Picker("详情内容", selection: $contentTab) {
            ForEach(DetailContentTab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding(.vertical, 4)
    }

    // MARK: - Transcript Document View

    private var transcriptDocumentView: some View {
        let bubbles = transcript.map { transcriptSentenceBubbles(for: $0) } ?? []
        let groups = RecordingDetailPlaybackPresentation.groupSentenceBubbles(bubbles)
        let roster = filterableSpeakerLabels(from: bubbles)
        let displayedGroups = selectedSpeakerFilter.map { filter in
            groups.filter { $0.speaker == filter }
        } ?? groups
        let activeID = RecordingDetailPlaybackPresentation.currentBubbleID(at: timelinePlayer.currentTime, bubbles: bubbles)
        let activeSpeaker = bubbles.first(where: { $0.id == activeID })?.speaker

        let pendingOrRunningJobs = jobs.filter { $0.kind == .transcription && ($0.state == .running || $0.state == .pending) }
        let failedJobs = jobs.filter { $0.kind == .transcription && $0.state == .failed }

        return VStack(alignment: .leading, spacing: 16) {
            if roster.count >= 2 {
                speakerLegend(
                    roster: roster,
                    activeSpeaker: activeSpeaker,
                    selectedSpeaker: selectedSpeakerFilter
                )
            }

            if !displayedGroups.isEmpty {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(displayedGroups) { group in
                        transcriptBubbleGroupView(
                            group: group,
                            roster: roster,
                            activeID: activeID
                        )
                    }
                }

                if !isCapturingThisRecording && !pendingOrRunningJobs.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("已就绪 \(bubbles.count) 个分句 · 正在增量转写后续音频 (\(pendingOrRunningJobs.count) 个排队中)…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }

                if !isCapturingThisRecording && !failedJobs.isEmpty {
                    failedJobsWarningBanner(failedJobs: failedJobs)
                }
            } else if isCapturingThisRecording {
                // liveRecordingBanner is rendered below
            } else {
                if !pendingOrRunningJobs.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.regular)
                        Text("正在生成首个音频分片的转写文稿…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 36)
                } else if !failedJobs.isEmpty {
                    failedJobsCard(failedJobs: failedJobs)
                } else {
                    Text(documentPlaceholder)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 24)
                }
            }

            if isCapturingThisRecording {
                liveRecordingBanner
            }

            if let transcriptError {
                Label(transcriptError, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
        }
    }

    private func failedJobsWarningBanner(failedJobs: [RecordingJob]) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("部分后续分段暂缓或遇到异常")
                    .font(.caption.weight(.medium))
                if let err = failedJobs.first?.lastError {
                    Text(formatErrorMessage(err))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Button {
                Task {
                    await model.retryTranscription(recordingID: recordingID)
                    await loadDetail()
                }
            } label: {
                Text("重试")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.15))
                    .foregroundStyle(.orange)
                    .clipShape(Capsule())
            }
        }
        .padding(10)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private func failedJobsCard(failedJobs: [RecordingJob]) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.orange)
            Text("转写暂缓或遇到异常")
                .font(.subheadline.weight(.medium))
            if let err = failedJobs.first?.lastError {
                Text(formatErrorMessage(err))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            Button {
                Task {
                    await model.retryTranscription(recordingID: recordingID)
                    await loadDetail()
                }
            } label: {
                Text("重新转写")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.15))
                    .foregroundStyle(.orange)
                    .clipShape(Capsule())
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private func formatErrorMessage(_ error: String) -> String {
        switch error {
        case "deferredUntilThermalImproves":
            return "设备发热较严重，已暂缓以保护硬件；降温后将自动恢复转写。"
        case "deferredUntilForeground":
            return "应用曾退至后台，回到前台后将继续转写。"
        case "deferredUntilMetalAvailable":
            return "Metal 图形加速通道排队中，稍候自动执行。"
        case "lockedPendingPurchase":
            return "试用配额已达上限，待解锁后继续。"
        case "recoveredAfterTermination":
            return "应用退出后已自动恢复，排队转写中。"
        default:
            return error
        }
    }

    private var liveRecordingBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: RecordingStatusStyle.symbolName(for: model.presentation))
                .foregroundStyle(RecordingStatusStyle.color(for: model.presentation))
                .symbolEffect(.pulse, isActive: !reduceMotion && model.presentation == .recording)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.presentation == .paused ? "录音已暂停" : "正在录音并实时转写…")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                if let progress = model.sessionProgress {
                    Text(RecordingStatusStyle.progressDetailText(for: progress, isInBackground: model.isInBackground))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("每约 60 秒增量转写已关闭分片")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(14)
        .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.red.opacity(0.2), lineWidth: 1))
    }

    @ViewBuilder
    private func speakerLegend(
        roster: [String],
        activeSpeaker: String?,
        selectedSpeaker: String?
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if selectedSpeaker != nil {
                    Button {
                        selectedSpeakerFilter = nil
                    } label: {
                        Text("全部")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(uiColor: .secondarySystemBackground))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("显示全部发言")
                }
                ForEach(roster, id: \.self) { speaker in
                    let color = RecordingDetailPlaybackPresentation.color(for: speaker, roster: roster)
                    let isActive = activeSpeaker == speaker
                    let isSelected = selectedSpeaker == speaker
                    Button {
                        selectedSpeakerFilter = isSelected ? nil : speaker
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(color)
                                .frame(width: 8, height: 8)
                            Text(speaker)
                                .font(.caption.weight(isActive || isSelected ? .semibold : .regular))
                                .foregroundStyle(isActive || isSelected ? .primary : .secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(isSelected ? color.opacity(0.18) : Color(uiColor: .secondarySystemBackground))
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(isSelected ? color : .clear, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("筛选 (speaker) 的发言")
                }
            }
        }
    }

    @ViewBuilder
    private func transcriptBubbleGroupView(
        group: SpeakerBubbleGroup,
        roster: [String],
        activeID: UUID?
    ) -> some View {
        let speaker = group.speaker
        let speakerColor = speaker != nil ? RecordingDetailPlaybackPresentation.color(for: speaker!, roster: roster) : Color.secondary

        VStack(alignment: .leading, spacing: 6) {
            if let speaker, !speaker.isEmpty {
                HStack(spacing: 6) {
                    Circle()
                        .fill(speakerColor)
                        .frame(width: 8, height: 8)
                    Text(speaker)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(group.bubbles) { bubble in
                    sentenceBubbleRow(
                        bubble: bubble,
                        isCurrent: bubble.id == activeID
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func sentenceBubbleRow(
        bubble: SentenceBubble,
        isCurrent: Bool
    ) -> some View {
        let isSelected = selectedBubbleID == bubble.id
        let showTimestamp = isCurrent || isSelected

        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 8) {
                Text(bubble.text)
                    .font(.body)
                    .foregroundStyle(isCurrent ? Color.red : Color.primary)
                    .multilineTextAlignment(.leading)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                if bubble.isManuallyEdited {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.blue)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isCurrent ? Color.red.opacity(0.12) : Color(uiColor: .secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(isCurrent ? Color.red.opacity(0.45) : Color.clear, lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    selectedBubbleID = (selectedBubbleID == bubble.id ? nil : bubble.id)
                }
            }
            .contextMenu {
                Button {
                    timelinePlayer.seek(to: bubble.startTime)
                    if !timelinePlayer.isPlaying {
                        timelinePlayer.play()
                    }
                } label: {
                    Label("从此开始播放", systemImage: "play.circle")
                }
                if isSpeakerAssignmentAvailable(for: bubble.id) {
                    Button {
                        speakerAssignmentSegmentID = bubble.id
                    } label: {
                        Label("修改此句说话人", systemImage: "person.crop.circle.badge.pencil")
                    }
                }
                Button {
                    editingSegmentRow = bubble.asTimedRow
                } label: {
                    Label("编辑此句逐字稿…", systemImage: "pencil")
                }
                Button {
                    UIPasteboard.general.string = bubble.text
                    withAnimation { isCopiedToastPresented = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { isCopiedToastPresented = false }
                    }
                } label: {
                    Label("复制单句文本", systemImage: "doc.on.doc")
                }
            }
            .confirmationDialog(
                "选择此句说话人",
                isPresented: Binding(
                    get: { speakerAssignmentSegmentID == bubble.id },
                    set: { if !$0 { speakerAssignmentSegmentID = nil } }
                ),
                titleVisibility: .visible
            ) {
                ForEach(editableSpeakerOptions) { option in
                    Button(option.title) {
                        speakerAssignmentSegmentID = nil
                        Task { await assignSpeaker(segmentID: bubble.id, speaker: option.speaker) }
                    }
                }
                Button("取消", role: .cancel) { speakerAssignmentSegmentID = nil }
            } message: {
                Text("仅显示已识别的单人说话人。")
            }
            .id(bubble.id)

            if showTimestamp {
                Text(transcriptOffset(bubble.offsetMilliseconds))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Speakers & Client Management View

    private var speakersManagementView: some View {
        let bindings = displayedBindings
        let participants = displayedManualParticipants
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text("本场参会人与声纹")
                    .font(.headline)

                Spacer()

                Button {
                    isParticipantPickerPresented = true
                } label: {
                    Label("添加参会人", systemImage: "person.badge.plus")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.borderless)
                .disabled(transcript == nil || !currentRecording.isMeeting)
                .accessibilityHint("记录未发言或未被识别的参会人")
            }

            Text("可手工补充未发言或未识别的参会人。确认或关联已有客户会绑定声纹；完成后长按已识别发言人可重新选择。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if bindings.isEmpty && participants.isEmpty {
                Text("暂无参会人。可手工添加，已识别的发言人也会在此列出。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 20)
            } else {
                VStack(spacing: 12) {
                    ForEach(bindings, id: \.temporaryLabel) { binding in
                        speakerCard(binding: binding)
                    }
                    ForEach(participants) { participant in
                        participantCard(participant)
                    }
                }
            }
        }
    }

    private func participantCard(_ participant: TranscriptDocumentV1.Participant) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color(uiColor: .tertiarySystemBackground))
                    .frame(width: 40, height: 40)
                Image(systemName: "person.crop.circle")
                    .font(.title3)
                    .foregroundStyle(.primary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(participant.name)
                    .font(.headline)
                if !participant.displaySubtitle.isEmpty {
                    Text(participant.displaySubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("已参会 · 暂无发言声纹")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func speakerCard(binding: MeetingSpeakerBinding) -> some View {
        let matchedClient = model.client(forVoiceprintID: binding.state.identityID ?? UUID())
        let hasEmbeddings = !binding.candidateEmbeddings.isEmpty
        let isResolved = binding.state.isConfirmed || !(binding.meetingAlias?.isEmpty ?? true)

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color(uiColor: .tertiarySystemBackground))
                        .frame(width: 40, height: 40)
                    Image(systemName: binding.state.isConfirmed ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                        .font(.title3)
                        .foregroundStyle(binding.state.isConfirmed ? .green : .primary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(binding.chipText)
                            .font(.headline)

                        if let client = matchedClient {
                            Text("已关联: \(client.name)")
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.12))
                                .foregroundStyle(.blue)
                                .clipShape(Capsule())
                        } else if binding.state.isConfirmed {
                            Text("已确认档案")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.12))
                                .foregroundStyle(.green)
                                .clipShape(Capsule())
                        } else if isResolved {
                            Text("本场已归属 · 未绑定声纹")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(uiColor: .tertiarySystemBackground))
                                .foregroundStyle(.secondary)
                                .clipShape(Capsule())
                        } else if binding.state.isSuspected {
                            Text("疑似匹配")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.12))
                                .foregroundStyle(.orange)
                                .clipShape(Capsule())
                        }
                    }

                    Text(hasEmbeddings ? "包含 \(binding.candidateEmbeddings.count) 个可用声纹特征" : "暂未提取到有效声纹向量")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            if !isResolved {
                HStack(spacing: 8) {
                    if binding.state.isSuspected {
                        Button {
                            let name = binding.state.linkedDisplayName ?? binding.chipText
                            Task { await applySpeakerAction(.confirm(name: name), temporaryLabel: binding.temporaryLabel) }
                        } label: {
                            Label("确定", systemImage: "checkmark")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                    }

                    Button {
                        selectedSpeakerForClientBinding = binding
                    } label: {
                        Label("关联客户…", systemImage: "link")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)

                    Button {
                        speakerToRename = binding
                        newSpeakerName = binding.chipText.replacingOccurrences(of: SpeakerIdentityLabeling.suspectedPrefix, with: "")
                        isRenameAlertPresented = true
                    } label: {
                        Label("重命名", systemImage: "pencil")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)

                    if binding.state.isSuspected {
                        Button(role: .destructive) {
                            Task { await applySpeakerAction(.deny, temporaryLabel: binding.temporaryLabel) }
                        } label: {
                            Text("否认匹配")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .contextMenu {
            if isResolved {
                Button {
                    selectedSpeakerForClientBinding = binding
                } label: {
                    Label("重新选择客户…", systemImage: "arrow.triangle.2.circlepath")
                }
                Button {
                    speakerToRename = binding
                    newSpeakerName = binding.chipText.replacingOccurrences(of: SpeakerIdentityLabeling.suspectedPrefix, with: "")
                    isRenameAlertPresented = true
                } label: {
                    Label("修改显示名称", systemImage: "pencil")
                }
            }
        }
    }

    // MARK: - Technical Details View

    private var technicalDetailsView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("录音元数据")
                .font(.headline)

            VStack(spacing: 0) {
                detailRow(label: "录制时间", value: currentRecording.startedAt.standardDateTimeString)
                Divider()
                detailRow(label: "录音时长", value: durationText)
                Divider()
                detailRow(label: "录音语言", value: transcript?.language.isEmpty == false ? (transcript?.language ?? "自动") : "自动")
                Divider()
                detailRow(label: "录音地点", value: currentRecording.locationName ?? "未记录")
                Divider()
                detailRow(label: "录音格式", value: "16kHz 16-bit 单声道 AAC")
                Divider()
                detailRow(label: "存储占用", value: "\(chunks.count) 个分片")
                Divider()
                detailRow(label: "唯一标识", value: recordingID.uuidString)
            }
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))

            relatedFilesSection

            Button(role: .destructive) {
                isDeleteConfirmationPresented = true
            } label: {
                Label("删除录音", systemImage: "trash")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .padding(.top, 8)
            .confirmationDialog(
                "确定删除此录音？",
                isPresented: $isDeleteConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("删除录音与文稿", role: .destructive) {
                    Task {
                        await model.deleteRecording(id: recordingID)
                        dismiss()
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("删除后将无法恢复该录音文件及其关联的转写文稿。")
            }
        }
    }

    private var relatedFilesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("相关文件")
                    .font(.headline)
                Spacer()
                Button {
                    isAttachmentPickerPresented = true
                } label: {
                    Label("添加文件", systemImage: "paperclip")
                        .font(.subheadline.weight(.medium))
                }
                .disabled(isAddingAttachments)
            }

            if isAddingAttachments {
                ProgressView("正在复制到本录音…")
                    .font(.caption)
            } else if attachments.isEmpty {
                Text("暂无相关文件。可添加会议通知、议程、文档或图片。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(attachments) { attachment in
                        attachmentRow(attachment)
                        if attachment.id != attachments.last?.id { Divider() }
                    }
                }
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }

            if let attachmentError {
                Text(attachmentError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func attachmentRow(_ attachment: RecordingAttachment) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "doc")
                .foregroundStyle(.secondary)
                .frame(width: 24)
            Button {
                Task { previewAttachmentURL = await model.recordingAttachmentURL(attachment) }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(attachment.originalFilename)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text("\(ByteCountFormatter.string(fromByteCount: attachment.fileSize, countStyle: .file)) · \(attachment.addedAt.standardTimeString)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Menu {
                ShareLink(item: model.repository.rootURL.appendingPathComponent(attachment.relativePath)) {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
                Button(role: .destructive) {
                    attachmentPendingDeletion = attachment
                } label: {
                    Label("移除", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("管理 \(attachment.originalFilename)")
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Helpers & Data Binding

    private var currentRecording: Recording {
        model.recordings.first(where: { $0.id == recordingID })
            ?? Recording(id: recordingID, startedAt: .distantPast, state: .failed)
    }

    private var playableChunks: [AudioChunk] {
        chunks.filter {
            $0.state == .closed &&
                FileManager.default.fileExists(
                    atPath: model.repository.rootURL.appendingPathComponent($0.relativePath).path
                )
        }
    }

    private var hasPlayableAudio: Bool {
        if let importedAsset {
            return importedAsset.audioRemovedAt == nil &&
                FileManager.default.fileExists(
                    atPath: model.repository.rootURL.appendingPathComponent(importedAsset.relativePath).path
                )
        }
        return !playableChunks.isEmpty
    }

    private var displayTitle: String {
        if let title = transcript?.title, !title.isEmpty { return title }
        if let title = currentRecording.title, !title.isEmpty { return title }
        if currentRecording.origin == .importedAudio {
            return currentRecording.sourceFilename.map {
                ($0 as NSString).deletingPathExtension
            } ?? "导入音频"
        }
        return currentRecording.isMeeting ? "未命名会议" : "未命名录音"
    }

    private var documentPlaceholder: String {
        switch progress?.processing {
        case .queued, .processing:
            return "正在生成本地转写文稿…"
        case .speakerFinalization:
            return "逐字稿已完成，正在整理说话人。"
        case .deferredUntilForeground:
            return "转写待回到前台后继续。"
        case .lockedPendingPurchase:
            return "音频已保存，转写等待解锁。"
        case .needsAttention:
            return "转写处理需要注意，可点击下方重试。"
        default:
            return "这条录音尚无可读取的本地文稿。"
        }
    }

    private typealias SentenceBubble = RecordingDetailPlaybackPresentation.SentenceBubble
    private typealias SpeakerBubbleGroup = RecordingDetailPlaybackPresentation.SpeakerBubbleGroup
    private typealias TranscriptPresentationRow = RecordingDetailPlaybackPresentation.TimedRow

    private func transcriptSentenceBubbles(for transcript: TranscriptDocumentV1) -> [SentenceBubble] {
        let mapped = transcript.segments.compactMap { segment -> SentenceBubble? in
            let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return SentenceBubble(
                id: segment.id,
                offsetMilliseconds: segment.offsetMilliseconds,
                endMilliseconds: RecordingDetailPlaybackPresentation.milliseconds(fromSamples: segment.endSample),
                speaker: speakerLabel(for: segment, in: transcript),
                text: trimmed,
                isManuallyEdited: segment.isManuallyEdited
            )
        }
        return RecordingDetailPlaybackPresentation.normalizingBubbleEndTimes(mapped)
    }

    private func transcriptPresentationRows(for transcript: TranscriptDocumentV1) -> [TranscriptPresentationRow] {
        transcriptSentenceBubbles(for: transcript).map(\.asTimedRow)
    }

    private func filterableSpeakerLabels(from bubbles: [SentenceBubble]) -> [String] {
        RecordingDetailPlaybackPresentation.legendSpeakers(from: bubbles.map(\.speaker))
            .filter { $0 != "说话人不确定" && $0 != "多人对话" && $0 != "多人会话" }
    }

    private var editableSpeakerOptions: [SpeakerAssignmentOption] {
        guard let transcript else { return [] }
        return transcript.editableSpeakerLabels.map { speaker in
            let title = speakerBindings.first(where: {
                $0.temporaryLabel == speaker || $0.chipText == speaker || $0.state.linkedDisplayName == speaker
            })?.chipText ?? speaker
            return SpeakerAssignmentOption(speaker: speaker, title: title)
        }
    }

    private func isSpeakerAssignmentAvailable(for segmentID: UUID) -> Bool {
        guard !editableSpeakerOptions.isEmpty,
              let transcript,
              let segment = transcript.segments.first(where: { $0.id == segmentID }) else {
            return false
        }
        guard let attribution = transcript.speakerTurn(for: segment)?.attribution else { return false }
        return attribution == .single || attribution == .unknown
    }

    private func resolvedSpeakerName(_ temporaryLabel: String?, in transcript: TranscriptDocumentV1) -> String? {
        guard let temporaryLabel, !temporaryLabel.isEmpty else { return nil }
        if let binding = speakerBindings.first(where: {
            $0.temporaryLabel == temporaryLabel || $0.chipText == temporaryLabel || $0.state.linkedDisplayName == temporaryLabel
        }) {
            return binding.chipText
        }
        return temporaryLabel
    }

    private func speakerLabel(for segment: TranscriptDocumentV1.Segment, in transcript: TranscriptDocumentV1) -> String? {
        guard let turn = transcript.speakerTurn(for: segment) else { return nil }
        switch turn.attribution {
        case .multiple:
            return "多人对话"
        case .unknown:
            return "说话人不确定"
        case .single:
            guard let speaker = turn.speaker else { return nil }
            if let binding = speakerBindings.first(where: {
                $0.temporaryLabel == speaker || $0.chipText == speaker || $0.state.linkedDisplayName == speaker
            }) {
                return binding.chipText
            }
            return speaker
        }
    }

    private var displayedBindings: [MeetingSpeakerBinding] {
        if !speakerBindings.isEmpty { return speakerBindings }
        guard let transcript else { return [] }
        return transcript.speakers.map {
            MeetingSpeakerBinding(temporaryLabel: $0, state: .unknown)
        }
    }

    private var displayedManualParticipants: [TranscriptDocumentV1.Participant] {
        guard let transcript else { return [] }
        return transcript.participants.filter { participant in
            !displayedBindings.contains { binding in
                if let clientID = participant.clientID,
                   let voiceprintID = model.client(id: clientID)?.voiceprintIdentityID,
                   binding.state.identityID == voiceprintID {
                    return true
                }
                return binding.chipText.compare(
                    participant.name,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) == .orderedSame
            }
        }
    }

    private func transcriptOffset(_ milliseconds: Int) -> String {
        let minutes = milliseconds / 60_000
        let seconds = milliseconds / 1_000 % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private enum SpeakerAction {
        case confirm(name: String)
        case deny
        case rename(name: String)
    }

    private func applySpeakerAction(_ action: SpeakerAction, temporaryLabel: String) async {
        do {
            let result: (TranscriptDocumentV1?, [MeetingSpeakerBinding])
            switch action {
            case let .confirm(name):
                result = try await model.confirmSpeakerIdentity(
                    recordingID: recordingID,
                    temporaryLabel: temporaryLabel,
                    displayName: name
                )
            case .deny:
                result = try await model.denySpeakerIdentity(
                    recordingID: recordingID,
                    temporaryLabel: temporaryLabel
                )
            case let .rename(name):
                result = try await model.renameSpeakerIdentity(
                    recordingID: recordingID,
                    temporaryLabel: temporaryLabel,
                    displayName: name
                )
            }
            if let document = result.0 {
                transcript = document
            }
            speakerBindings = result.1
        } catch {
            // best-effort speaker update
        }
    }

    private func assignSpeaker(segmentID: UUID, speaker: String) async {
        do {
            transcript = try await model.assignSpeaker(
                recordingID: recordingID,
                segmentID: segmentID,
                speaker: speaker
            )
        } catch {
            transcriptError = "修改此句说话人失败：\(error.localizedDescription)"
        }
    }

    private func bindSpeakerToClient(binding: MeetingSpeakerBinding, client: ClientProfile) async {
        do {
            let result = try await model.confirmSpeakerIdentity(
                recordingID: recordingID,
                temporaryLabel: binding.temporaryLabel,
                displayName: client.name
            )
            if let voiceprintID = result.1.first(where: { $0.temporaryLabel == binding.temporaryLabel })?.state.identityID {
                await model.linkClientVoiceprint(clientID: client.id, voiceprintID: voiceprintID)
            }
            transcript = result.0
            speakerBindings = result.1
        } catch {
            transcriptError = "关联客户失败：\(error.localizedDescription)"
        }
        selectedSpeakerForClientBinding = nil
    }

    private func addMeetingParticipant(name: String) async {
        do {
            transcript = try await model.addMeetingParticipant(
                recordingID: recordingID,
                name: name
            )
        } catch {
            transcriptError = "添加参会人失败：\(error.localizedDescription)"
        }
    }

    private func addMeetingParticipant(client: ClientProfile) async {
        do {
            transcript = try await model.addMeetingParticipant(
                recordingID: recordingID,
                client: client
            )
        } catch {
            transcriptError = "添加参会人失败：\(error.localizedDescription)"
        }
    }

    private func createClientAndBindSpeaker(client: ClientProfile, binding: MeetingSpeakerBinding) async {
        do {
            let result = try await model.createClientAndConfirmSpeakerIdentity(
                recordingID: recordingID,
                temporaryLabel: binding.temporaryLabel,
                client: client
            )
            transcript = result.0
            speakerBindings = result.1
        } catch {
            transcriptError = "新建客户失败：\(error.localizedDescription)"
        }
        isNewClientSheetPresented = false
        speakerForNewClient = nil
    }

    private func addAttachments(from urls: [URL]) async {
        isAddingAttachments = true
        defer { isAddingAttachments = false }
        do {
            _ = try await model.addRecordingAttachments(from: urls, recordingID: recordingID)
            attachments = try await model.recordingAttachments(recordingID: recordingID)
            attachmentError = nil
        } catch {
            attachments = (try? await model.recordingAttachments(recordingID: recordingID)) ?? attachments
            attachmentError = "添加文件失败：\(error.localizedDescription)"
        }
    }

    private func removeAttachment(_ attachment: RecordingAttachment) async {
        do {
            try await model.removeRecordingAttachment(attachment)
            attachments = try await model.recordingAttachments(recordingID: recordingID)
            attachmentPendingDeletion = nil
            attachmentError = nil
        } catch {
            attachmentError = "移除文件失败：\(error.localizedDescription)"
        }
    }

    private func loadDetail() async {
        do {
            chunks = try await model.repository.chunks(recordingID: recordingID)
                .sorted { $0.startSample < $1.startSample }
            importedAsset = try await model.importedAudioAsset(recordingID: recordingID)
            processingRanges = try await model.processingRanges(recordingID: recordingID)
            progress = try await model.presentationProgress(for: recordingID)
            jobs = (try? await model.repository.jobs(recordingID: recordingID)) ?? []
            attachments = (try? await model.recordingAttachments(recordingID: recordingID)) ?? []

            let currentPlayableChunks = playableChunks
            let currentChunkIDs = currentPlayableChunks.map(\.id)
            if let importedAsset {
                let url = model.repository.rootURL.appendingPathComponent(importedAsset.relativePath)
                if loadedAssetURL != url {
                    loadedAssetURL = url
                    timelinePlayer.load(assetURL: url, durationSeconds: importedAsset.durationSeconds)
                }
            } else if loadedPlayableChunkIDs != currentChunkIDs {
                loadedPlayableChunkIDs = currentChunkIDs
                timelinePlayer.load(chunks: currentPlayableChunks, rootURL: model.repository.rootURL)
            }
            loadError = nil
        } catch {
            loadError = "无法读取录音详情：\(error.localizedDescription)"
            return
        }

        do {
            transcript = try await model.transcript(recordingID: recordingID)
            speakerBindings = (try? await model.speakerBindings(recordingID: recordingID)) ?? []
            transcriptError = nil
        } catch {
            transcript = nil
            transcriptError = "文稿无法读取：\(error.localizedDescription)"
        }
    }

    private func scrollToSearchHit(using proxy: ScrollViewProxy) {
        guard !didAutoScrollToHit else { return }
        guard contentTab == .transcript else { return }
        let target = resolvedScrollTarget
        guard let target else { return }
        didAutoScrollToHit = true
        DispatchQueue.main.async {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                proxy.scrollTo(target, anchor: .center)
            }
        }
    }

    private func scrollToActiveSegment(using proxy: ScrollViewProxy) {
        guard timelinePlayer.isPlaying else { return }
        guard contentTab == .transcript else { return }
        guard let transcript else { return }
        let bubbles = transcriptSentenceBubbles(for: transcript)
        guard let target = RecordingDetailPlaybackPresentation.currentBubbleID(at: timelinePlayer.currentTime, bubbles: bubbles) else { return }
        guard lastScrolledActiveSegmentID != target else { return }
        lastScrolledActiveSegmentID = target
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            proxy.scrollTo(target, anchor: .center)
        }
    }

    private var resolvedScrollTarget: UUID? {
        if let scrollToSegmentID { return scrollToSegmentID }
        let query = highlightQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !query.isEmpty, let transcript else { return nil }
        return transcript.segments.first {
            $0.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }?.id
    }
}

/// Adds a meeting attendee without implying speech or creating a voiceprint.
struct MeetingParticipantPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: RecordingCoreModel
    let existingClientIDs: Set<UUID>
    var onAddName: (String) -> Void
    var onSelectClient: (ClientProfile) -> Void

    @State private var name = ""
    @State private var search = ""

    private var filteredClients: [ClientProfile] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return model.clients }
        return model.clients.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.organization.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("参会人姓名", text: $name)
                        .textContentType(.name)
                    Button {
                        onAddName(name.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    } label: {
                        Label("仅添加到本场会议", systemImage: "person.badge.plus")
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text("本场参会人")
                } footer: {
                    Text("只记录出席事实，不会生成声纹或将其标记为已发言。")
                }

                Section("从客户档案添加") {
                    if filteredClients.isEmpty {
                        Text("未找到客户档案")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(filteredClients) { client in
                            let isAdded = existingClientIDs.contains(client.id)
                            Button {
                                onSelectClient(client)
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(client.name)
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(.primary)
                                        if !client.displaySubtitle.isEmpty {
                                            Text(client.displaySubtitle)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if isAdded {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .disabled(isAdded)
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "搜索客户姓名…")
            .navigationTitle("添加参会人")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Sheet to pick an existing Client Profile to bind to a speaker, or create
/// a new global client linked to a fresh voiceprint from this speaker.
struct SpeakerClientPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: RecordingCoreModel
    let binding: MeetingSpeakerBinding
    var onSelectClient: (ClientProfile) -> Void
    var onCreateNew: () -> Void

    @State private var search = ""

    private var filteredClients: [ClientProfile] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return model.clients }
        return model.clients.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.organization.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        dismiss()
                        onCreateNew()
                    } label: {
                        Label("新建客户档案…", systemImage: "person.badge.plus")
                            .font(.body.weight(.medium))
                    }
                } footer: {
                    Text("新建客户会建立当前说话人的声纹，并加入全局档案。")
                }

                Section("选择已有客户") {
                    if filteredClients.isEmpty {
                        Text("未找到客户档案")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(filteredClients) { client in
                            Button {
                                onSelectClient(client)
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(client.name)
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(.primary)
                                        if !client.displaySubtitle.isEmpty {
                                            Text(client.displaySubtitle)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if client.hasVoiceprint {
                                        Image(systemName: "waveform.badge.checkmark")
                                            .foregroundStyle(.green)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "搜索客户姓名…")
            .navigationTitle("关联客户档案")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Sheet to edit recording metadata (title, tags, location) independently from transcript.
struct EditRecordingMetadataSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: RecordingCoreModel
    let recordingID: UUID
    let initialTitle: String
    let initialTags: [String]
    let initialLocation: String?

    @State private var titleInput: String = ""
    @State private var tagsInput: String = ""
    @State private var locationInput: String = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(
        model: RecordingCoreModel,
        recordingID: UUID,
        initialTitle: String,
        initialTags: [String],
        initialLocation: String? = nil
    ) {
        self.model = model
        self.recordingID = recordingID
        self.initialTitle = initialTitle
        self.initialTags = initialTags
        self.initialLocation = initialLocation
        _titleInput = State(initialValue: initialTitle)
        _tagsInput = State(initialValue: initialTags.joined(separator: ", "))
        _locationInput = State(initialValue: initialLocation ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("录音标题") {
                    TextField("输入标题", text: $titleInput)
                }

                Section("录音地点") {
                    TextField("输入录音发生的地址或地点（可选）", text: $locationInput)
                    if !locationInput.isEmpty {
                        Button("清空地点") {
                            locationInput = ""
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Section("标签") {
                    TextField("标签（多个标签用逗号分隔）", text: $tagsInput)
                    Text("例如：周会, 客户沟通, 项目评审")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("编辑录音信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task {
                            isSaving = true
                            defer { isSaving = false }
                            let tags = tagsInput
                                .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == ";" || $0 == " " })
                                .map(String.init)
                            do {
                                try await model.saveRecordingMetadata(
                                    recordingID: recordingID,
                                    title: titleInput,
                                    tags: tags,
                                    locationName: locationInput
                                )
                                dismiss()
                            } catch {
                                errorMessage = "保存失败：\(error.localizedDescription)"
                            }
                        }
                    }
                    .disabled(isSaving)
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Sheet to edit single segment transcript with manual edit confirmation.
struct EditSegmentTextSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: RecordingCoreModel
    let recordingID: UUID
    let row: RecordingDetailPlaybackPresentation.TimedRow
    let onSaved: () async -> Void

    @State private var textInput: String = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(
        model: RecordingCoreModel,
        recordingID: UUID,
        row: RecordingDetailPlaybackPresentation.TimedRow,
        onSaved: @escaping () async -> Void
    ) {
        self.model = model
        self.recordingID = recordingID
        self.row = row
        self.onSaved = onSaved
        _textInput = State(initialValue: row.text)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    if let speaker = row.speaker, !speaker.isEmpty {
                        Text(speaker)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                    Text("+\(formatOffset(row.offsetMilliseconds))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    if row.isManuallyEdited {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark.seal.fill")
                            Text("已校对")
                        }
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.blue)
                    }
                }
                .padding(.horizontal, 4)

                VStack(alignment: .leading, spacing: 6) {
                    Text("逐字稿内容（人工编辑后将永久锁定防覆盖）")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextEditor(text: $textInput)
                        .font(.body)
                        .padding(8)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                        .frame(minHeight: 140)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Spacer()
            }
            .padding(20)
            .navigationTitle("编辑逐字稿段落")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存校对") {
                        Task {
                            isSaving = true
                            defer { isSaving = false }
                            do {
                                _ = try await model.saveSingleSegmentText(
                                    recordingID: recordingID,
                                    segmentID: row.id,
                                    text: textInput
                                )
                                await onSaved()
                                dismiss()
                            } catch {
                                errorMessage = "保存失败：\(error.localizedDescription)"
                            }
                        }
                    }
                    .disabled(isSaving)
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func formatOffset(_ ms: Int) -> String {
        let totalSeconds = ms / 1_000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
