import SwiftUI

struct TranscriptionCenterView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: RecordingCoreModel

    @State private var queueStatus = TranscriptionQueueStatus()
    @State private var selectedTab: TaskTabState = .todo
    @State private var isRefreshing = false
    @State private var selectedRecordingID: UUID? = nil

    enum TaskTabState: String, CaseIterable, Identifiable {
        case todo = "待办"
        case running = "进行中"
        case failed = "异常需关注"
        case cancelled = "已取消"
        case completed = "已完成"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .todo: "list.bullet.clipboard"
            case .running: "waveform"
            case .failed: "exclamationmark.triangle.fill"
            case .cancelled: "stop.circle"
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

    // MARK: - 卡片 1：统计与切换概览卡片 (Statistics & Tab Card)

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
                        Text("正在处理")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.12), in: Capsule())
                }
            }

            HStack(spacing: 8) {
                statTabButton(
                    tab: .todo,
                    title: "待办",
                    count: queueStatus.todoTasks.count,
                    icon: "list.bullet.clipboard",
                    color: .secondary,
                    isPulse: false
                )
                statTabButton(
                    tab: .running,
                    title: "进行中",
                    count: queueStatus.runningTasks.count,
                    icon: "bolt.fill",
                    color: .orange,
                    isPulse: !queueStatus.runningTasks.isEmpty
                )
                statTabButton(
                    tab: .failed,
                    title: "异常",
                    count: queueStatus.failedTasks.count,
                    icon: "exclamationmark.triangle.fill",
                    color: .red,
                    isPulse: !queueStatus.failedTasks.isEmpty
                )
                statTabButton(
                    tab: .cancelled,
                    title: "已取消",
                    count: queueStatus.cancelledTasks.count,
                    icon: "stop.circle",
                    color: .secondary,
                    isPulse: false
                )
                statTabButton(
                    tab: .completed,
                    title: "已完成",
                    count: queueStatus.completedRecordingGroups.count,
                    icon: "checkmark.circle.fill",
                    color: .green,
                    isPulse: false
                )
            }
            .padding(.vertical, 2)

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

    private func statTabButton(
        tab: TaskTabState,
        title: String,
        count: Int,
        icon: String,
        color: Color,
        isPulse: Bool
    ) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedTab = tab
            }
        } label: {
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(color)
                        .symbolEffect(.pulse, isActive: isPulse && !reduceMotion)
                    Text("\(count)")
                        .font(.system(size: 20, weight: isSelected ? .bold : .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.primary)
                }
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                isSelected ? Color(uiColor: .systemBackground) : Color(uiColor: .tertiarySystemGroupedBackground).opacity(0.5),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.primary.opacity(0.12) : Color.clear, lineWidth: 1)
            )
            .shadow(color: isSelected ? Color.black.opacity(0.06) : Color.clear, radius: 3, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - 卡片 2：列表卡片 (Task List Card)

    private var currentTabTasks: [RecordingProcessingTaskItem] {
        switch selectedTab {
        case .todo:
            return queueStatus.todoTasks
        case .running:
            return queueStatus.runningTasks
        case .failed:
            return queueStatus.failedTasks
        case .cancelled:
            return queueStatus.cancelledTasks
        case .completed:
            return queueStatus.completedTasks
        }
    }

    private var currentTabItemCount: Int {
        selectedTab == .completed
            ? queueStatus.completedRecordingGroups.count
            : currentTabTasks.count
    }

    private var isCurrentTabEmpty: Bool {
        currentTabItemCount == 0
    }

    private func tabColor(_ tab: TaskTabState) -> Color {
        switch tab {
        case .todo: .secondary
        case .running: .orange
        case .failed: .red
        case .cancelled: .secondary
        case .completed: .green
        }
    }

    private var taskListCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: selectedTab.icon)
                        .font(.body)
                        .foregroundStyle(tabColor(selectedTab))
                    Text(selectedTab.rawValue)
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
                Spacer()
                Text(selectedTab == .completed
                    ? "\(currentTabItemCount) 个记录"
                    : "\(currentTabItemCount) 个任务")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            if isCurrentTabEmpty {
                emptyStateView
                    .padding(.vertical, 28)
                    .padding(.bottom, 8)
            } else if selectedTab == .completed {
                LazyVStack(spacing: 10) {
                    ForEach(queueStatus.completedRecordingGroups) { group in
                        completedRecordingRow(group)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(Array(currentTabTasks.enumerated()), id: \.element.id) { index, task in
                        taskRow(task, index: index + 1)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
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

    private func taskRow(_ task: RecordingProcessingTaskItem, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text("\(index)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 18, alignment: .leading)
                    .accessibilityLabel("第 \(index) 项")

                VStack(alignment: .leading, spacing: 2) {
                    Text(stageTitle(task.stage))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(task.recordingTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                if task.state == .failed {
                    Button("重试") {
                        Task {
                            await model.retryProcessingTask(
                                recordingID: task.recordingID,
                                stage: task.stage
                            )
                            await refreshQueue()
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    .frame(minHeight: 44)
                }

                Button("查看") {
                    selectedRecordingID = task.recordingID
                }
                .font(.caption.weight(.medium))
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
            }

            HStack(alignment: .top, spacing: 0) {
                compactStatus(
                    title: "状态",
                    value: taskStateTitle(task.state),
                    color: taskStateColor(task.state)
                )
                Spacer(minLength: 20)
                compactStageProgress(
                    title: task.stage == .transcription ? "逐字稿" : "声纹",
                    progress: task.progress,
                    activeTitle: task.stage == .transcription ? "识别中" : "提取中"
                )
                if task.stage == .speakerProcessing {
                    Spacer(minLength: 20)
                    compactFinalization(task.speakerFinalizationState)
                }
                Spacer(minLength: 20)

                compactStatus(
                    title: "更新",
                    value: task.updatedAt.standardTimeString,
                    color: .secondary,
                    alignment: .trailing
                )
            }

            if let dependencyMessage = task.dependencyMessage,
               task.state == .todo {
                Label(dependencyMessage, systemImage: "arrow.turn.down.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = task.lastError, !error.isEmpty {
                Text("提示: \(formatErrorMessage(error))")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
        .padding(12)
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .accessibilityIdentifier("processing-task-\(task.id)")
        .contextMenu {
            if task.state == .cancelled {
                Button {
                    Task {
                        await model.restartCancelledProcessingTask(
                            recordingID: task.recordingID,
                            stage: task.stage
                        )
                        await refreshQueue()
                    }
                } label: {
                    Label("重新开始任务", systemImage: "arrow.clockwise")
                }
            } else if task.state != .completed {
                Button {
                    Task {
                        await model.markProcessingTaskCompleted(
                            recordingID: task.recordingID,
                            stage: task.stage
                        )
                        await refreshQueue()
                    }
                } label: {
                    Label("标记为已完成", systemImage: "checkmark.circle")
                }

                Button(role: .destructive) {
                    Task {
                        await model.cancelProcessingTask(
                            recordingID: task.recordingID,
                            stage: task.stage
                        )
                        await refreshQueue()
                    }
                } label: {
                    Label("取消任务", systemImage: "stop.circle")
                }
            }
        }
    }

    private func completedRecordingRow(_ group: CompletedRecordingProcessingGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Text(group.recordingTitle)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Spacer(minLength: 8)

                Button("查看") {
                    selectedRecordingID = group.recordingID
                }
                .font(.caption.weight(.medium))
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
            }

            Divider()

            ForEach(Array(group.tasks.enumerated()), id: \.element.id) { index, task in
                if index > 0 {
                    Divider()
                        .padding(.leading, 26)
                }
                completedStageRow(task, index: index + 1)
            }
        }
        .padding(12)
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("completed-recording-\(group.recordingID.uuidString)")
    }

    private func completedStageRow(
        _ task: RecordingProcessingTaskItem,
        index: Int
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(index).")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 18, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(completedStageTitle(task.stage))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text("\(task.progress.completed)/\(task.progress.total) 已完成")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 3) {
                Text("完成时间")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(task.updatedAt.formatted(.dateTime.month().day().hour().minute()))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("completed-stage-\(task.id)")
    }

    // MARK: - 固定底部快捷操作栏 (Fixed Bottom Action Dock)

    private var fixedBottomActionDock: some View {
        Group {
            switch selectedTab {
            case .todo, .running:
                stoppableTaskActions
            case .failed:
                failedTaskActions
            case .cancelled:
                EmptyView()
            case .completed:
                EmptyView()
            }
        }
    }

    private var stoppableTaskActions: some View {
        VStack(spacing: 8) {
            Divider()
            stopAllButton
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 6)
        }
        .background(.ultraThinMaterial)
    }

    private var failedTaskActions: some View {
        VStack(spacing: 8) {
            Divider()
            HStack(spacing: 8) {
                stopAllButton

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

    private var stopAllButton: some View {
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
        .tint(.red)
        .disabled(
            queueStatus.todoTasks.isEmpty
                && queueStatus.runningTasks.isEmpty
                && queueStatus.failedTasks.isEmpty
        )
    }

    // MARK: - Helpers

    private func refreshQueue() async {
        isRefreshing = true
        defer { isRefreshing = false }
        queueStatus = await model.fetchTranscriptionQueueStatus()
    }

    private func stageTitle(_ stage: ProcessingTaskStage) -> String {
        switch stage {
        case .transcription: "逐字稿识别"
        case .speakerProcessing: "声文整理"
        }
    }

    private func completedStageTitle(_ stage: ProcessingTaskStage) -> String {
        switch stage {
        case .transcription: "逐字稿识别"
        case .speakerProcessing: "声文识别"
        }
    }

    private func taskStateTitle(_ state: ProcessingTaskState) -> String {
        switch state {
        case .todo: "待办"
        case .running: "进行中"
        case .failed: "异常"
        case .cancelled: "已取消"
        case .completed: "已完成"
        }
    }

    private func taskStateColor(_ state: ProcessingTaskState) -> Color {
        switch state {
        case .todo, .cancelled: .secondary
        case .running: .orange
        case .failed: .red
        case .completed: .green
        }
    }

    private func compactStageProgress(
        title: String,
        progress: ProcessingStageProgress,
        activeTitle: String
    ) -> some View {
        compactStatus(
            title: title,
            value: progress.cancelled > 0
                ? "已取消"
                : progress.failed > 0
                ? "\(progress.failed) 异常"
                : "\(progress.completed)/\(progress.total)",
            color: progress.cancelled > 0
                ? .secondary
                : (progress.failed > 0 ? .red : (progress.running > 0 ? .orange : .secondary)),
            detail: progress.running > 0 ? activeTitle : nil
        )
    }

    private func compactFinalization(_ state: RecordingJobState?) -> some View {
        compactStatus(
            title: "整理",
            value: finalizationTitle(state),
            color: finalizationColor(state)
        )
    }

    private func compactStatus(
        title: String,
        value: String,
        color: Color,
        detail: String? = nil,
        alignment: HorizontalAlignment = .leading
    ) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.medium))
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(color)
                    .lineLimit(1)
            }
        }
    }

    private func finalizationTitle(_ state: RecordingJobState?) -> String {
        switch state {
        case .running: "整理中"
        case .pending: "待办"
        case .completed: "已完成"
        case .failed: "异常"
        case .cancelled: "已取消"
        case nil: "待办"
        }
    }

    private func finalizationColor(_ state: RecordingJobState?) -> Color {
        switch state {
        case .completed: .green
        case .failed: .red
        case .cancelled: .secondary
        case .running: .orange
        case .pending, nil: .secondary
        }
    }

    private func formatErrorMessage(_ error: String) -> String {
        switch error {
        case "userStopped":
            return "已手动关停，可长按任务重新开始。"
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
