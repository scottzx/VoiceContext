import SwiftUI

/// Meeting / recording detail with basic transcript correction (#28).
/// Extracted from ContentView so capture chrome and list stay manageable.
struct RecordingDetailScreen: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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

    private enum DetailContentTab: String, CaseIterable, Identifiable {
        case transcript
        case speakers

        var id: String { rawValue }

        var title: String {
            switch self {
            case .transcript: "逐字稿"
            case .speakers: "说话人"
            }
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    status
                    audio
                    if isEditing {
                        editor
                    } else {
                        contentTabs
                        switch contentTab {
                        case .transcript:
                            document
                        case .speakers:
                            speakers
                        }
                    }
                    if let saveError {
                        Label(saveError, systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("detail-save-error")
                    }
                    exportActions
                    processing
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
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
                if transcript != nil {
                    Button(isEditing ? "完成" : "编辑") {
                        if isEditing {
                            Task { await saveEdits() }
                        } else {
                            beginEditing()
                        }
                    }
                    .disabled(isSaving)
                    .accessibilityLabel(isEditing ? "完成并保存文稿编辑" : "编辑文稿")
                    .accessibilityHint(isEditing ? "保存标题、标签与逐字稿修改" : "修改标题、标签与逐字稿")
                    .accessibilityIdentifier("edit-transcript")
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.showsSessionChrome {
                RecordingBar(model: model, reduceMotion: reduceMotion)
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
        } // ScrollViewReader
    }


    private func transcriptRowAccessibilityLabel(
        _ row: TranscriptPresentationRow,
        isCurrent: Bool
    ) -> String {
        var parts = ["偏移 \(transcriptOffset(row.offsetMilliseconds))"]
        if let speaker = row.speaker, !speaker.isEmpty {
            parts.append(speaker)
        }
        parts.append(row.text)
        if isCurrent { parts.append("正在播放") }
        return parts.joined(separator: "，")
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
        guard let target = RecordingDetailPlaybackPresentation.currentRowID(
            at: timelinePlayer.currentTime,
            rows: rows
        ) else { return }
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

    private var status: some View {
        let capture = progress?.capture ?? currentRecording.persistedCaptureState
        let processing = progress?.processing ?? .idle
        return VStack(alignment: .leading, spacing: 8) {
            Text(displayTitle)
                .font(.title3.weight(.semibold))
                .accessibilityIdentifier("detail-title")

            Text(metadata)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)

            if let transcript {
                Text(identitySummary(for: transcript))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(identitySummary(for: transcript))
            }

            Label(
                RecordingStatusStyle.captureText(for: capture),
                systemImage: RecordingStatusStyle.captureSymbolName(for: capture)
            )
            .font(.subheadline.weight(.medium))
            .foregroundStyle(RecordingStatusStyle.captureColor(for: capture))
            .accessibilityLabel("录音状态：\(RecordingStatusStyle.captureText(for: capture))")

            Label(
                RecordingStatusStyle.processingText(for: processing),
                systemImage: RecordingStatusStyle.processingSymbolName(for: processing)
            )
            .font(.subheadline.weight(.medium))
            .foregroundStyle(RecordingStatusStyle.processingColor(for: processing))
            .accessibilityLabel("处理状态：\(RecordingStatusStyle.processingText(for: processing))")

            if let progress {
                Text(RecordingStatusStyle.progressDetailText(
                    for: progress,
                    isInBackground: model.isInBackground
                ))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel(
                    RecordingStatusStyle.progressDetailText(
                        for: progress,
                        isInBackground: model.isInBackground
                    )
                )
            }

            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("transcript-save-error")
            }

            if processing == .lockedPendingPurchase, !model.trialEntitlement.isUnlocked {
                VStack(alignment: .leading, spacing: 8) {
                    Text("音频已保存，转写等待解锁。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    NavigationLink {
                        PurchaseUnlockView(trial: model.trialEntitlement)
                    } label: {
                        Text("永久解锁 / 恢复购买")
                    }
                    .accessibilityIdentifier("detail-purchase-unlock")
                }
                .padding(.top, 4)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var audio: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("音频")
                .font(.headline)

            if !hasPlayableAudio {
                Label(
                    transcript?.audio.availableOnThisDevice == false
                        ? "音频已在本机清理，文稿仍可阅读"
                        : "音频暂不可用",
                    systemImage: "waveform.slash"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("audio-unavailable")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Slider(
                        value: Binding(
                            get: { timelinePlayer.currentTime },
                            set: { timelinePlayer.seek(to: $0) }
                        ),
                        in: 0...max(timelinePlayer.duration, 0.01)
                    )
                    .tint(.red)
                    .accessibilityLabel("音频时间轴")
                    .accessibilityValue(
                        "当前 \(RecordingStatusStyle.formatDuration(timelinePlayer.currentTime))，总时长 \(RecordingStatusStyle.formatDuration(timelinePlayer.duration))"
                    )
                    .accessibilityHint("左右调整可定位播放位置")

                    HStack {
                        Text(RecordingStatusStyle.formatDuration(timelinePlayer.currentTime))
                        Spacer()
                        Text(RecordingStatusStyle.formatDuration(timelinePlayer.duration))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                    HStack(spacing: 22) {
                        Button {
                            timelinePlayer.seek(by: -RecordingDetailPlaybackPresentation.skipSeconds)
                        } label: {
                            Image(systemName: "gobackward.10")
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel("快退 10 秒")
                        .accessibilityHint("大约向后跳转 10 秒")
                        .accessibilityIdentifier("skip-back-10")
                        Button { timelinePlayer.togglePlayback() } label: {
                            Image(systemName: timelinePlayer.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title2)
                                .frame(width: 52, height: 52)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.primary)
                        .accessibilityLabel(timelinePlayer.isPlaying ? "暂停" : "播放")
                        .accessibilityIdentifier("playback-toggle")
                        Button {
                            timelinePlayer.seek(by: RecordingDetailPlaybackPresentation.skipSeconds)
                        } label: {
                            Image(systemName: "goforward.10")
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel("快进 10 秒")
                        .accessibilityHint("大约向前跳转 10 秒")
                        .accessibilityIdentifier("skip-forward-10")
                        Menu {
                            ForEach([Float(1), 1.25, 1.5, 2], id: \.self) { rate in
                                Button("\(rate, specifier: "%.2g")×") {
                                    timelinePlayer.setRate(rate)
                                }
                            }
                        } label: {
                            Text("\(timelinePlayer.playbackRate, specifier: "%.2g")×")
                                .font(.subheadline.weight(.medium))
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel("播放倍速")
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .contain)

                    if let playbackError = timelinePlayer.playbackError {
                        Label(playbackError, systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("playback-error")
                    }
                }
            }
        }
    }

    private var contentTabs: some View {
        Picker("详情内容", selection: $contentTab) {
            ForEach(DetailContentTab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("detail-content-tabs")
    }

    private var document: some View {
        let rows = transcript.map { transcriptPresentationRows(for: $0) } ?? []
        let roster = RecordingDetailPlaybackPresentation.legendSpeakers(
            from: rows.map(\.speaker)
        )
        let activeID = RecordingDetailPlaybackPresentation.currentRowID(
            at: timelinePlayer.currentTime,
            rows: rows
        )
        let activeSpeaker = rows.first(where: { $0.id == activeID })?.speaker

        return VStack(alignment: .leading, spacing: 8) {
            Text("逐字稿")
                .font(.headline)
            if let transcript {
                Text("revision \(transcript.revision)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("transcript-revision")
                if !transcript.tags.isEmpty {
                    Text("标签：\(transcript.tags.joined(separator: "、"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("transcript-tags")
                }
                if roster.count >= 2 {
                    speakerLegend(roster: roster, activeSpeaker: activeSpeaker)
                }
                ForEach(rows) { row in
                    transcriptRow(
                        row,
                        roster: roster,
                        isCurrent: row.id == activeID
                    )
                }
            } else {
                Text(documentPlaceholder)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            if let transcriptError {
                Label(transcriptError, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("transcript-read-error")
            }
        }
    }

    private typealias TranscriptPresentationRow = RecordingDetailPlaybackPresentation.TimedRow

    @ViewBuilder
    private func speakerLegend(roster: [String], activeSpeaker: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("说话人")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(roster, id: \.self) { speaker in
                        let color = RecordingDetailPlaybackPresentation.color(
                            for: speaker,
                            roster: roster
                        )
                        let isActive = activeSpeaker == speaker
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(color)
                                .frame(width: 10, height: 14)
                                .accessibilityHidden(true)
                            Text(speaker)
                                .font(.caption.weight(isActive ? .semibold : .regular))
                                .foregroundStyle(isActive ? .primary : .secondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(isActive ? color.opacity(0.16) : Color(uiColor: .secondarySystemBackground))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(isActive ? color.opacity(0.7) : .clear, lineWidth: 1)
                        )
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            isActive ? "当前说话人 \(speaker)" : "说话人 \(speaker)"
                        )
                        .accessibilityAddTraits(isActive ? .isSelected : [])
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("speaker-legend")
        .accessibilityHint("播放时会高亮当前说话人")
    }

    @ViewBuilder
    private func transcriptRow(
        _ row: TranscriptPresentationRow,
        roster: [String],
        isCurrent: Bool
    ) -> some View {
        let speakerColor: Color = {
            guard let speaker = row.speaker, !speaker.isEmpty else { return .secondary }
            return RecordingDetailPlaybackPresentation.color(for: speaker, roster: roster)
        }()

        Button {
            timelinePlayer.seek(to: row.startTime)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(row.speaker == nil ? Color.clear : speakerColor)
                    .frame(width: 3)
                    .padding(.vertical, 2)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("+\(transcriptOffset(row.offsetMilliseconds))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if let speaker = row.speaker, !speaker.isEmpty {
                            Text(speaker)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(speakerColor)
                                .lineLimit(1)
                        }
                        if isCurrent {
                            Text("播放中")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Color.primary.opacity(0.08))
                                )
                                .accessibilityHidden(true)
                        }
                    }
                    Text(row.text)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isCurrent ? Color.primary.opacity(0.06) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isCurrent ? Color.primary.opacity(0.12) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .id(row.id)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(transcriptRowAccessibilityLabel(row, isCurrent: isCurrent))
        .accessibilityHint("轻点跳到该句开始处")
        .accessibilityAddTraits(isCurrent ? .updatesFrequently : [])
        .accessibilityIdentifier(isCurrent ? "active-transcript-segment" : "transcript-segment")
    }

    /// Prefer offline speaker turns when present so the transcript reads as
    /// dialogue with speaker labels. Each ASR segment is assigned once via its
    /// midpoint to avoid duplicating long segments across many short turns.
    private func transcriptPresentationRows(
        for transcript: TranscriptDocumentV1
    ) -> [TranscriptPresentationRow] {
        let turns = transcript.speakerTurns.sorted {
            if $0.startSample != $1.startSample {
                return $0.startSample < $1.startSample
            }
            return ($0.speaker ?? "") < ($1.speaker ?? "")
        }
        guard !turns.isEmpty else {
            let mapped = transcript.segments.map {
                TranscriptPresentationRow(
                    id: $0.id,
                    offsetMilliseconds: $0.offsetMilliseconds,
                    endMilliseconds: RecordingDetailPlaybackPresentation.milliseconds(
                        fromSamples: $0.endSample
                    ),
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
                return turn.startSample <= mid
                    && mid < max(turn.endSample, turn.startSample + 1)
            }
            for segment in owned { assigned.insert(segment.id) }
            let texts = owned
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !texts.isEmpty else { continue }
            let offsetMs = owned.map(\.offsetMilliseconds).min()
                ?? Int((Double(turn.startSample) / 16.0).rounded())
            let endMs = owned.map {
                RecordingDetailPlaybackPresentation.milliseconds(fromSamples: $0.endSample)
            }.max()
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
                    endMilliseconds: RecordingDetailPlaybackPresentation.milliseconds(
                        fromSamples: segment.endSample
                    ),
                    speaker: speakerLabel(for: segment, in: transcript),
                    text: trimmed
                )
            )
        }
        return RecordingDetailPlaybackPresentation.normalizingEndTimes(rows)
    }

    private func resolvedSpeakerName(
        _ temporaryLabel: String?,
        in transcript: TranscriptDocumentV1
    ) -> String? {
        guard let temporaryLabel, !temporaryLabel.isEmpty else { return nil }
        if let binding = speakerBindings.first(where: {
            $0.temporaryLabel == temporaryLabel
                || $0.chipText == temporaryLabel
                || $0.state.linkedDisplayName == temporaryLabel
        }) {
            return binding.chipText
        }
        return temporaryLabel
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("编辑文稿")
                .font(.headline)
            TextField("标题", text: $draftTitle)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("标题")
                .accessibilityIdentifier("edit-title")
            TextField("标签（用逗号分隔）", text: $draftTagsText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("标签")
                .accessibilityIdentifier("edit-tags")
            if let transcript {
                ForEach(transcript.segments) { segment in
                    VStack(alignment: .leading, spacing: 6) {
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
                        .lineLimit(3...8)
                        .accessibilityLabel("偏移 \(transcriptOffset(segment.offsetMilliseconds)) 的文本")
                    }
                }
            }
            Text("保存后会重建 JSON/Markdown，并增加 revision。不含波形级切分。")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                .accessibilityLabel(isSaving ? "正在保存文稿" : "保存文稿")
                .accessibilityHint("保存后会增加 revision 并重建本地导出文件")
                .accessibilityIdentifier("save-transcript")
            }
        }
    }

    @ViewBuilder
    private var speakers: some View {
        let bindings = displayedBindings
        VStack(alignment: .leading, spacing: 12) {
            Text("说话人")
                .font(.headline)
            Text("在此标记本场说话人；有声纹样本后可确认到长期档案。逐字稿页按说话人呈现转写结果。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if bindings.isEmpty {
                Text("暂无说话人标签。转写或离线聚类完成后会出现在这里。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("speakers-empty")
            } else {
                ForEach(Array(bindings.enumerated()), id: \.element.temporaryLabel) { _, binding in
                    SpeakerIdentityConfirmView(
                        binding: binding,
                        onConfirm: { name in
                            Task { await applySpeakerAction(.confirm(name: name), temporaryLabel: binding.temporaryLabel) }
                        },
                        onDeny: {
                            Task { await applySpeakerAction(.deny, temporaryLabel: binding.temporaryLabel) }
                        },
                        onRename: { name in
                            Task { await applySpeakerAction(.rename(name: name), temporaryLabel: binding.temporaryLabel) }
                        }
                    )
                    if binding.temporaryLabel != bindings.last?.temporaryLabel {
                        Divider()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var exportActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("导出")
                .font(.headline)
            Text("导出文本、字幕或分享音频；Markdown / JSON / Codex 在高级导出中。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            NavigationLink {
                ExportDocumentsDestination(model: model, recordingID: recordingID)
            } label: {
                Text(transcript == nil ? "导出尚不可用" : "导出文本 / 字幕 / 音频")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(.primary)
            .disabled(transcript == nil)
            .accessibilityIdentifier("open-export")
        }
    }

    @ViewBuilder
    private var processing: some View {
        let processingState = progress?.processing ?? .idle
        VStack(alignment: .leading, spacing: 8) {
            Text("处理状态")
                .font(.headline)

            Label(
                RecordingStatusStyle.processingText(for: processingState),
                systemImage: RecordingStatusStyle.processingSymbolName(for: processingState)
            )
            .font(.subheadline.weight(.medium))
            .foregroundStyle(RecordingStatusStyle.processingColor(for: processingState))
            .accessibilityLabel("处理状态：\(RecordingStatusStyle.processingText(for: processingState))")

            if let progress {
                if let transcribed = RecordingStatusStyle.transcribedUpToText(progress.transcribedUpTo) {
                    Text(transcribed)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(transcribed)
                }
                if let outstanding = RecordingStatusStyle.outstandingItemsText(progress.outstandingItemCount) {
                    Text(outstanding)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(outstanding)
                }
            }

            if currentRecording.origin == .importedAudio, !processingRanges.isEmpty {
                let completed = processingRanges.filter { $0.state == .completed }.count
                Text("已完成处理范围 \(completed)/\(processingRanges.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("已完成处理范围 \(completed)/\(processingRanges.count)")
            }

            if progress?.canRetry == true || currentRecording.state == .failed {
                Button("重新处理") {
                    Task { await model.retryTranscription(recordingID: recordingID) }
                }
                .buttonStyle(.bordered)
                .tint(.primary)
                .accessibilityHint("重新提交本地转写")
                .accessibilityIdentifier("retry-processing")
            }

            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
        }
    }

    private var displayedBindings: [MeetingSpeakerBinding] {
        if !speakerBindings.isEmpty { return speakerBindings }
        guard let transcript else { return [] }
        return transcript.speakers.map {
            MeetingSpeakerBinding(temporaryLabel: $0, state: .unknown)
        }
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
            "正在生成本地文稿。"
        case .deferredUntilForeground:
            "转写待回到前台后继续。"
        case .lockedPendingPurchase:
            "音频已保存，转写等待解锁。"
        case .needsAttention:
            "文稿处理需要注意，可重试。"
        default:
            "这条录音尚无可读取的本地文稿。"
        }
    }

    private var metadata: String {
        let time = currentRecording.startedAt.formatted(date: .abbreviated, time: .shortened)
        let duration = currentRecording.endedAt.map {
            RecordingStatusStyle.formatDuration($0.timeIntervalSince(currentRecording.startedAt))
        } ?? "录制中"
        let languageLabel = (transcript?.languageMode ?? currentRecording.languageMode).shortLabel
        if currentRecording.origin == .importedAudio {
            let source = currentRecording.sourceFilename ?? "导入音频"
            let completed = processingRanges.filter { $0.state == .completed }.count
            let total = processingRanges.count
            if total > 0 {
                return "\(time) · \(duration) · \(languageLabel) · 导入 · \(source) · 范围 \(completed)/\(total)"
            }
            return "\(time) · \(duration) · \(languageLabel) · 导入 · \(source)"
        }
        return "\(time) · \(duration) · \(languageLabel)"
    }

    private func identitySummary(for transcript: TranscriptDocumentV1) -> String {
        let audioText = transcript.audio.availableOnThisDevice ? "音频可用" : "音频不可用"
        let speakerText: String = {
            if speakerBindings.contains(where: { $0.state.isSuspected }) {
                return "含疑似身份"
            }
            if speakerBindings.contains(where: { $0.state.isConfirmed }) {
                return "含已确认身份"
            }
            if !transcript.speakers.isEmpty {
                return "\(transcript.speakers.count) 位说话人"
            }
            return "无说话人标签"
        }()
        return "revision \(transcript.revision) · \(audioText) · \(speakerText)"
    }

    private func speakerLabel(
        for segment: TranscriptDocumentV1.Segment,
        in transcript: TranscriptDocumentV1
    ) -> String? {
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

    private func transcriptOffset(_ milliseconds: Int) -> String {
        let minutes = milliseconds / 60_000
        let seconds = milliseconds / 1_000 % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
