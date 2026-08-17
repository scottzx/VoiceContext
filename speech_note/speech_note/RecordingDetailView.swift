import SwiftUI

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
    @State private var speakerBindings: [MeetingSpeakerBinding] = []
    @State private var loadError: String?
    @State private var transcriptError: String?
    @State private var saveError: String?
    @State private var isEditing = false
    @State private var draftTitle = ""
    @State private var draftTagsText = ""
    @State private var draftSegmentTexts: [UUID: String] = [:]
    @State private var isSaving = false
    @State private var contentTab: DetailContentTab = .transcript
    @StateObject private var timelinePlayer = RecordingAudioTimelinePlayer()

    // Speaker to Client binding state
    @State private var selectedSpeakerForClientBinding: MeetingSpeakerBinding? = nil
    @State private var isNewClientSheetPresented = false
    @State private var speakerForNewClient: MeetingSpeakerBinding? = nil
    @State private var isCopiedToastPresented = false
    @State private var isExportSheetPresented = false

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

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headerCard
                    audioPlayerCard

                    if isEditing {
                        editorSection
                    } else {
                        contentTabsPicker
                        switch contentTab {
                        case .transcript:
                            transcriptDocumentView
                        case .speakers:
                            speakersManagementView
                        case .details:
                            technicalDetailsView
                        }
                    }

                    if let saveError {
                        Label(saveError, systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("detail-save-error")
                    }
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
                    HStack(spacing: 12) {
                        Button {
                            isExportSheetPresented = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .disabled(transcript == nil)
                        .accessibilityLabel("导出与分享")

                        if transcript != nil {
                            Button(isEditing ? "完成" : "编辑") {
                                if isEditing {
                                    Task { await saveEdits() }
                                } else {
                                    beginEditing()
                                }
                            }
                            .fontWeight(isEditing ? .semibold : .regular)
                            .disabled(isSaving)
                            .accessibilityIdentifier("edit-transcript")
                        }
                    }
                }
            }
            .sheet(isPresented: $isExportSheetPresented) {
                NavigationStack {
                    ExportDocumentsDestination(model: model, recordingID: recordingID)
                }
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
            .safeAreaInset(edge: .top, spacing: 0) {
                if model.showsSessionChrome {
                    RecordingBar(model: model, reduceMotion: reduceMotion)
                }
            }
            .overlay(alignment: .bottom) {
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
            .task(id: recordingID) {
                while !Task.isCancelled {
                    if !isEditing {
                        await loadDetail()
                    }
                    let processing = progress?.processing
                    let shouldKeepUpdating: Bool = {
                        switch processing {
                        case .queued, .processing, .deferredUntilForeground, .lockedPendingPurchase:
                            return true
                        case .idle:
                            return progress?.capture == .recording
                                || progress?.capture == .paused
                                || progress?.capture == .interrupted
                                || progress?.capture == .stopping
                        case .needsAttention, .complete, .none:
                            return false
                        }
                    }()
                    guard shouldKeepUpdating else { break }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            .onDisappear {
                timelinePlayer.stop()
            }
        }
    }

    // MARK: - Header Card

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(displayTitle)
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)
                .accessibilityIdentifier("detail-title")

            // Meta tags row
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                    Text(currentRecording.startedAt.formatted(date: .abbreviated, time: .shortened))
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
        let capture = progress?.capture ?? currentRecording.persistedCaptureState

        let (title, icon, color): (String, String, Color) = {
            if capture == .recording {
                return ("录制中", "circle.fill", .red)
            }
            switch processing {
            case .processing, .queued:
                return ("转写中", "waveform", .orange)
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
        currentRecording.endedAt.map {
            RecordingStatusStyle.formatDuration($0.timeIntervalSince(currentRecording.startedAt))
        } ?? "录制中"
    }

    // MARK: - Audio Player Card

    @ViewBuilder
    private var audioPlayerCard: some View {
        VStack(spacing: 12) {
            if !hasPlayableAudio {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.slash")
                        .foregroundStyle(.secondary)
                    Text(transcript?.audio.availableOnThisDevice == false
                         ? "音频已在设备上清理，逐字稿仍可完整浏览"
                         : "音频暂不可用")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            } else {
                VStack(spacing: 8) {
                    // Timeline Scrubber
                    Slider(
                        value: Binding(
                            get: { timelinePlayer.currentTime },
                            set: { timelinePlayer.seek(to: $0) }
                        ),
                        in: 0...max(timelinePlayer.duration, 0.01)
                    )
                    .tint(.red)
                    .accessibilityLabel("音频时间轴")

                    // Timestamps
                    HStack {
                        Text(RecordingStatusStyle.formatDuration(timelinePlayer.currentTime))
                        Spacer()
                        Text("-\(RecordingStatusStyle.formatDuration(max(0, timelinePlayer.duration - timelinePlayer.currentTime)))")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                    // Control Buttons
                    HStack(spacing: 32) {
                        // Skip back 15s
                        Button {
                            timelinePlayer.seek(by: -15)
                        } label: {
                            Image(systemName: "gobackward.15")
                                .font(.title3)
                                .foregroundStyle(.primary)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("快退 15 秒")

                        // Play / Pause prominent round button
                        Button {
                            timelinePlayer.togglePlayback()
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color.primary)
                                    .frame(width: 56, height: 56)
                                Image(systemName: timelinePlayer.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.title2)
                                    .foregroundStyle(Color(uiColor: .systemBackground))
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(timelinePlayer.isPlaying ? "暂停" : "播放")

                        // Skip forward 15s
                        Button {
                            timelinePlayer.seek(by: 15)
                        } label: {
                            Image(systemName: "goforward.15")
                                .font(.title3)
                                .foregroundStyle(.primary)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("快进 15 秒")

                        // Playback Speed
                        Menu {
                            ForEach([Float(0.75), 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                                Button("\(rate, specifier: "%.2g")×") {
                                    timelinePlayer.setRate(rate)
                                }
                            }
                        } label: {
                            Text("\(timelinePlayer.playbackRate, specifier: "%.2g")×")
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color(uiColor: .secondarySystemBackground))
                                .clipShape(Capsule())
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)

                    if let playbackError = timelinePlayer.playbackError {
                        Label(playbackError, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(16)
                .background(Color(uiColor: .secondarySystemBackground).opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
            }
        }
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
        let rows = transcript.map { transcriptPresentationRows(for: $0) } ?? []
        let roster = RecordingDetailPlaybackPresentation.legendSpeakers(from: rows.map(\.speaker))
        let activeID = RecordingDetailPlaybackPresentation.currentRowID(at: timelinePlayer.currentTime, rows: rows)
        let activeSpeaker = rows.first(where: { $0.id == activeID })?.speaker

        return VStack(alignment: .leading, spacing: 14) {
            if roster.count >= 2 {
                speakerLegend(roster: roster, activeSpeaker: activeSpeaker)
            }

            if let transcript {
                if rows.isEmpty {
                    Text(documentPlaceholder)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 24)
                } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(rows) { row in
                            transcriptDialogueRow(
                                row,
                                roster: roster,
                                isCurrent: row.id == activeID
                            )
                        }
                    }
                }
            } else {
                Text(documentPlaceholder)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 24)
            }

            if let transcriptError {
                Label(transcriptError, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func speakerLegend(roster: [String], activeSpeaker: String?) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(roster, id: \.self) { speaker in
                    let color = RecordingDetailPlaybackPresentation.color(for: speaker, roster: roster)
                    let isActive = activeSpeaker == speaker
                    HStack(spacing: 6) {
                        Circle()
                            .fill(color)
                            .frame(width: 8, height: 8)
                        Text(speaker)
                            .font(.caption.weight(isActive ? .semibold : .regular))
                            .foregroundStyle(isActive ? .primary : .secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(isActive ? color.opacity(0.18) : Color(uiColor: .secondarySystemBackground))
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(isActive ? color : .clear, lineWidth: 1))
                }
            }
        }
    }

    @ViewBuilder
    private func transcriptDialogueRow(
        _ row: TranscriptPresentationRow,
        roster: [String],
        isCurrent: Bool
    ) -> some View {
        let speakerColor = row.speaker != nil ? RecordingDetailPlaybackPresentation.color(for: row.speaker!, roster: roster) : Color.secondary

        Button {
            timelinePlayer.seek(to: row.startTime)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if let speaker = row.speaker, !speaker.isEmpty {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(speakerColor)
                                .frame(width: 6, height: 6)
                            Text(speaker)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(speakerColor)
                        }
                    }

                    Text("+\(transcriptOffset(row.offsetMilliseconds))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Spacer()

                    if isCurrent {
                        HStack(spacing: 4) {
                            Image(systemName: "waveform")
                            Text("播放中")
                        }
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.red)
                    }
                }

                Text(row.text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isCurrent ? Color.primary.opacity(0.06) : Color(uiColor: .secondarySystemBackground).opacity(0.4))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isCurrent ? Color.red.opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .id(row.id)
        .contextMenu {
            Button {
                UIPasteboard.general.string = row.text
                withAnimation { isCopiedToastPresented = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation { isCopiedToastPresented = false }
                }
            } label: {
                Label("复制文本", systemImage: "doc.on.doc")
            }
            Button {
                timelinePlayer.seek(to: row.startTime)
            } label: {
                Label("从此开始播放", systemImage: "play.circle")
            }
        }
    }

    // MARK: - Speakers & Client Management View

    private var speakersManagementView: some View {
        let bindings = displayedBindings
        return VStack(alignment: .leading, spacing: 14) {
            Text("本场参会人与声纹")
                .font(.headline)

            Text("点击参会人可一键绑定到「客户档案」或保存为新客户。绑定后，在后续录音中将自动识别说话人。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if bindings.isEmpty {
                Text("暂无说话人标签。离线聚类完成后将在此列出本场发言人。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 20)
            } else {
                VStack(spacing: 12) {
                    ForEach(bindings, id: \.temporaryLabel) { binding in
                        speakerCard(binding: binding)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func speakerCard(binding: MeetingSpeakerBinding) -> some View {
        let matchedClient = model.client(forVoiceprintID: binding.state.identityID ?? UUID())
        let hasEmbeddings = !binding.candidateEmbeddings.isEmpty

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

            // Action Buttons
            HStack(spacing: 8) {
                Button {
                    selectedSpeakerForClientBinding = binding
                } label: {
                    Label("关联客户", systemImage: "link")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)

                Button {
                    speakerForNewClient = binding
                    isNewClientSheetPresented = true
                } label: {
                    Label("建为新客户", systemImage: "person.badge.plus")
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
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Technical Details View

    private var technicalDetailsView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("录音元数据")
                .font(.headline)

            VStack(spacing: 0) {
                detailRow(label: "录制时间", value: currentRecording.startedAt.formatted(date: .abbreviated, time: .standard))
                Divider()
                detailRow(label: "录制类型", value: currentRecording.isMeeting ? "会议模式" : (currentRecording.origin == .importedAudio ? "导入音频" : "个人录音"))
                Divider()
                detailRow(label: "语言模式", value: (transcript?.languageMode ?? currentRecording.languageMode).shortLabel)
                Divider()
                detailRow(label: "文稿版本", value: transcript.map { "版本 \($0.revision)" } ?? "未生成")
                Divider()
                detailRow(label: "分片数量", value: "\(chunks.count) 个 AAC 分片")
                if let asset = importedAsset {
                    Divider()
                    detailRow(label: "来源文件名", value: asset.sourceFilename)
                }
            }
            .padding(.horizontal, 14)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))

            if progress?.canRetry == true || currentRecording.state == .failed {
                Button {
                    Task { await model.retryTranscription(recordingID: recordingID) }
                } label: {
                    Label("重新进行本地转写", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(.primary)
                .padding(.top, 8)
            }
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 10)
    }

    // MARK: - Editor Section

    private var editorSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("编辑文稿")
                .font(.headline)
            TextField("标题", text: $draftTitle)
                .textFieldStyle(.roundedBorder)
            TextField("标签（用逗号分隔）", text: $draftTagsText)
                .textFieldStyle(.roundedBorder)

            if let transcript {
                ForEach(transcript.segments) { segment in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("+\(transcriptOffset(segment.offsetMilliseconds))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        TextField(
                            "逐字稿",
                            text: Binding(
                                get: { draftSegmentTexts[segment.id] ?? segment.text },
                                set: { draftSegmentTexts[segment.id] = $0 }
                            ),
                            axis: .vertical
                        )
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...6)
                    }
                }
            }

            HStack {
                Button("取消") {
                    isEditing = false
                    saveError = nil
                }
                .buttonStyle(.bordered)
                Button(isSaving ? "保存中…" : "保存") {
                    Task { await saveEdits() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.primary)
                .disabled(isSaving)
            }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
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

    private typealias TranscriptPresentationRow = RecordingDetailPlaybackPresentation.TimedRow

    private func transcriptPresentationRows(for transcript: TranscriptDocumentV1) -> [TranscriptPresentationRow] {
        let turns = transcript.speakerTurns.sorted {
            if $0.startSample != $1.startSample { return $0.startSample < $1.startSample }
            return ($0.speaker ?? "") < ($1.speaker ?? "")
        }
        guard !turns.isEmpty else {
            let mapped = transcript.segments.map {
                TranscriptPresentationRow(
                    id: $0.id,
                    offsetMilliseconds: $0.offsetMilliseconds,
                    endMilliseconds: RecordingDetailPlaybackPresentation.milliseconds(fromSamples: $0.endSample),
                    speaker: speakerLabel(for: $0, in: transcript),
                    text: $0.text
                )
            }
            return RecordingDetailPlaybackPresentation.normalizingEndTimes(mapped)
        }

        var assigned = Set<UUID>()
        var rows: [TranscriptPresentationRow] = []
        for turn in turns {
            let owned = transcript.segments.filter { segment in
                let mid = (segment.startSample + segment.endSample) / 2
                return turn.startSample <= mid && mid < max(turn.endSample, turn.startSample + 1)
            }
            for segment in owned { assigned.insert(segment.id) }
            let texts = owned.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !texts.isEmpty else { continue }
            let offsetMs = owned.map(\.offsetMilliseconds).min() ?? Int((Double(turn.startSample) / 16.0).rounded())
            let endMs = owned.map { RecordingDetailPlaybackPresentation.milliseconds(fromSamples: $0.endSample) }.max()
                ?? RecordingDetailPlaybackPresentation.milliseconds(fromSamples: turn.endSample)
            rows.append(
                TranscriptPresentationRow(
                    id: owned[0].id,
                    offsetMilliseconds: offsetMs,
                    endMilliseconds: endMs,
                    speaker: resolvedSpeakerName(turn.speaker, in: transcript),
                    text: texts.joined(separator: " ")
                )
            )
        }
        for segment in transcript.segments where !assigned.contains(segment.id) {
            let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            rows.append(
                TranscriptPresentationRow(
                    id: segment.id,
                    offsetMilliseconds: segment.offsetMilliseconds,
                    endMilliseconds: RecordingDetailPlaybackPresentation.milliseconds(fromSamples: segment.endSample),
                    speaker: speakerLabel(for: segment, in: transcript),
                    text: trimmed
                )
            )
        }
        return RecordingDetailPlaybackPresentation.normalizingEndTimes(rows)
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
        let mid = (segment.startSample + segment.endSample) / 2
        if let turn = transcript.speakerTurns.first(where: {
            $0.startSample <= mid && mid < max($0.endSample, $0.startSample + 1)
        }), let speaker = turn.speaker {
            if let binding = speakerBindings.first(where: {
                $0.temporaryLabel == speaker || $0.chipText == speaker || $0.state.linkedDisplayName == speaker
            }) {
                return binding.chipText
            }
            return speaker
        }
        return nil
    }

    private var displayedBindings: [MeetingSpeakerBinding] {
        if !speakerBindings.isEmpty { return speakerBindings }
        guard let transcript else { return [] }
        return transcript.speakers.map {
            MeetingSpeakerBinding(temporaryLabel: $0, state: .unknown)
        }
    }

    private func transcriptOffset(_ milliseconds: Int) -> String {
        let minutes = milliseconds / 60_000
        let seconds = milliseconds / 1_000 % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func beginEditing() {
        guard let transcript else { return }
        draftTitle = transcript.title ?? currentRecording.title ?? ""
        draftTagsText = transcript.tags.joined(separator: ", ")
        draftSegmentTexts = Dictionary(uniqueKeysWithValues: transcript.segments.map { ($0.id, $0.text) })
        saveError = nil
        isEditing = true
    }

    private func saveEdits() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        let tags = draftTagsText
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == ";" })
            .map(String.init)
        do {
            let saved = try await model.saveTranscriptEdits(
                recordingID: recordingID,
                title: draftTitle,
                tags: tags,
                segmentTexts: draftSegmentTexts
            )
            transcript = saved
            isEditing = false
            saveError = nil
            await loadDetail()
        } catch {
            saveError = "保存失败：\(error.localizedDescription)"
        }
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
            saveError = nil
        } catch {
            saveError = "说话人更新失败：\(error.localizedDescription)"
        }
    }

    private func bindSpeakerToClient(binding: MeetingSpeakerBinding, client: ClientProfile) async {
        await applySpeakerAction(.confirm(name: client.name), temporaryLabel: binding.temporaryLabel)
        if let voiceprintID = binding.state.identityID {
            await model.linkClientVoiceprint(clientID: client.id, voiceprintID: voiceprintID)
        }
        selectedSpeakerForClientBinding = nil
    }

    private func createClientAndBindSpeaker(client: ClientProfile, binding: MeetingSpeakerBinding) async {
        await applySpeakerAction(.confirm(name: client.name), temporaryLabel: binding.temporaryLabel)
        var newClient = client
        if let voiceprintID = binding.state.identityID {
            newClient.voiceprintIdentityID = voiceprintID
        }
        await model.upsertClient(newClient)
        isNewClientSheetPresented = false
        speakerForNewClient = nil
    }

    private func loadDetail() async {
        do {
            chunks = try await model.repository.chunks(recordingID: recordingID)
                .sorted { $0.startSample < $1.startSample }
            importedAsset = try await model.importedAudioAsset(recordingID: recordingID)
            processingRanges = try await model.processingRanges(recordingID: recordingID)
            progress = try await model.presentationProgress(for: recordingID)
            if let importedAsset {
                let url = model.repository.rootURL.appendingPathComponent(importedAsset.relativePath)
                timelinePlayer.load(assetURL: url, durationSeconds: importedAsset.durationSeconds)
            } else {
                timelinePlayer.load(chunks: playableChunks, rootURL: model.repository.rootURL)
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
        guard contentTab == .transcript, !isEditing else { return }
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
        guard contentTab == .transcript, !isEditing else { return }
        guard let transcript else { return }
        let rows = transcriptPresentationRows(for: transcript)
        guard let target = RecordingDetailPlaybackPresentation.currentRowID(at: timelinePlayer.currentTime, rows: rows) else { return }
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

/// Sheet to pick an existing Client Profile to bind to a speaker.
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
