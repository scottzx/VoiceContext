import ActivityKit
import SwiftUI
import WidgetKit

/// Lock-screen card is the original status card. Dynamic Island compact uses
/// light-on-dark so the pill is readable; expanded reuses the same card.
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            RecordingLockScreenCardView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    RecordingIslandStatusLabel(state: context.state, onDark: true)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RecordingIslandTimeLabel(context: context, onDark: true)
                }
                DynamicIslandExpandedRegion(.center) {
                    EmptyView()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    RecordingIslandExpandedCardView(context: context)
                }
            } compactLeading: {
                RecordingIslandStatusDot(state: context.state)
            } compactTrailing: {
                RecordingIslandTimeLabel(context: context, onDark: true)
                    .font(.system(.caption, design: .rounded).monospacedDigit().weight(.semibold))
                    .frame(maxWidth: 56)
                    .minimumScaleFactor(0.5)
            } minimal: {
                RecordingIslandStatusDot(state: context.state)
            }
        }
    }
}

/// Original ~60pt status card: indicator, waveform, live timer. No buttons.
struct RecordingLockScreenCardView: View {
    let context: ActivityViewContext<RecordingActivityAttributes>

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            RecordingIslandStatusLabel(state: context.state, onDark: false)

            Spacer(minLength: 4)

            HStack(spacing: 10) {
                waveformBars
                RecordingIslandTimeLabel(context: context, onDark: false)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(height: 60)
        .containerBackground(for: .widget) {
            Color(.secondarySystemBackground).opacity(0.92)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        if context.state.isInterrupted { return "听记已中断" }
        if context.state.isPaused { return "听记已暂停" }
        return "听记正在录音"
    }

    private var waveformBars: some View {
        HStack(spacing: 2) {
            ForEach(0..<10, id: \.self) { index in
                let heights: [CGFloat] = [6, 12, 18, 14, 20, 16, 22, 15, 10, 6]
                RoundedRectangle(cornerRadius: 1)
                    .fill((context.state.isPaused || context.state.isInterrupted)
                          ? Color.secondary.opacity(0.35)
                          : Color.primary.opacity(0.65))
                    .frame(width: 2.5, height: heights[index])
            }
        }
        .frame(height: 24)
        .accessibilityHidden(true)
    }
}

/// Same card content for Dynamic Island expanded, without widget containerBackground.
private struct RecordingIslandExpandedCardView: View {
    let context: ActivityViewContext<RecordingActivityAttributes>

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            RecordingIslandStatusLabel(state: context.state, onDark: false)

            Spacer(minLength: 4)

            HStack(spacing: 10) {
                waveformBars
                RecordingIslandTimeLabel(context: context, onDark: false)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(
            Color(.secondarySystemBackground).opacity(0.92),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private var waveformBars: some View {
        HStack(spacing: 2) {
            ForEach(0..<10, id: \.self) { index in
                let heights: [CGFloat] = [6, 12, 18, 14, 20, 16, 22, 15, 10, 6]
                RoundedRectangle(cornerRadius: 1)
                    .fill((context.state.isPaused || context.state.isInterrupted)
                          ? Color.secondary.opacity(0.35)
                          : Color.primary.opacity(0.65))
                    .frame(width: 2.5, height: heights[index])
            }
        }
        .frame(height: 24)
        .accessibilityHidden(true)
    }
}

private struct RecordingIslandStatusLabel: View {
    let state: RecordingActivityAttributes.ContentState
    let onDark: Bool

    var body: some View {
        HStack(spacing: 6) {
            RecordingIslandStatusDot(state: state)
            Text(statusText)
                .font(.subheadline.weight(state.isPaused ? .medium : .semibold))
                .foregroundStyle(statusColor)
                .lineLimit(1)
        }
    }

    private var statusText: String {
        if state.isInterrupted { return "已中断" }
        if state.isPaused { return "已暂停" }
        return "正在录音"
    }

    private var statusColor: Color {
        if onDark { return .white }
        if state.isPaused || state.isInterrupted { return Color.secondary }
        return Color.primary
    }
}

private struct RecordingIslandStatusDot: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        if state.isInterrupted {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(red: 1.0, green: 0.62, blue: 0.04))
        } else if state.isPaused {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(red: 1.0, green: 0.62, blue: 0.04))
        } else {
            Circle()
                .fill(Color(red: 1.0, green: 0.23, blue: 0.19))
                .frame(width: 8, height: 8)
        }
    }
}

private struct RecordingIslandTimeLabel: View {
    let context: ActivityViewContext<RecordingActivityAttributes>
    let onDark: Bool

    var body: some View {
        Group {
            if context.state.isInterrupted || context.state.isPaused {
                Text(context.state.isInterrupted ? "已中断" : "已暂停")
            } else {
                Text(timerInterval: context.state.startedAt...Date.distantFuture, countsDown: false)
            }
        }
        .font(.system(.body, design: .rounded).monospacedDigit().weight(.semibold))
        .foregroundStyle(onDark ? Color.white : (context.state.isPaused || context.state.isInterrupted ? Color.secondary : Color.primary))
        .multilineTextAlignment(.trailing)
        .lineLimit(1)
    }
}
