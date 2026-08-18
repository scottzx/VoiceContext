import SwiftUI

struct TranscriptionCenterView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: RecordingCoreModel

    @State private var queueStatus = TranscriptionQueueStatus()
    @State private var selectedTab: TaskTabState = .active
    @State private var isRefreshing = false
    @State private var selectedRecordingID: UUID? = nil

    enum TaskTabState: String, CaseIterable, Identifiable {
        case active = "进行中/排队"
        case failed = "异常需关注"
        case completed = "已完成"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .active: "waveform"
            case .failed: "exclamationmark.triangle.fill"
            case .completed: "checkmark.circle.fill"
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // 卡片 1：统计卡片
                    statisticsCard

                    // 卡片 2：列表卡片（下方带有滑块控制器）
                    taskListCard
                }
                .padding(.vertical, 16)
                .padding(.bottom, 72) // 预留底部快捷键高度，防止被遮挡
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("转写任务中心")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await refreshQueue() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isRefreshing)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // 固定在屏幕底部的快捷操作栏
                fixedBottomActionDock
            }
            .task {
                while !Task.isCancelled {
                    await refreshQueue()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            .sheet(item: Binding(
                get: { selectedRecordingID.map { IdentifiableUUID(id: $0) } },
                set: { selectedRecordingID = $0?.id }
            )) { item in
                NavigationStack {
                    RecordingDetailScreen(model: model, recordingID: item.id)
                }
            }
        }
    }

    // MARK: - 卡片 1：统计卡片 (Statistics Card)

    private var statisticsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "chart.bar.xaxis")
                        .foregroundStyle(.blue)
                    Text("任务与系统概览")
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
                Spacer()
                if !queueStatus.runningTasks.isEmpty {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 7, height: 7)
                        Text("正在转写")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.12), in: Capsule())
                }
            }

            HStack(spacing: 0) {
                statItem(
                    title: "进行/排队",
                    count: queueStatus.runningTasks.count + queueStatus.pendingTasks.count,
                    icon: "bolt.fill",
                    color: .orange,
                    isPulse: !queueStatus.runningTasks.isEmpty
                )
                Divider().frame(height: 36)
                statItem(
                    title: "需关注/异常",
                    count: queueStatus.failedTasks.count,
                    icon: "exclamationmark.triangle.fill",
                    color: .red,
                    isPulse: !queueStatus.failedTasks.isEmpty
                )
                Divider().frame(height: 36)
                statItem(
                    title: "已就绪分段",
                    count: queueStatus.completedTasks.count,
                    icon: "checkmark.circle.fill",
                    color: .green,
                    isPulse: false
                )
            }
            .padding(.vertical, 4)

            Divider()

            // 系统健康轻量指示条
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                    Text("Metal: \(queueStatus.runningTasks.isEmpty ? "就绪" : "计算中")")
                }
                .font(.caption2)
                .foregroundStyle(queueStatus.runningTasks.isEmpty ? Color.secondary : Color.orange)

                HStack(spacing: 4) {
                    Image(systemName: "thermometer.medium")
                    Text("温控: \(queueStatus.thermalState)")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                Spacer()

                if model.captureIsActive {
                    HStack(spacing: 4) {
                        Image(systemName: "mic.fill")
                        Text("录音中")
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.red)
                }
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
    }

    private func statItem(
        title: String,
        count: Int,
        icon: String,
        color: Color,
        isPulse: Bool
    ) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(color)
                    .symbolEffect(.pulse, isActive: isPulse && !reduceMotion)
                Text("\(count)")
                    .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.primary)
            }
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 卡片 2：列表卡片（下方带有滑块控制器）

    private var currentTabTasks: [TranscriptionTaskItem] {
        switch selectedTab {
        case .active:
            return queueStatus.runningTasks + queueStatus.pendingTasks
        case .failed:
            return queueStatus.failedTasks
        case .completed:
            return queueStatus.completedTasks
        }
    }

    private func count(for tab: TaskTabState) -> Int {
        switch tab {
        case .active:
            return queueStatus.runningTasks.count + queueStatus.pendingTasks.count
        case .failed:
            return queueStatus.failedTasks.count
        case .completed:
            return queueStatus.completedTasks.count
        }
    }

    private var taskListCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: selectedTab.icon)
                        .font(.body)
                        .foregroundStyle(.blue)
                    Text(selectedTab.rawValue)
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
                Spacer()
                Text("\(currentTabTasks.count) 个任务")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            if currentTabTasks.isEmpty {
                emptyStateView
                    .padding(.vertical, 28)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(currentTabTasks) { task in
                        taskRow(task)
                    }
                }
                .padding(.horizontal, 16)
            }

            // 列表下方的滑块控制器 (Slider / Segmented Controller)
            sliderControlSection
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .padding(.top, 4)
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 32))
                .foregroundStyle(.secondary.opacity(0.6))
            Text("当前分类下暂无任务")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var sliderControlSection: some View {
        HStack(spacing: 0) {
            ForEach(TaskTabState.allCases) { tab in
                let isSelected = selectedTab == tab
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedTab = tab
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 11))
                        Text(tab.rawValue)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        Text("(\(count(for: tab)))")
                            .font(.system(size: 11, design: .rounded).monospacedDigit())
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(
                        isSelected ? Color(uiColor: .systemBackground) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .shadow(color: isSelected ? Color.black.opacity(0.06) : Color.clear, radius: 3, x: 0, y: 1)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private func taskRow(_ task: TranscriptionTaskItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: taskStateIcon(task.state))
                    .font(.body)
                    .foregroundStyle(taskStateColor(task.state))
                    .symbolEffect(.pulse, isActive: task.state == .running && !reduceMotion)

                VStack(alignment: .leading, spacing: 3) {
                    Text(task.recordingTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let timeText = task.timeRangeText {
                        Text(timeText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    if let error = task.lastError, !error.isEmpty {
                        Text("提示: \(formatErrorMessage(error))")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(3)
                    }

                    HStack(spacing: 8) {
                        Text("状态: \(taskStateTitle(task.state))")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(taskStateColor(task.state))

                        if task.attemptCount > 0 {
                            Text("尝试: \(task.attemptCount)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        Text(task.updatedAt.formatted(date: .omitted, time: .shortened))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                VStack(spacing: 8) {
                    if task.state == .failed || task.state == .pending {
                        Button {
                            Task {
                                await model.retryTranscriptionJob(id: task.id)
                                await refreshQueue()
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

                    Button {
                        selectedRecordingID = task.recordingID
                    } label: {
                        Text("查看")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color(uiColor: .tertiarySystemGroupedBackground))
                            .foregroundStyle(.primary)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(12)
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 固定底部快捷操作栏 (Fixed Bottom Action Dock)

    private var fixedBottomActionDock: some View {
        VStack(spacing: 8) {
            Divider()
            HStack(spacing: 8) {
                // 1. 一键开始 / 恢复转写
                Button {
                    Task {
                        await model.resumeAllTranscriptionJobs()
                        await refreshQueue()
                    }
                } label: {
                    Label("一键开始", systemImage: "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)

                // 2. 全部关停
                Button {
                    Task {
                        await model.stopAllTranscriptionJobs()
                        await refreshQueue()
                    }
                } label: {
                    Label("全部关停", systemImage: "stop.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red.opacity(0.9))

                // 3. 重试异常
                Button {
                    Task {
                        await model.retryAllFailedJobs()
                        await refreshQueue()
                    }
                } label: {
                    Label("重试异常", systemImage: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .disabled(queueStatus.failedTasks.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 6)
        }
        .background(.ultraThinMaterial)
    }

    // MARK: - Helpers

    private func refreshQueue() async {
        isRefreshing = true
        defer { isRefreshing = false }
        queueStatus = await model.fetchTranscriptionQueueStatus()
    }

    private func taskStateTitle(_ state: RecordingJobState) -> String {
        switch state {
        case .pending: "排队中"
        case .running: "转写中"
        case .completed: "已就绪"
        case .failed: "异常"
        }
    }

    private func taskStateIcon(_ state: RecordingJobState) -> String {
        switch state {
        case .pending: "clock"
        case .running: "waveform"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private func taskStateColor(_ state: RecordingJobState) -> Color {
        switch state {
        case .pending: .blue
        case .running: .orange
        case .completed: .green
        case .failed: .red
        }
    }

    private func formatErrorMessage(_ error: String) -> String {
        switch error {
        case "userStopped":
            return "已手动全部关停。点击下方「一键开始」可随时继续转写。"
        case "deferredUntilThermalImproves":
            return "设备发热较明显，已暂缓以保护硬件；降温后将自动恢复转写。"
        case "deferredUntilForeground":
            return "应用退至后台时暂缓，回到前台后将继续转写。"
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
}

private struct IdentifiableUUID: Identifiable {
    let id: UUID
}
