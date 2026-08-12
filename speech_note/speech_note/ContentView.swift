import AVFoundation
import Combine
import SwiftUI

private enum RecordingTimeFilter: String, CaseIterable, Identifiable {
    case all
    case today
    case lastSevenDays
    case thisMonth

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部时间"
        case .today: "今天"
        case .lastSevenDays: "最近 7 天"
        case .thisMonth: "本月"
        }
    }

    func includes(_ date: Date, calendar: Calendar = .current) -> Bool {
        let now = Date()
        switch self {
        case .all:
            return true
        case .today:
            return calendar.isDate(date, inSameDayAs: now)
        case .lastSevenDays:
            guard let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) else {
                return false
            }
            return date >= start
        case .thisMonth:
            return calendar.isDate(date, equalTo: now, toGranularity: .month)
        }
    }
}

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
        items = chunks.compactMap { chunk in
            let url = rootURL.appendingPathComponent(chunk.relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let sampleCount = max(0, chunk.endSample - chunk.startSample)
            return Item(
                url: url,
                duration: Double(sampleCount) / AACSegmentRecorder.targetSampleRate
            )
        }
        duration = items.reduce(0) { $0 + $1.duration }
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
        if currentTime >= duration { seek(to: 0) }
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
            updateCurrentTime()
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
        currentTime = 0
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
        var remaining = target
        currentIndex = 0
        while currentIndex < items.count - 1, remaining >= items[currentIndex].duration {
            remaining -= items[currentIndex].duration
            currentIndex += 1
        }
        currentItemOffset = min(remaining, items[currentIndex].duration)
        currentTime = target
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
        guard !items.isEmpty else { return }
        currentItemOffset = player?.currentTime ?? currentItemOffset
        let completedDuration = items.prefix(currentIndex).reduce(0) { $0 + $1.duration }
        currentTime = min(duration, completedDuration + currentItemOffset)
    }
}

/// Playback refused to start without throwing; surfaced as a readable state
/// rather than being treated as a completed timeline.
private enum PlaybackFailure: Error {
    case couldNotStart
}

