import Foundation
import Observation
import UIKit

/// App-level model for the 0.1.0 recording-core device validation. Owns the
/// repository, the session coordinator, and the observable evidence the
/// validation screen needs: state, chunk/gap snapshots, recovery results,
/// integrity diagnostics, and the shareable report.
@MainActor
@Observable
final class RecordingCoreModel {
    struct RecoverySummary: Equatable {
        let date: Date
        let replayedEventCount: Int
        let recoveredRecordingIDs: [UUID]
    }

    struct Snapshot: Equatable {
        var recording: Recording?
        var chunks: [AudioChunk] = []
        var gaps: [RecordingGap] = []
        var appliedEventCount = 0
        var schemaVersion = 0
    }

    private(set) var presentation: RecordingSessionCoordinator.PresentationState = .idle
    private(set) var activeRecordingID: UUID?
    private(set) var snapshot = Snapshot()
    private(set) var recordings: [Recording] = []
    private(set) var recoveries: [RecoverySummary] = []
    private(set) var inputLevel: Float?
    private(set) var integrityIssues: [RecordingIntegrityIssue]?
    private(set) var inspectedRecordingID: UUID?
    private(set) var notice: String?
    private(set) var reportURL: URL?
    private(set) var isInBackground = false

    let repository: RecordingRepository
    private let recorder = AACSegmentRecorder()
    private let coordinator: RecordingSessionCoordinator
    private let diagnostics = RecordingDiagnostics()
    private var refreshTask: Task<Void, Never>?

