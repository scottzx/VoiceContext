import SwiftUI
import QuickLook

struct RecordingAgentResults: View {
    let recordingID: String
    @Environment(\.dismiss) private var dismiss
    @State private var files: [URL] = []
    @State private var error: String?
    @State private var preview: GeneratedFile?

    var body: some View {
        NavigationStack {
            Group {
                if let error {
                    ContentUnavailableView("无法读取产物", systemImage: "exclamationmark.triangle", description: Text(error))
                } else if files.isEmpty {
                    ContentUnavailableView("暂无智能体产物", systemImage: "doc.text", description: Text("将这份录音交给智能体整理后，可在这里查看它保存的结果。"))
                } else {
                    List(files, id: \.self) { file in
                        Button { preview = GeneratedFile(url: file) } label: {
                            Label(file.lastPathComponent, systemImage: "doc.text").foregroundStyle(.primary)
                        }
                    }
                    .refreshable { await load() }
                }
            }
            .navigationTitle("智能体产物")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .sheet(item: $preview) { item in GeneratedFilePreview(url: item.url) }
            .task { await load() }
        }
    }

    private func load() async {
        let root = AIChatViewModel.minisSharedPersistentDir.resolvingSymlinksInPath()
            .appendingPathComponent("VoiceContext/Generated/\(recordingID)")
        let result = await Task.detached(priority: .utility) { () -> Result<[URL], Error> in
            do {
                guard root.resolvingSymlinksInPath() == root.standardizedFileURL else {
                    throw CocoaError(.fileReadInvalidFileName)
                }
                guard FileManager.default.fileExists(atPath: root.path) else { return .success([]) }
                var found: [URL] = []
                guard let enumerator = FileManager.default.enumerator(at: root,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else {
                    throw CocoaError(.fileReadNoPermission)
                }
                for case let file as URL in enumerator {
                    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isSymbolicLink != true, values.isRegularFile == true,
                          file.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { continue }
                    found.append(file)
                }
                return .success(found.sorted { $0.path < $1.path })
            } catch { return .failure(error) }
        }.value
        switch result {
        case .success(let items): files = items; error = nil
        case .failure(let failure): error = failure.localizedDescription
        }
    }
}

private struct GeneratedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct GeneratedFilePreview: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