/// The product-facing recording workspace. Its state is deliberately read
/// from `RecordingCoreModel`, which in turn refreshes its snapshots from the
/// journal/SQLite repository; this view never creates a parallel UI state
/// machine for capture.
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: RecordingCoreModel
    @State private var modelError: String?
    @State private var timeFilter: RecordingTimeFilter = .all
    @State private var isStartSheetPresented = false
    @State private var isSettingsPresented = false
    @State private var isRecordingScreenPresented = false
    private let isRecordingDetailFixtureEnabled: Bool

    init() {
        isRecordingDetailFixtureEnabled = ProcessInfo.processInfo.arguments.contains("-uiTestingSeedRecordingDetail")
        if isRecordingDetailFixtureEnabled {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let fixtureRoot = documents.appendingPathComponent("VoiceContext-uiTesting", isDirectory: true)
            try? FileManager.default.removeItem(at: fixtureRoot)
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
            } else {
                workspace
            }
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(to: ScenePhaseLike(phase))
        }
        .onChange(of: model.captureIsActive) { _, isActive in
            isRecordingScreenPresented = isActive
        }
        .task {
            if isRecordingDetailFixtureEnabled {
                await installRecordingDetailFixture()
            }
            await model.recoverOnLaunch()
        }
    }

    private var workspace: some View {
        NavigationStack {
            recordsScreen
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("我的", systemImage: "person.circle") {
                            isSettingsPresented = true
                        }
                        .accessibilityLabel("打开我的")
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    if model.captureIsActive {
                        RecordingBar(model: model, reduceMotion: reduceMotion)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    captureDock
                }
        }
        .sheet(isPresented: $isStartSheetPresented) {
            StartRecordingSheet(model: model)
        }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsScreen(model: model, reduceMotion: reduceMotion)
        }
        .fullScreenCover(isPresented: $isRecordingScreenPresented) {
            RecordingScreen(
                model: model,
                reduceMotion: reduceMotion,
                isPresented: $isRecordingScreenPresented
            )
        }
    }

    private var recordsScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Spacer()
                    Picker("时间筛选", selection: $timeFilter) {
                        ForEach(RecordingTimeFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityLabel("时间筛选")
                }
                .padding(.horizontal, 20)

                if recordingGroups.isEmpty {
                    ContentUnavailableView {
                        Label("还没有记录", systemImage: "waveform")
                    } description: {
                        Text("开始录音，保存一个念头或一次对话。")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                } else {
                    ForEach(recordingGroups) { group in
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(group.date.formatted(date: .complete, time: .omitted))
                                    .font(.headline)
                                Spacer()
                                Text("\(group.recordings.count) 条记录")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                            .padding(.bottom, 4)

                            ForEach(group.recordings) { recording in
                                NavigationLink {
                                    RecordingDetailScreen(model: model, recordingID: recording.id)
                                } label: {
                                    RecordingRow(recording: recording)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("recording-row-\(recording.id.uuidString)")
                                Divider().padding(.leading, 20)
                            }
                        }
                    }
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
        .background(Color(uiColor: .systemBackground))
    }

    private var captureDock: some View {
        VStack(spacing: 6) {
            Button {
                isStartSheetPresented = true
            } label: {
                ZStack {
                    Circle()
                        .fill(.red)
                        .frame(width: 64, height: 64)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.white)
                }
                .frame(width: 72, height: 72)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("开始录音")
            .accessibilityHint("可选择性填写标题和会议字段")

            Text("开始录音")
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var recordingGroups: [RecordingDayGroup] {
        let filtered = model.recordings
            .filter { timeFilter.includes($0.startedAt) }
            .sorted { $0.startedAt > $1.startedAt }
        let grouped = Dictionary(grouping: filtered) {
            Calendar.current.startOfDay(for: $0.startedAt)
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

/// A deliberately small, truthful detail surface for the recordings that the
/// capture pipeline already persists. Full transcript editing belongs to #28,
/// but a completed or failed recording must never be a dead-end in the list.
private struct RecordingDetailScreen: View {
    let model: RecordingCoreModel
    let recordingID: UUID

    @State private var chunks: [AudioChunk] = []
    @State private var transcriptionJob: RecordingJob?
    @State private var transcript: TranscriptDocumentV1?
    @State private var loadError: String?
    @State private var transcriptError: String?
    @StateObject private var timelinePlayer = RecordingAudioTimelinePlayer()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                status
                audio
                document
                processing
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(currentRecording.isMeeting ? "会议详情" : "录音详情")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: currentRecording.updatedAt) {
            await loadDetail()
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
        VStack(alignment: .leading, spacing: 8) {
            Text(currentRecording.title?.isEmpty == false
                 ? currentRecording.title!
                 : (currentRecording.isMeeting ? "未命名会议" : "未命名录音"))
                .font(.title3.weight(.semibold))

            Text(metadata)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)

            Label(statusText, systemImage: statusSymbol)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(statusColor)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(currentRecording.title ?? "未命名录音")，\(metadata)，\(statusText)")
    }

    @ViewBuilder
    private var audio: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("音频")
                .font(.headline)

            if playableChunks.isEmpty {
                Label("音频暂不可用", systemImage: "waveform.slash")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
                        Text(RecordingRow.duration(timelinePlayer.currentTime))
                        Spacer()
                        Text(RecordingRow.duration(timelinePlayer.duration))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                    HStack(spacing: 22) {
                        Button { timelinePlayer.seek(by: -15) } label: {
                            Image(systemName: "gobackward.15")
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        Button { timelinePlayer.togglePlayback() } label: {
                            Image(systemName: timelinePlayer.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title2)
                                .frame(width: 52, height: 52)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.primary)
                        Button { timelinePlayer.seek(by: 15) } label: {
                            Image(systemName: "goforward.15")
                                .frame(minWidth: 44, minHeight: 44)
                        }
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
                ForEach(transcript.segments) { segment in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("+\(transcriptOffset(segment.offsetMilliseconds))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(segment.text)
                            .font(.body)
                    }
                    .padding(.vertical, 8)
                }
            } else {
                Text(currentRecording.state == .processing
                     ? "正在生成本地文稿。"
                     : "这条录音尚无可读取的本地文稿。")
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

    @ViewBuilder
    private var processing: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("处理状态")
                .font(.headline)

            if let transcriptionJob {
                LabeledContent("转写") {
                    Text(jobStateText(transcriptionJob.state))
                        .foregroundStyle(jobColor(transcriptionJob.state))
                }
                LabeledContent("尝试次数") {
                    Text("\(transcriptionJob.attemptCount)")
                        .monospacedDigit()
                }
                if let message = transcriptionJob.lastError, !message.isEmpty {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
            } else {
                Text("尚未创建转写任务。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if currentRecording.state == .failed {
                Button("重新处理") {
                    Task { await model.retryTranscription(recordingID: recordingID) }
                }
                .buttonStyle(.bordered)
                .tint(.primary)
                .accessibilityHint("重新提交本地转写任务")
            }

            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
        }
    }

    private var metadata: String {
        let time = currentRecording.startedAt.formatted(date: .abbreviated, time: .shortened)
        let duration = currentRecording.endedAt.map {
            RecordingRow.duration($0.timeIntervalSince(currentRecording.startedAt))
        } ?? "录制中"
        return "\(time) · \(duration)"
    }

    private var statusText: String {
        switch currentRecording.state {
        case .recording: "正在录音"
        case .paused: "已暂停"
        case .interrupted: "录音中断，需要注意"
        case .stopping: "正在停止"
        case .processing: "正在处理"
        case .complete: "已完成"
        case .failed: "需要注意"
        }
    }

    private var statusSymbol: String {
        switch currentRecording.state {
        case .recording: "record.circle.fill"
        case .paused: "pause.circle.fill"
        case .interrupted, .failed: "exclamationmark.triangle.fill"
        case .stopping: "stop.circle"
        case .processing: "hourglass"
        case .complete: "checkmark.circle"
        }
    }

    private var statusColor: Color {
        switch currentRecording.state {
        case .recording, .failed: .red
        case .paused, .interrupted, .processing: .orange
        case .stopping, .complete: .secondary
        }
    }

    private func jobStateText(_ state: RecordingJobState) -> String {
        switch state {
        case .pending: "等待处理"
        case .running: "正在处理"
        case .completed: "已完成"
        case .failed: "处理失败"
        }
    }

    private func jobColor(_ state: RecordingJobState) -> Color {
        switch state {
        case .pending, .running: .orange
        case .completed: .secondary
        case .failed: .red
        }
    }

    private func loadDetail() async {
        do {
            async let storedChunks = model.repository.chunks(recordingID: recordingID)
            async let jobs = model.repository.jobs(recordingID: recordingID)
            chunks = try await storedChunks.sorted { $0.startSample < $1.startSample }
            transcriptionJob = try await jobs.last(where: { $0.kind == .transcription })
            timelinePlayer.load(chunks: playableChunks, rootURL: model.repository.rootURL)
            loadError = nil
        } catch {
            loadError = "无法读取录音详情：\(error.localizedDescription)"
            return
        }

        do {
            transcript = try await model.transcript(recordingID: recordingID)
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

private struct CalendarStrip: View {
    @Binding var selectedDate: Date
    let recordings: [Recording]

    private let calendar = Calendar.current

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(days, id: \.self) { day in
                    let isSelected = calendar.isDate(day, inSameDayAs: selectedDate)
                    let count = recordings.filter { calendar.isDate($0.startedAt, inSameDayAs: day) }.count
                    Button {
                        selectedDate = day
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
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private var days: [Date] {
        let today = calendar.startOfDay(for: Date())
        return (-3...3).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
    }
}

private struct RecordingRow: View {
    let recording: Recording

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: statusSymbol)
                .font(.title3)
                .foregroundStyle(statusColor)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(recording.title?.isEmpty == false ? recording.title! : defaultTitle)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(metadata)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                if recording.state != .complete {
                    Label(statusText, systemImage: statusSymbol)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(recording.title?.isEmpty == false ? recording.title! : defaultTitle)，\(metadata)，\(statusText)")
    }

    private var defaultTitle: String {
        recording.isMeeting ? "未命名会议" : "未命名录音"
    }

    private var metadata: String {
        let time = recording.startedAt.formatted(date: .omitted, time: .shortened)
        let duration: String
        if let endedAt = recording.endedAt {
            duration = Self.duration(endedAt.timeIntervalSince(recording.startedAt))
        } else {
            duration = "录制中"
        }
        return "\(time) · \(duration)"
    }

    private var statusText: String {
        switch recording.state {
        case .recording: "正在录音"
        case .paused: "已暂停"
        case .interrupted: "录音中断，需要注意"
        case .stopping: "正在停止"
        case .processing: "正在处理"
        case .complete: "已完成"
        case .failed: "需要注意"
        }
    }

    private var statusSymbol: String {
        switch recording.state {
        case .recording: "record.circle.fill"
        case .paused: "pause.circle.fill"
        case .interrupted, .failed: "exclamationmark.triangle.fill"
        case .stopping: "stop.circle"
        case .processing: "hourglass"
        case .complete: "checkmark.circle"
        }
    }

    private var statusColor: Color {
        switch recording.state {
        case .recording, .failed: .red
        case .paused, .interrupted, .processing: .orange
        case .stopping, .complete: .secondary
        }
    }

    fileprivate static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return seconds >= 3_600
            ? String(format: "%d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct StartRecordingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var isMeeting = false
    let model: RecordingCoreModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        Task {
                            await model.start(title: title, isMeeting: isMeeting)
                            if model.captureIsActive { dismiss() }
                        }
                    } label: {
                        Label("直接开始录音", systemImage: "mic.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.primary)
                    .accessibilityHint("不填写以下字段也可以开始")
                } footer: {
                    Text("标题和会议字段都可以在录音结束后补充。")
                }

                Section("可选信息") {
                    TextField("标题", text: $title)
                        .textInputAutocapitalization(.sentences)
                    Toggle("这是一次会议", isOn: $isMeeting)
                }

                if let notice = model.notice {
                    Section {
                        Label(notice, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("开始记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct RecordingScreen: View {
    let model: RecordingCoreModel
    let reduceMotion: Bool
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer(minLength: 28)
                status
                timer
                level
                Spacer()
                controls
                if let notice = model.notice {
                    Label(notice, systemImage: "info.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            .navigationTitle("录音中")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("最小化") { isPresented = false }
                }
            }
            .background(Color(uiColor: .systemBackground))
        }
        .interactiveDismissDisabled()
        .onChange(of: model.captureIsActive) { _, active in
            if !active { isPresented = false }
        }
    }

    private var status: some View {
        Label(statusText, systemImage: statusSymbol)
            .font(.headline)
            .foregroundStyle(statusColor)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("录音状态：\(statusText)")
    }

    private var timer: some View {
        Text(elapsedText)
            .font(.system(size: 48, weight: .regular, design: .rounded).monospacedDigit())
            .contentTransition(.numericText())
            .padding(.top, 12)
            .accessibilityLabel("已录制时长")
            .accessibilityValue(elapsedAccessibility)
    }

    @ViewBuilder
    private var level: some View {
        if let inputLevel = model.inputLevel {
            GeometryReader { proxy in
                Capsule()
                    .fill(Color(uiColor: .systemFill))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(.red)
                            .frame(width: max(2, proxy.size.width * CGFloat(inputLevel)))
                    }
            }
            .frame(height: 6)
            .padding(.top, 24)
            .accessibilityLabel("麦克风输入电平")
            .accessibilityValue("\(Int(inputLevel * 100))%")
        } else {
            Text(levelFallback)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 24)
        }
    }

    private var controls: some View {
        HStack(spacing: 20) {
            Button {
                Task { await model.pauseOrResume() }
            } label: {
                Label(pauseTitle, systemImage: pauseSymbol)
                    .frame(minWidth: 88, minHeight: 52)
            }
            .buttonStyle(.bordered)
            .disabled(model.presentation == .interrupted)
            .accessibilityHint(model.presentation == .interrupted ? "系统中断期间不可暂停" : "")

            Button(role: .destructive) {
                Task { await model.stop() }
            } label: {
                Label("停止", systemImage: "stop.fill")
                    .frame(minWidth: 88, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .accessibilityLabel("停止录音")
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: model.presentation)
    }

    private var statusText: String {
        switch model.presentation {
        case .recording: "正在录音"
        case .paused: "已暂停"
        case .interrupted: "已中断，等待恢复"
        case .stopping: "正在安全停止"
        case .processing: "正在处理"
        case .idle, .failed: "录音已结束"
        }
    }

    private var statusSymbol: String {
        switch model.presentation {
        case .recording: "record.circle.fill"
        case .paused: "pause.circle.fill"
        case .interrupted: "exclamationmark.triangle.fill"
        case .stopping: "stop.circle"
        case .processing: "hourglass"
        case .idle, .failed: "checkmark.circle"
        }
    }

    private var statusColor: Color {
        switch model.presentation {
        case .recording: .red
        case .paused, .interrupted, .processing: .orange
        case .stopping, .idle: .secondary
        case .failed: .red
        }
    }

    private var elapsedText: String {
        guard let recording = model.snapshot.recording else { return "00:00" }
        let ending = recording.endedAt ?? Date()
        return RecordingRow.duration(ending.timeIntervalSince(recording.startedAt))
    }

    private var elapsedAccessibility: String {
        guard let recording = model.snapshot.recording else { return "尚未开始录音" }
        let seconds = max(0, Int((recording.endedAt ?? Date()).timeIntervalSince(recording.startedAt)))
        return "\(seconds / 60) 分 \(seconds % 60) 秒"
    }

    private var pauseTitle: String { model.presentation == .paused ? "继续" : "暂停" }
    private var pauseSymbol: String { model.presentation == .paused ? "play.fill" : "pause.fill" }
    private var levelFallback: String {
        model.presentation == .interrupted ? "系统中断；恢复后会继续显示输入电平。" : "正在等待麦克风输入。"
    }
}

private struct RecordingBar: View {
    let model: RecordingCoreModel
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "record.circle.fill")
                .foregroundStyle(.red)
                .symbolEffect(.pulse, isActive: !reduceMotion && model.presentation == .recording)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(barTitle)
                    .font(.subheadline.weight(.semibold))
                Text("\(elapsedText) · \(backlogText)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(barTitle)，已录制 \(elapsedAccessibility)，\(backlogText)")

            Spacer(minLength: 4)

            Button(role: .destructive) {
                Task { await model.stop() }
            } label: {
                Label("停止", systemImage: "stop.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: 54, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .accessibilityLabel("停止录音")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var barTitle: String {
        switch model.presentation {
        case .recording: "正在录音"
        case .paused: "录音已暂停"
        case .interrupted: "录音已中断"
        default: "录音状态变化中"
        }
    }

    private var backlogText: String {
        model.isInBackground ? "录音继续，转写待前台处理" : "转写将在停止后处理"
    }

    private var elapsedText: String {
        guard let recording = model.snapshot.recording else { return "00:00" }
        return RecordingRow.duration(Date().timeIntervalSince(recording.startedAt))
    }

    private var elapsedAccessibility: String {
        guard let recording = model.snapshot.recording else { return "0 分 0 秒" }
        let seconds = max(0, Int(Date().timeIntervalSince(recording.startedAt)))
        return "\(seconds / 60) 分 \(seconds % 60) 秒"
    }
}

private struct SettingsScreen: View {
    @Environment(\.dismiss) private var dismiss
    let model: RecordingCoreModel
    let reduceMotion: Bool

    var body: some View {
        NavigationStack {
            List {
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
            .safeAreaInset(edge: .top, spacing: 0) {
                if model.captureIsActive {
                    RecordingBar(model: model, reduceMotion: reduceMotion)
                }
            }
        }
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
        case .recording: "正在录音"
        case .paused: "已暂停"
        case .interrupted: "已中断"
        case .stopping: "正在停止"
        case .processing: "正在处理"
        case let .failed(message): "失败：\(message)"
        }
    }

    private var validationStateSymbol: String {
        switch model.presentation {
        case .idle: "circle.dashed"
        case .recording: "record.circle.fill"
        case .paused: "pause.circle.fill"
        case .interrupted: "exclamationmark.triangle.fill"
        case .stopping: "stop.circle"
        case .processing: "hourglass"
        case .failed: "xmark.octagon.fill"
        }
    }

    private var validationStateColor: Color {
        switch model.presentation {
        case .recording, .failed: .red
        case .paused, .interrupted, .processing: .orange
        case .idle, .stopping: .secondary
        }
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
