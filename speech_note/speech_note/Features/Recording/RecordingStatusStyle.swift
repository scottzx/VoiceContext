import SwiftUI

/// Shared status copy / symbol / color for recording surfaces.
/// Keeps list rows, detail, session screen, and the global bar aligned without
/// duplicating switch statements across ContentView.
enum RecordingStatusStyle {
    static func text(for state: RecordingState) -> String {
        switch state {
        case .recording: L("正在录音")
        case .paused: L("已暂停")
        case .interrupted: L("已中断")
        case .stopping: L("正在停止")
        case .processing: L("正在处理")
        case .complete: L("已完成")
        case .failed: L("需要注意")
        }
    }

    static func symbolName(for state: RecordingState) -> String {
        switch state {
        case .recording: "record.circle.fill"
        case .paused: "pause.circle.fill"
        case .interrupted, .failed: "exclamationmark.triangle.fill"
        case .stopping: "stop.circle"
        case .processing: "hourglass"
        case .complete: "checkmark.circle"
        }
    }

    static func color(for state: RecordingState) -> Color {
        switch state {
        case .recording, .failed: .red
        case .paused, .interrupted, .processing: .orange
        case .stopping, .complete: .secondary
        }
    }

    static func text(for presentation: RecordingSessionCoordinator.PresentationState) -> String {
        switch presentation {
        case .recording: L("正在录音")
        case .paused: L("已暂停")
        case .interrupted: L("已中断")
        case .stopping: L("正在安全停止")
        case .processing: L("正在处理")
        case .idle, .failed: L("录音已结束")
        }
    }

    static func symbolName(for presentation: RecordingSessionCoordinator.PresentationState) -> String {
        switch presentation {
        case .recording: "record.circle.fill"
        case .paused: "pause.circle.fill"
        case .interrupted: "exclamationmark.triangle.fill"
        case .stopping: "stop.circle"
        case .processing: "hourglass"
        case .idle, .failed: "checkmark.circle"
        }
    }

    static func color(for presentation: RecordingSessionCoordinator.PresentationState) -> Color {
        switch presentation {
        case .recording: .red
        case .paused, .interrupted, .processing: .orange
        case .stopping, .idle: .secondary
        case .failed: .red
        }
    }

    /// Compact titles for the global recording bar (capture-owned only).
    static func barTitle(for presentation: RecordingSessionCoordinator.PresentationState) -> String {
        switch presentation {
        case .recording: L("正在录音")
        case .paused: L("录音已暂停")
        case .interrupted: L("已中断")
        case .stopping: L("正在安全停止")
        case .processing: L("正在处理")
        case .idle: L("录音状态变化中")
        case .failed: L("需要注意")
        }
    }

    // MARK: - Capture vs processing (orthogonal)

    static func captureText(for capture: RecordingCaptureState) -> String {
        switch capture {
        case .idle: L("录音已停止")
        case .preparing: L("正在准备录音")
        case .recording: L("正在录音")
        case .paused: L("已暂停")
        case .interrupted: L("已中断")
        case .stopping: L("正在安全停止")
        }
    }

    static func captureSymbolName(for capture: RecordingCaptureState) -> String {
        switch capture {
        case .idle: "stop.circle"
        case .preparing: "ellipsis.circle"
        case .recording: "record.circle.fill"
        case .paused: "pause.circle.fill"
        case .interrupted: "exclamationmark.triangle.fill"
        case .stopping: "stop.circle"
        }
    }

    static func captureColor(for capture: RecordingCaptureState) -> Color {
        switch capture {
        case .recording: .red
        case .paused, .interrupted: .orange
        case .preparing, .stopping, .idle: .secondary
        }
    }

    static func processingText(for processing: RecordingProcessingState) -> String {
        switch processing {
        case .idle: L("尚未开始转写")
        case .queued: L("排队处理中")
        case .processing: L("正在处理")
        case .speakerFinalization: L("逐字稿已完成，正在整理说话人")
        case .deferredUntilForeground: L("待回到前台后继续")
        case .lockedPendingPurchase: L("音频已保存，转写等待解锁")
        case .needsAttention: L("需要注意，可重试")
        case .complete: L("全部完成")
        }
    }

    static func processingSymbolName(for processing: RecordingProcessingState) -> String {
        switch processing {
        case .idle: "text.bubble"
        case .queued: "clock"
        case .processing: "hourglass"
        case .speakerFinalization: "person.2"
        case .deferredUntilForeground: "iphone"
        case .lockedPendingPurchase: "lock.fill"
        case .needsAttention: "exclamationmark.triangle.fill"
        case .complete: "checkmark.circle"
        }
    }

    static func processingColor(for processing: RecordingProcessingState) -> Color {
        switch processing {
        case .idle, .complete: .secondary
        case .queued, .processing, .speakerFinalization, .deferredUntilForeground, .lockedPendingPurchase: .orange
        case .needsAttention: .red
        }
    }

    /// Honest minute-level progress. Never invents a value from animation timers.
    static func transcribedUpToText(_ interval: TimeInterval?) -> String? {
        guard let interval else { return nil }
        return String(format: L("已转写至 +%@"), formatDuration(interval))
    }

    static func outstandingItemsText(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return String(format: L("还剩 %lld 项"), count)
    }

    /// Secondary line for capture chrome / detail: progress without chunk jargon.
    static func progressDetailText(
        for progress: RecordingPresentationProgress,
        isInBackground: Bool
    ) -> String {
        var parts: [String] = []
        if let transcribed = transcribedUpToText(progress.transcribedUpTo) {
            parts.append(transcribed)
        }
        if let outstanding = outstandingItemsText(progress.outstandingItemCount) {
            parts.append(outstanding)
        }
        switch progress.processing {
        case .deferredUntilForeground:
            parts.append(isInBackground ? L("转写待回到前台后继续") : processingText(for: .deferredUntilForeground))
        case .lockedPendingPurchase:
            parts.append(processingText(for: .lockedPendingPurchase))
        case .needsAttention:
            parts.append(processingText(for: .needsAttention))
        case .speakerFinalization:
            parts.append(processingText(for: .speakerFinalization))
        case .processing, .queued:
            if parts.isEmpty {
                parts.append(processingText(for: progress.processing))
            }
        case .idle:
            if progress.capture == .interrupted {
                parts.append(L("可点继续恢复"))
            } else if progress.capture == .recording || progress.capture == .paused {
                parts.append(isInBackground ? L("录音继续，转写待前台处理") : L("分钟级增量转写"))
            }
        case .complete:
            if parts.isEmpty {
                parts.append(processingText(for: .complete))
            }
        }
        return parts.isEmpty ? processingText(for: progress.processing) : parts.joined(separator: " · ")
    }

    static func formatDuration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.down)))
        return seconds >= 3_600
            ? String(format: "%d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
