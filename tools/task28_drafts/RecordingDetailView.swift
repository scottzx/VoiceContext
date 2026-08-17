import SwiftUI

/// Meeting / recording detail with basic transcript correction (#28).
/// Extracted from ContentView so capture chrome and list stay manageable.
struct RecordingDetailScreen: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: RecordingCoreModel
    let recordingID: UUID

    @State private var chunks: [AudioChunk] = []
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
    @StateObject private var timelinePlayer = RecordingAudioTimelinePlayer()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                status
                audio
                if isEditing {
                    editor
                } else {
                    document
                    speakers
                }
                exportActions
                processing
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
        }
        .background(Color(uiColor: .systemBackground))
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
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var audio: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("音频")
                .font(.headline)

            if playableChunks.isEmpty {
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

                    HStack {
                        Text(RecordingStatusStyle.formatDuration(timelinePlayer.currentTime))
                        Spacer()
                        Text(RecordingStatusStyle.formatDuration(timelinePlayer.duration))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                    HStack(spacing: 22) {
                        Button { timelinePlayer.seek(by: -15) } label: {
                            Image(systemName: "gobackward.15")
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel("快退 15 秒")
                        Button { timelinePlayer.togglePlayback() } label: {
                            Image(systemName: timelinePlayer.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title2)
                                .frame(width: 52, height: 52)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.primary)
                        .accessibilityLabel(timelinePlayer.isPlaying ? "暂停" : "播放")
                        Button { timelinePlayer.seek(by: 15) } label: {
                            Image(systemName: "goforward.15")
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel("快进 15 秒")
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

    private var document: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("文稿")
                .font(.headline)
            if let transcript {
                Text("逐字稿 · revision \(transcript.revision)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("transcript-revision")
                if !transcript.tags.isEmpty {
                    Text("标签：\(transcript.tags.joined(separator: "、"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("transcript-tags")
                }
                ForEach(transcript.segments) { segment in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("+\(transcriptOffset(segment.offsetMilliseconds))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            if let speaker = speakerLabel(for: segment, in: transcript) {
                                Text(speaker)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(segment.text)
                            .font(.body)
                    }
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "偏移 \(transcriptOffset(segment.offsetMilliseconds))，\(speakerLabel(for: segment, in: transcript) ?? "")，\(segment.text)"
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
                .accessibilityIdentifier("save-transcript")
            }
        }
    }

    @ViewBuilder
    private var speakers: some View {
        let bindings = displayedBindings
        if !bindings.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("说话人")
                    .font(.headline)
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
                }
            }
        }
    }

    @ViewBuilder
    private var exportActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("导出")
                .font(.headline)
            Text("Markdown / JSON 保存在本机 Documents，可经分享或“存储到文件”打开。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            NavigationLink {
                ExportDocumentsDestination(model: model, recordingID: recordingID)
            } label: {
                Text(transcript == nil ? "导出尚不可用" : "导出 Markdown / JSON")
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
        return currentRecording.isMeeting ? "未命名会议" : "未命名录音"
    }

    private var documentPlaceholder: String {
        switch progress?.processing {
        case .queued, .processing:
            "正在生成本地文稿。"
        case .deferredUntilForeground:
            "转写待回到前台后继续。"
        case .lockedPendingPurchase:
            "转写待解锁后继续。"
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
        return "\(time) · \(duration)"
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
            progress = try await model.presentationProgress(for: recordingID)
            timelinePlayer.load(chunks: playableChunks, rootURL: model.repository.rootURL)
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
