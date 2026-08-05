import SwiftUI

/// Validation surface for the 0.1.0 recording core. It is deliberately a
/// single, quiet screen: the person starts and stops the microphone, and the
/// evidence the device checklist needs (state, chunks, gaps, recovery,
/// integrity) is read straight from the journal/SQLite-backed model rather
/// than from the old direct-recorder spike.
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: RecordingCoreModel
    @State private var modelError: String?

    init() {
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
                validationScreen
            }
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(to: ScenePhaseLike(phase))
        }
    }

    private var validationScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                timerBlock
                controls
                evidence
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .background(Color(uiColor: .systemBackground))
        .task {
            await model.recoverOnLaunch()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("录音核心验证")
                .font(.largeTitle.weight(.bold))
            Text("0.1.0 · journal / SQLite / gap 真机链路")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            stateLine
        }
        .padding(.top, 8)
    }

    private var stateLine: some View {
        HStack(spacing: 8) {
            Image(systemName: stateSymbol)
                .foregroundStyle(stateColor)
            Text(stateText)
                .font(.headline)
                .foregroundStyle(stateColor)
            if model.isInBackground {
                Text("后台")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let recording = model.snapshot.recording {
                Text(recording.id.shortID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("录音状态：\(stateText)")
    }

    private var stateSymbol: String {
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

    private var stateColor: Color {
        switch model.presentation {
        case .idle: .secondary
        case .recording: .red
        case .paused: .orange
        case .interrupted: .orange
        case .stopping: .secondary
        case .processing: .orange
        case .failed: .red
        }
    }

    private var stateText: String {
        switch model.presentation {
        case .idle: "未开始"
        case .recording: "正在录音"
        case .paused: "已暂停"
        case .interrupted: "已中断，等待处理"
        case .stopping: "正在停止"
        case .processing: "已停止，处理中"
        case .failed(let message): "失败：\(message)"
        }
    }

    // MARK: - Timer

    private var timerBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(timerText)
                .font(.system(size: 48, weight: .regular, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
                .accessibilityLabel("已录制时长")
                .accessibilityValue(timerAccessibility)
            Text(timerCaption)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            if model.presentation == .recording, let level = model.inputLevel {
                inputLevelBar(level: level)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inputLevelBar(level: Float) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(uiColor: .systemFill))
                Capsule()
                    .fill(.red)
                    .frame(width: max(2, proxy.size.width * CGFloat(level)))
            }
        }
        .frame(height: 4)
        .accessibilityLabel("麦克风输入电平")
    }

    private var timerText: String {
        guard let recording = model.snapshot.recording else { return "--:--" }
        let interval: TimeInterval
        switch recording.state {
        case .recording, .paused:
            interval = Date().timeIntervalSince(recording.startedAt)
        default:
            interval = (recording.endedAt ?? recording.updatedAt).timeIntervalSince(recording.startedAt)
        }
        return Self.clock(max(0, interval))
    }

    private var timerAccessibility: String {
        guard let recording = model.snapshot.recording else { return "尚未开始录音" }
        let seconds = Int(Date().timeIntervalSince(recording.startedAt))
        return "\(seconds / 60) 分 \(seconds % 60) 秒"
    }

    private var timerCaption: String {
        let chunks = model.snapshot.chunks
        let gaps = model.snapshot.gaps
        let lastSample = chunks.last?.endSample ?? 0
        return "chunk \(chunks.count) · gap \(gaps.count) · 样本 \(lastSample.formatted()) · 事件 \(model.snapshot.appliedEventCount)"
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 16) {
            recordButton
            if showsSecondaryControls {
                secondaryControls
            }
            if let notice = model.notice {
                noticeBanner(notice)
            }
        }
    }

    private var showsSecondaryControls: Bool {
        switch model.presentation {
        case .recording, .paused, .interrupted, .processing: true
        default: false
        }
    }

    private var recordButton: some View {
        Button(action: primaryAction) {
            ZStack {
                Circle()
                    .fill(recordButtonFill)
                    .frame(width: 64, height: 64)
                Image(systemName: recordButtonSymbol)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(recordButtonGlyph)
            }
            .frame(width: 72, height: 72)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!primaryActionEnabled)
        .opacity(primaryActionEnabled ? 1 : 0.4)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(primaryAccessibilityLabel)
        .sensoryFeedback(primaryFeedback, trigger: model.presentation)
    }

    private var recordButtonSymbol: String {
        switch model.presentation {
        case .idle, .failed: "mic.fill"
        case .recording, .paused, .interrupted: "stop.fill"
        case .stopping, .processing: "hourglass"
        }
    }

    private var recordButtonFill: Color {
        switch model.presentation {
        case .idle, .failed: .red
        case .recording, .paused, .interrupted: .red
        case .stopping, .processing: Color(.systemGray4)
        }
    }

    private var recordButtonGlyph: Color {
        switch model.presentation {
        case .stopping, .processing: .secondary
        default: .white
        }
    }

    private var primaryActionEnabled: Bool {
        switch model.presentation {
        case .idle, .failed, .recording, .paused, .interrupted: true
        case .stopping, .processing: false
        }
    }

    private var primaryAccessibilityLabel: String {
        switch model.presentation {
        case .idle, .failed: "开始录音"
        case .recording, .paused, .interrupted: "停止录音"
        default: "录音状态切换中"
        }
    }

    private var primaryFeedback: SensoryFeedback {
        switch model.presentation {
        case .recording: .start
        case .interrupted: .warning
        case .failed: .error
        default: .impact(weight: .light)
        }
    }

    private func primaryAction() {
        switch model.presentation {
        case .idle, .failed:
            Task { await model.start() }
        case .recording, .paused, .interrupted:
            Task { await model.stop() }
        case .stopping, .processing:
            break
        }
    }

    private var secondaryControls: some View {
        HStack(spacing: 12) {
            switch model.presentation {
            case .recording, .paused, .interrupted:
                Button(model.presentation == .paused ? "继续" : "暂停") {
                    Task { await model.pauseOrResume() }
                }
                .buttonStyle(.bordered)
                .disabled(model.presentation == .interrupted)

                if model.presentation == .interrupted {
                    Text("中断期间由系统决定是否恢复")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .processing:
                Button("标记处理完成") {
                    Task { await model.markProcessingCompleted() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.primary)
            default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func noticeBanner(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
            Text(notice)
                .font(.subheadline)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Evidence

    private var evidence: some View {
        VStack(alignment: .leading, spacing: 24) {
            evidenceSection("恢复与幂等") {
                recoveryRows
                Button("再次运行恢复（幂等检查）") {
                    Task { await model.runRecoveryAgain() }
                }
                .buttonStyle(.bordered)
                .font(.subheadline)
            }

            evidenceSection("分片 chunk") {
                if model.snapshot.chunks.isEmpty {
                    emptyRow("停止或达到分片边界后出现")
                } else {
                    ForEach(model.snapshot.chunks) { chunk in
                        chunkRow(chunk)
                    }
                }
            }

            evidenceSection("缺口 gap") {
                if model.snapshot.gaps.isEmpty {
                    emptyRow("暂无中断、路由或写入缺口")
                } else {
                    ForEach(model.snapshot.gaps) { gap in
                        gapRow(gap)
                    }
                }
            }

            evidenceSection("完整性与报告") {
                integrityRows
                HStack(spacing: 12) {
                    Button("运行诊断") {
                        Task { await model.runDiagnostics() }
                    }
                    .buttonStyle(.bordered)
                    .font(.subheadline)

                    Button("生成报告") {
                        Task { await model.makeReport() }
                    }
                    .buttonStyle(.bordered)
                    .font(.subheadline)

                    if let url = model.reportURL {
                        ShareLink(item: url) {
                            Text("分享")
                        }
                        .buttonStyle(.bordered)
                        .font(.subheadline)
                    }
                }
            }
        }
    }

    private func evidenceSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content()
        }
    }

    private var recoveryRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.recoveries.isEmpty {
                emptyRow("启动时会读取 journal 并修复索引")
            } else {
                ForEach(Array(model.recoveries.enumerated()), id: \.offset) { _, recovery in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("重放 \(recovery.replayedEventCount) · 恢复 \(recovery.recoveredRecordingIDs.count)")
                            .font(.subheadline.monospacedDigit())
                        if !recovery.recoveredRecordingIDs.isEmpty {
                            Text(recovery.recoveredRecordingIDs.map(\.shortID).joined(separator: "，"))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func chunkRow(_ chunk: AudioChunk) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(chunk.id.shortID)
                    .font(.subheadline.monospaced())
                Spacer()
                Text(chunkStateText(chunk.state))
                    .font(.caption)
                    .foregroundStyle(chunk.state == .closed ? Color.secondary : Color.orange)
            }
            Text("\(chunk.startSample.formatted()) → \(chunk.endSample.formatted()) · \((chunk.endSample - chunk.startSample).formatted()) 样本")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        Divider()
    }

    private func chunkStateText(_ state: AudioChunkState) -> String {
        switch state {
        case .writing: "写入中"
        case .closed: "已关闭"
        case .corrupt: "损坏"
        case .audioRemoved: "音频已清理"
        }
    }

    @ViewBuilder
    private func gapRow(_ gap: RecordingGap) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(gapReasonText(gap.reason))
                    .font(.subheadline)
                Spacer()
                Text(gap.endSample == nil ? "未关闭" : "已关闭")
                    .font(.caption)
                    .foregroundStyle(gap.endSample == nil ? Color.orange : Color.secondary)
            }
            Text("\(gap.startSample.formatted()) → \(gap.endSample.map { $0.formatted() } ?? "…")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        Divider()
    }

    private func gapReasonText(_ reason: RecordingGapReason) -> String {
        switch reason {
        case .systemInterruption: "系统中断（电话/Siri）"
        case .routeChange: "路由变化（蓝牙等）"
        case .writeFailure: "写入背压/失败"
        case .recoveredAfterTermination: "强制终止后恢复"
        }
    }

    private var integrityRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let issues = model.integrityIssues {
                if issues.isEmpty {
                    Label("无重叠、无未解释缺口、音频可读", systemImage: "checkmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                } else {
                    ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                        Label(String(describing: issue), systemImage: "exclamationmark.triangle")
                            .font(.caption.monospaced())
                            .foregroundStyle(.orange)
                    }
                }
            } else {
                emptyRow("运行诊断以核对样本边界与音频可读性")
            }
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.tertiary)
    }

    private func startupFailure(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("录音核心初始化失败")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static func clock(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }
}

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

private extension UUID {
    var shortID: String {
        String(uuidString.prefix(8))
    }
}

#Preview {
    ContentView()
}
