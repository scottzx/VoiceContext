import SwiftUI

/// Shared status copy / symbol / color for recording surfaces.
/// Keeps list rows, detail, session screen, and the global bar aligned without
/// duplicating switch statements across ContentView.
enum RecordingStatusStyle {
    static func text(for state: RecordingState) -> String {
        switch state {
        case .recording: "正在录音"
        case .paused: "已暂停"
        case .interrupted: "录音中断，需要注意"
        case .stopping: "正在停止"
        case .processing: "正在处理"
        case .complete: "已完成"
        case .failed: "需要注意"
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
        case .recording: "正在录音"
        case .paused: "已暂停"
        case .interrupted: "已中断，等待恢复"
        case .stopping: "正在安全停止"
        case .processing: "正在处理"
        case .idle, .failed: "录音已结束"
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
        case .recording: "正在录音"
        case .paused: "录音已暂停"
        case .interrupted: "录音已中断"
        case .stopping: "正在安全停止"
        case .processing: "正在处理"
        case .idle: "录音状态变化中"
        case .failed: "需要注意"
        }
    }

    // MARK: - Capture vs processing (orthogonal)

    static func captureText(for capture: RecordingCaptureState) -> String {
        switch capture {
        case .idle: "录音已停止"
        case .preparing: "正在准备录音"
        case .recording: "正在录音"
        case .paused: "已暂停"
        case .interrupted: "录音中断，需要注意"
        case .stopping: "正在安全停止"
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
        case .idle: "尚未开始转写"
        case .queued: "排队处理中"
        case .processing: "正在处理"
        case .deferredUntilForeground: "待回到前台后继续"
        case .lockedPendingPurchase: "音频已保存，转写等待解锁"
        case .needsAttention: "需要注意，可重试"
        case .complete: "全部完成"
        }
    }

    static func processingSymbolName(for processing: RecordingProcessingState) -> String {
        switch processing {
        case .idle: "text.bubble"
        case .queued: "clock"
        case .processing: "hourglass"
        case .deferredUntilForeground: "iphone"
        case .lockedPendingPurchase: "lock.fill"
        case .needsAttention: "exclamationmark.triangle.fill"
        case .complete: "checkmark.circle"
        }
    }

    static func processingColor(for processing: RecordingProcessingState) -> Color {
        switch processing {
        case .idle, .complete: .secondary
        case .queued, .processing, .deferredUntilForeground, .lockedPendingPurchase: .orange
        case .needsAttention: .red
        }
    }

    /// Honest minute-level progress. Never invents a value from animation timers.
    static func transcribedUpToText(_ interval: TimeInterval?) -> String? {
        guard let interval else { return nil }
        return "已转写至 +\(formatDuration(interval))"
    }

    static func outstandingItemsText(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return "还剩 \(count) 项"
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
            parts.append(isInBackground ? "转写待回到前台后继续" : processingText(for: .deferredUntilForeground))
        case .lockedPendingPurchase:
            parts.append(processingText(for: .lockedPendingPurchase))
        case .needsAttention:
            parts.append(processingText(for: .needsAttention))
        case .processing, .queued:
            if parts.isEmpty {
                parts.append(processingText(for: progress.processing))
            }
        case .idle:
            if progress.capture == .recording || progress.capture == .paused || progress.capture == .interrupted {
                parts.append(isInBackground ? "录音继续，转写待前台处理" : "分钟级增量转写")
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
