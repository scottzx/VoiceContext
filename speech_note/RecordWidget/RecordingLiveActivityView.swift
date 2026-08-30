import ActivityKit
import SwiftUI
import WidgetKit

/// Compact lock screen Live Activity card adhering to DESIGN.md (Quiet Native Utility).
/// Sits in the notification stack area at ~60pt height, never blocking lock screen wallpaper.
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            RecordingLockScreenCardView(context: context)
        } dynamicIsland: { _ in
            // Dynamic Island is kept minimal/inactive per product owner direction.
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { EmptyView() }
                DynamicIslandExpandedRegion(.trailing) { EmptyView() }
                DynamicIslandExpandedRegion(.center) { EmptyView() }
                DynamicIslandExpandedRegion(.bottom) { EmptyView() }
            } compactLeading: {
                EmptyView()
            } compactTrailing: {
                EmptyView()
            } minimal: {
                EmptyView()
            }
        }
    }
}

struct RecordingLockScreenCardView: View {
    let context: ActivityViewContext<RecordingActivityAttributes>

    private var stopRecordingURL: URL {
        URL(string: "voicecontext://stop-recording")!
    }

    private var openRecordingURL: URL {
        URL(string: "voicecontext://recording")!
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Left: State Indicator & Status Text
            HStack(spacing: 6) {
                if context.state.isPaused {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(red: 1.0, green: 0.62, blue: 0.04)) // vc.warning
                    Text("已暂停")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.secondary)
                } else {
                    Circle()
                        .fill(Color(red: 1.0, green: 0.23, blue: 0.19)) // vc.recording
                        .frame(width: 8, height: 8)
                    Text("正在录音")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                }
            }

            Spacer(minLength: 4)

            // Center: Waveform bars & Live Counting Chronometer
            HStack(spacing: 10) {
                waveformBars

                if context.state.isPaused {
                    Text("已暂停")
                        .font(.system(.body, design: .rounded).monospacedDigit().weight(.semibold))
                        .foregroundStyle(Color.secondary)
                } else {
                    Text(timerInterval: context.state.startedAt...Date.distantFuture, countsDown: false)
                        .font(.system(.body, design: .rounded).monospacedDigit().weight(.semibold))
                        .foregroundStyle(Color.primary)
                }
            }

            Spacer(minLength: 4)

            // Right: Stop button with 44x44pt hit target
            Link(destination: stopRecordingURL) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(red: 1.0, green: 0.23, blue: 0.19).opacity(0.15))
                        .frame(width: 38, height: 38)

                    RoundedRectangle(cornerRadius: 3.5)
                        .fill(Color(red: 1.0, green: 0.23, blue: 0.19))
                        .frame(width: 13, height: 13)
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("停止录音")
            .accessibilityHint("在后台安全停止录音并保存分片")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(height: 60)
        .containerBackground(for: .widget) {
            Color(.secondarySystemBackground).opacity(0.92)
        }
        .widgetURL(openRecordingURL)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(context.state.isPaused ? "VoiceContext 录音已暂停" : "VoiceContext 正在录音")
    }

    /// Calm, restrained 10-bar waveform visualizer conforming to DESIGN.md
    private var waveformBars: some View {
        HStack(spacing: 2) {
            ForEach(0..<10, id: \.self) { index in
                let heights: [CGFloat] = [6, 12, 18, 14, 20, 16, 22, 15, 10, 6]
                RoundedRectangle(cornerRadius: 1)
                    .fill(context.state.isPaused
                          ? Color.secondary.opacity(0.35)
                          : Color.primary.opacity(0.65))
                    .frame(width: 2.5, height: heights[index])
            }
        }
        .frame(height: 24)
        .accessibilityHidden(true)
    }
}
