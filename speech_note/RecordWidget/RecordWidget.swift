import SwiftUI
import WidgetKit

/// Home-screen Record control. Opens the app start-recording deep link only.
/// Never renders transcript / note privacy content (FR-ADD-WDG-003).
struct RecordWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecordWidgetEntry {
        RecordWidgetEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (RecordWidgetEntry) -> Void) {
        completion(RecordWidgetEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecordWidgetEntry>) -> Void) {
        let entry = RecordWidgetEntry(date: .now)
        // Static control surface — no timeline refresh needed.
        completion(Timeline(entries: [entry], policy: .never))
    }
}

struct RecordWidgetEntry: TimelineEntry {
    let date: Date
}

struct RecordWidgetView: View {
    var entry: RecordWidgetEntry
    @Environment(\.widgetFamily) private var family

    /// Keep the URL in-extension (no App Group / shared framework required).
    private var startRecordingURL: URL {
        URL(string: "voicecontext://start-recording")!
    }

    var body: some View {
        Group {
            switch family {
            case .systemMedium:
                mediumBody
            default:
                smallBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(for: .widget) {
            Color(.systemBackground)
        }
        .widgetURL(startRecordingURL)
        .accessibilityLabel("开始录音")
        .accessibilityHint("打开应用并进入开录流程")
    }

    private var smallBody: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.red)
                    .frame(width: 44, height: 44)
                Image(systemName: "mic.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text("Record")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(8)
    }

    private var mediumBody: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.red)
                    .frame(width: 56, height: 56)
                Image(systemName: "mic.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Record")
                    .font(.title3.weight(.semibold))
                Text("轻点进入开录")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }
}

@main
struct RecordWidget: Widget {
    let kind = "RecordWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RecordWidgetProvider()) { entry in
            RecordWidgetView(entry: entry)
        }
        .configurationDisplayName("录音")
        .description("从主屏一键进入开录流程。不显示逐字稿内容。")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}