    convenience init() throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try self.init(rootURL: documents.appendingPathComponent("VoiceContext", isDirectory: true))
    }

    init(rootURL: URL) throws {
        repository = try RecordingRepository(rootURL: rootURL)
        coordinator = RecordingSessionCoordinator(repository: repository, capture: recorder)
        coordinator.onStateChanged = { [weak self] state in
            self?.presentationChanged(to: state)
        }
        recorder.onMeteringUpdate = { [weak self] metrics in
            Task { @MainActor [weak self] in
                self?.inputLevel = metrics.displayLevel
            }
        }
    }

    /// Fallback for the error path of the UI: a tmp-backed model that keeps
    /// the screen renderable if the Documents-backed repository fails.
    static func makePlaceholder() -> RecordingCoreModel {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceContext-fallback", isDirectory: true)
        return try! RecordingCoreModel(rootURL: url)
    }

    // MARK: - Session control

    var captureIsActive: Bool {
        switch presentation {
        case .recording, .paused, .interrupted:
            true
        case .idle, .stopping, .processing, .failed:
            false
        }
    }

    func start(title: String? = nil, isMeeting: Bool = false) async {
        notice = nil
        do {
            let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let recordingID = try await coordinator.start(
                isMeeting: isMeeting,
                title: normalizedTitle?.isEmpty == false ? normalizedTitle : nil
            )
            activeRecordingID = recordingID
        } catch {
            notice = "开始失败：\(error.localizedDescription)"
        }
        await refresh()
    }

    func pauseOrResume() async {
        do {
            if presentation == .paused {
                try await coordinator.resume()
            } else {
                try await coordinator.pause()
            }
        } catch {
            notice = error.localizedDescription
        }
        await refresh()
    }

    func stop() async {
        do {
            try await coordinator.stop()
        } catch {
            notice = error.localizedDescription
        }
        await refresh()
    }

    /// The 0.1.0 core intentionally ends capture in `processing`; there is no
    /// transcription pipeline yet, so the validation screen advances the state
    /// machine explicitly instead of silently flipping it.
    func markProcessingCompleted() async {
        do {
            try await coordinator.markProcessingCompleted()
        } catch {
            notice = error.localizedDescription
        }
        await refresh()
    }

    func scenePhaseChanged(to phase: ScenePhaseLike) {
        switch phase {
        case .background:
            coordinator.applicationEnteredBackground()
            isInBackground = true
        case .active:
            coordinator.applicationBecameActive()
            isInBackground = false
        default:
            break
        }
    }

    // MARK: - Recovery evidence

    func recoverOnLaunch() async {
        await runRecovery()
    }

    func runRecoveryAgain() async {
        await runRecovery()
    }

    private func runRecovery() async {
        do {
            let result = try await repository.recoverUnfinished(at: Date())
            recoveries.append(RecoverySummary(
                date: Date(),
                replayedEventCount: result.replayedEventCount,
                recoveredRecordingIDs: result.interruptedRecordingIDs
            ))
            notice = result.interruptedRecordingIDs.isEmpty
                ? "恢复检查完成：没有未完成的录音（幂等）。"
                : "恢复完成：\(result.interruptedRecordingIDs.count) 条录音转为 interrupted。"
        } catch {
            notice = "恢复失败：\(error.localizedDescription)"
        }
        await refresh()
    }

    // MARK: - Diagnostics and report

    func runDiagnostics() async {
        var recordingID = activeRecordingID
        if recordingID == nil {
            recordingID = await latestRecordingID()
        }
        guard let recordingID else {
            notice = "没有可诊断的录音。"
            return
        }
        do {
            integrityIssues = try await diagnostics.inspect(recordingID: recordingID, repository: repository)
            inspectedRecordingID = recordingID
            notice = integrityIssues?.isEmpty == true
                ? "完整性诊断通过：无重叠、无未解释缺口、音频可读。"
                : "完整性诊断发现 \(integrityIssues?.count ?? 0) 个问题。"
        } catch {
            notice = "诊断失败：\(error.localizedDescription)"
        }
    }

    func makeReport() async {
        if integrityIssues == nil {
            await runDiagnostics()
        }
        var checks: [RecordingValidationReport.Check] = []
        if let issues = integrityIssues {
            checks.append(RecordingValidationReport.Check(
                id: "integrity",
                title: "完整性诊断（边界/缺口/可读性）",
                outcome: issues.isEmpty ? .passed : .failed,
                notes: inspectedRecordingID.map { "Recording \($0.uuidString.prefix(8))" } ?? ""
            ))
        }
        checks.append(contentsOf: manualChecks())

        var report = RecordingValidationReport(
            deviceModel: Self.deviceModel(),
            operatingSystem: "iOS \(UIDevice.current.systemVersion)",
            appBuild: Self.appBuild(),
            startedAt: Date(),
            completedAt: nil,
            checks: checks,
            integrityIssues: integrityIssues ?? []
        )
        report.checks.append(RecordingValidationReport.Check(
            id: "chunks",
            title: "chunk 边界汇总",
            outcome: .pending,
            notes: chunkBoundarySummary()
        ))

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let url = repository.rootURL
            .deletingLastPathComponent()
            .appendingPathComponent("validation-report-\(formatter.string(from: Date())).md")
        do {
            try report.markdown().write(to: url, atomically: true, encoding: .utf8)
            reportURL = url
            notice = "报告已生成：\(url.lastPathComponent)"
        } catch {
            notice = "报告写入失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Private

    private func presentationChanged(to state: RecordingSessionCoordinator.PresentationState) {
        presentation = state
        switch state {
        case .recording, .stopping, .processing, .paused:
            startPolling()
        case .interrupted:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            startPolling()
        case .failed:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .idle:
            stopPolling()
            inputLevel = nil
        }
        Task { await refresh() }
    }

    private func startPolling() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func stopPolling() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func refresh() async {
        do {
            recordings = try await repository.recordings()
                .sorted { $0.startedAt > $1.startedAt }
        } catch {
            notice = "读取记录列表失败：\(error.localizedDescription)"
        }

        var recordingID = activeRecordingID
        if recordingID == nil {
            recordingID = await latestRecordingID()
        }
        guard let recordingID else {
            snapshot = Snapshot(
                appliedEventCount: await repository.appliedEventCount,
                schemaVersion: await repository.schemaVersion
            )
            return
        }
        do {
            snapshot = Snapshot(
                recording: try await repository.recording(id: recordingID),
                chunks: try await repository.chunks(recordingID: recordingID)
                    .sorted { $0.startSample < $1.startSample },
                gaps: try await repository.gaps(recordingID: recordingID)
                    .sorted { $0.startedAt < $1.startedAt },
                appliedEventCount: await repository.appliedEventCount,
                schemaVersion: await repository.schemaVersion
            )
        } catch {
            notice = "读取索引失败：\(error.localizedDescription)"
        }
    }

    private func latestRecordingID() async -> UUID? {
        guard let recordings = try? await repository.recordings() else { return nil }
        return recordings.max(by: { $0.startedAt < $1.startedAt })?.id
    }

    private func manualChecks() -> [RecordingValidationReport.Check] {
        let titles = [
            ("background-30min", "30 分钟后台连续（锁屏/切换 App）"),
            ("lockscreen-stop", "锁屏/控制中心停止入口"),
            ("two-hour-chunks", "2 小时连续分片（约 5 分钟边界）"),
            ("interruption-gap", "电话/Siri 中断产生 gap 且 UI 显示 interrupted"),
            ("route-gap", "蓝牙断连/路由变化产生显式 gap"),
            ("termination-recovery", "强制终止后恢复 interrupted 且重复恢复幂等"),
            ("low-storage", "低存储拒绝新录音（请求麦克风前，原因明确）"),
        ]
        return titles.map { RecordingValidationReport.Check(id: $0.0, title: $0.1, outcome: .pending, notes: "") }
    }

    private func chunkBoundarySummary() -> String {
        guard !snapshot.chunks.isEmpty else { return "无 chunk" }
        let totalSamples = snapshot.chunks.map { $0.endSample - $0.startSample }.reduce(0, +)
        let lines = snapshot.chunks.map {
            "  \($0.startSample)–\($0.endSample)（\(String(format: "%.1f", Double($0.endSample - $0.startSample) / 16_000))s，\($0.state.rawValue)）"
        }
        return "共 \(snapshot.chunks.count) 个 chunk，合计 \(String(format: "%.1f", Double(totalSamples) / 16_000))s：\n" + lines.joined(separator: "\n")
    }

    private static func deviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { buffer in
            buffer.baseAddress.map { String(cString: $0.assumingMemoryBound(to: CChar.self)) } ?? UIDevice.current.model
        }
        return "\(UIDevice.current.model) \(machine)"
    }

    private static func appBuild() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "speech_note \(version) (\(build))"
    }
}

/// Mirrors SwiftUI.ScenePhase without importing SwiftUI into the model.
enum ScenePhaseLike {
    case active
    case inactive
    case background
}
