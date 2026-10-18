import SwiftUI
import UniformTypeIdentifiers

struct StoryPlayerView: View {
    @ObservedObject private var library = StoryLibraryStore.shared
    @ObservedObject private var player = StoryPlaybackController.shared
    @ObservedObject private var voice = XiaolanVoiceController.shared
    @State private var showImporter = false
    @State private var pendingDeletion: StoryAudio?
    @State private var operationError: String?

    private var currentStory: StoryAudio? { library.stories.first { $0.id == player.currentStoryID } }
    private var hasFinished: Bool { player.duration > 0 && player.currentTime >= player.duration }
    private var hasPlaybackIntent: Bool { player.isPlaying || player.isWaitingForVoice }
    private var completionSessionID: String? { voice.isEnabled ? voice.sessionID : nil }
    private var playbackStatus: String {
        player.isWaitingForVoice ? "等待语音结束后播放" : (player.isPlaying ? "正在播放" : (hasFinished ? "已播完" : "已暂停"))
    }

    var body: some View {
        List {
            if let error = library.loadError {
                Section { Text(error).foregroundStyle(YimaDesign.Color.muted) }
            }
            if let story = currentStory {
                Section("当前故事") { playbackControls(story) }
            }
            if let error = player.error {
                Section { Text(error).font(YimaDesign.Typography.metadata).foregroundStyle(YimaDesign.Color.muted) }
            }
            if library.stories.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: YimaDesign.Space.md) {
                        Text("还没有故事音频")
                            .font(YimaDesign.Typography.section)
                        Text("导入音频后，可以点击播放，也可以让小蓝同学播放、暂停或换一篇。")
                            .font(YimaDesign.Typography.metadata)
                            .foregroundStyle(YimaDesign.Color.muted)
                        Button("导入音频", action: openImporter)
                            .frame(minHeight: YimaDesign.Layout.primaryHeight)
                            .disabled(library.loadError != nil)
                    }
                    .padding(.vertical, YimaDesign.Space.lg)
                }
            } else {
                Section {
                    ForEach(library.stories) { story in
                        storyRow(story)
                    }
                } header: {
                    Text("故事（\(library.stories.count)）")
                } footer: {
                    Text("可以对小蓝同学说：“播放\(library.stories.first?.title ?? "故事名称")”“暂停故事”或“换一篇”。")
                }
            }
        }
        .listStyle(.plain)
        .background(YimaDesign.Color.canvas)
        .tint(YimaDesign.Color.ink)
        .navigationTitle("儿童故事机")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: openImporter) {
                    Label("导入音频", systemImage: "plus")
                        .frame(minWidth: YimaDesign.Layout.hitTarget, minHeight: YimaDesign.Layout.hitTarget)
                }
                .disabled(library.loadError != nil)
                .accessibilityIdentifier("story-import-audio")
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio], allowsMultipleSelection: true, onCompletion: importAudio)
        .pausesXiaolanVoice(while: showImporter || pendingDeletion != nil)
        .confirmationDialog("删除故事？", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }), titleVisibility: .visible) {
            if let story = pendingDeletion {
                Button("删除音频", role: .destructive) { remove(story) }
                Button("取消", role: .cancel) { pendingDeletion = nil }
            }
        } message: {
            if let story = pendingDeletion { Text("将从故事库删除“\(story.title)”。") }
        }
        .alert("故事机", isPresented: Binding(get: { operationError != nil }, set: { if !$0 { operationError = nil } })) {
            Button("好", role: .cancel) { operationError = nil }
        } message: { Text(operationError ?? "") }
    }

    private func playbackControls(_ story: StoryAudio) -> some View {
        VStack(alignment: .leading, spacing: YimaDesign.Space.md) {
            Text(story.title).font(YimaDesign.Typography.itemTitle)
            Text(playbackStatus)
                .font(YimaDesign.Typography.metadata)
                .foregroundStyle(YimaDesign.Color.muted)
                .accessibilityIdentifier("story-playback-status")
            Slider(value: Binding(get: { min(player.currentTime, player.duration) }, set: { position in perform { try player.seek(to: position) } }),
                   in: 0...max(player.duration, 1))
                .disabled(player.duration <= 0)
                .frame(minHeight: YimaDesign.Layout.hitTarget)
                .accessibilityLabel("播放进度")
                .accessibilityValue("\(spokenTime(player.currentTime))，共\(spokenTime(player.duration))")
            HStack {
                Text(timeLabel(player.currentTime)).accessibilityLabel("已播放\(spokenTime(player.currentTime))")
                Spacer()
                Text(timeLabel(player.duration)).accessibilityLabel("共\(spokenTime(player.duration))")
            }
            .font(YimaDesign.Typography.compactMetadata)
            .monospacedDigit()
            .foregroundStyle(YimaDesign.Color.muted)
            HStack {
                control("后退15秒", symbol: "gobackward.15") { perform { try player.seek(to: max(0, player.currentTime - 15)) } }
                Spacer(minLength: YimaDesign.Space.sm)
                control(hasPlaybackIntent ? "暂停故事" : (hasFinished ? "重新播放" : "继续播放"), symbol: hasPlaybackIntent ? "pause.fill" : "play.fill") { toggle(story) }
                Spacer(minLength: YimaDesign.Space.sm)
                control("前进15秒", symbol: "goforward.15") { perform { try player.seek(to: min(player.duration, player.currentTime + 15)) } }
                Spacer(minLength: YimaDesign.Space.sm)
                control("换一篇", symbol: "forward.end.fill") { perform { try player.next(sourceSessionID: completionSessionID) } }
            }
        }
        .padding(.vertical, YimaDesign.Space.sm)
    }

    private func storyRow(_ story: StoryAudio) -> some View {
        Button { toggle(story) } label: {
            HStack(spacing: YimaDesign.Space.md) {
                Image(systemName: player.currentStoryID == story.id && hasPlaybackIntent ? "pause.fill" : "play.fill")
                    .frame(width: YimaDesign.Layout.hitTarget)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: YimaDesign.Space.xs) {
                    Text(story.title).font(YimaDesign.Typography.itemTitle).lineLimit(2)
                    Text(player.currentStoryID == story.id ? "\(playbackStatus) · \(timeLabel(story.duration))" : timeLabel(story.duration))
                        .font(YimaDesign.Typography.metadata)
                        .foregroundStyle(YimaDesign.Color.muted)
                        .accessibilityLabel(player.currentStoryID == story.id ? "\(playbackStatus)，共\(spokenTime(story.duration))" : spokenTime(story.duration))
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(YimaDesign.Color.ink)
            .frame(minHeight: YimaDesign.Layout.rowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(player.currentStoryID == story.id && hasPlaybackIntent ? "暂停故事" : "播放故事")
        .accessibilityAction(named: Text("删除故事")) { requestDeletion(story) }
        .swipeActions {
            Button("删除", role: .destructive) { requestDeletion(story) }
        }
    }

    private func control(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title2)
                .frame(minWidth: YimaDesign.Layout.hitTarget, minHeight: YimaDesign.Layout.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
    }

    private func toggle(_ story: StoryAudio) {
        perform {
            if player.currentStoryID == story.id {
                if hasPlaybackIntent { player.pause() }
                else if hasFinished { try player.play(story, sourceSessionID: completionSessionID) }
                else { try player.resume(sourceSessionID: completionSessionID) }
            } else { try player.play(story, sourceSessionID: completionSessionID) }
        }
    }

    private func openImporter() {
        AppNavigationCenter.shared.userNavigationBegan()
        showImporter = true
    }

    private func requestDeletion(_ story: StoryAudio) {
        AppNavigationCenter.shared.userNavigationBegan()
        pendingDeletion = story
    }

    private func importAudio(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            var failures: [String] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do { try library.importAudio(from: url) }
                catch { failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
            }
            if !failures.isEmpty { operationError = failures.joined(separator: "\n") }
        } catch { operationError = error.localizedDescription }
    }

    private func remove(_ story: StoryAudio) {
        pendingDeletion = nil
        perform {
            if player.currentStoryID == story.id { player.stop() }
            try library.remove(story.id)
        }
    }

    private func perform(_ action: () throws -> Void) {
        AppNavigationCenter.shared.userNavigationBegan()
        do { try action() }
        catch { operationError = error.localizedDescription }
    }

    private func timeLabel(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func spokenTime(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration))
        return "\(seconds / 60)分\(seconds % 60)秒"
    }
}
