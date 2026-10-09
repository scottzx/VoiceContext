import SwiftUI

/// Shared by recording settings and the local chat voice entry point.
public struct TranscriptionModelDownloadView: View {
    @ObservedObject private var download = TranscriptionModelDownloadService.shared
    @State private var allowCellular = false

    public init() {}

    public var body: some View {
        List {
            Section {
                TranscriptionModelStatusBanner()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            if download.state != .ready {
                Section {
                    if isActive {
                        Button("取消下载", role: .cancel) { download.cancelDownload() }
                            .frame(minHeight: 44)
                    } else {
                        Toggle("允许使用蜂窝网络", isOn: $allowCellular)
                        Text("默认仅使用 Wi-Fi。使用蜂窝网络会消耗流量。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button {
                            download.startDownload(allowCellular: allowCellular)
                        } label: {
                            Text(download.state == .failed ? "重试下载" : "下载模型")
                                .font(YimaDesign.Typography.metadata.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: YimaDesign.Layout.primaryHeight)
                                .foregroundStyle(YimaDesign.Color.canvas)
                                .background(YimaDesign.Color.ink, in: RoundedRectangle(cornerRadius: YimaDesign.Radius.control))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("transcription-model-download")
                    }
                }
            }

            Section {
                LabeledContent("下载大小", value: byteCount(download.totalBytes))
                Link("模型来源：魔搭", destination: URL(string: "https://modelscope.cn/models/scott887/SenseVoiceSmall-Q8_0.gguf")!)
                    .tint(.blue)
            }

            Section {
                Text("下载期间可离开此页，系统会在后台继续传输。强制退出 App 可能中断下载，重新打开后可继续。")
                Text("音频、文稿和声纹保留在本机，模型下载不会上传这些内容。")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .navigationTitle("语音转文字模型")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .tint(YimaDesign.Color.ink)
    }

    private var isActive: Bool {
        download.state == .waiting || download.state == .downloading || download.state == .verifying
    }

    private func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)
    }
}

/// The same status and progress appear at the point of use and on the download page.
struct TranscriptionModelStatusBanner: View {
    @ObservedObject private var download = TranscriptionModelDownloadService.shared
    var openDownload: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: YimaDesign.Space.md) {
            HStack(alignment: .top, spacing: YimaDesign.Space.sm) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(needsAttention ? YimaDesign.Color.warningText : YimaDesign.Color.ink)
                    .accessibilityHidden(true)
                Text(LocalizedStringKey(title))
                    .font(YimaDesign.Typography.section)
                    .foregroundStyle(YimaDesign.Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("transcription-model-status")
            }

            Text(message)
                .font(YimaDesign.Typography.metadata)
                .foregroundStyle(YimaDesign.Color.muted)
                .fixedSize(horizontal: false, vertical: true)

            if download.state == .downloading || download.state == .waiting {
                VStack(alignment: .leading, spacing: YimaDesign.Space.xs) {
                    ProgressView(value: Double(download.downloadedBytes), total: Double(max(1, download.totalBytes)))
                        .tint(YimaDesign.Color.ink)
                        .accessibilityLabel("模型下载进度")
                    Text("\(byteCount(download.downloadedBytes)) / \(byteCount(download.totalBytes))")
                        .font(YimaDesign.Typography.compactMetadata)
                        .monospacedDigit()
                        .foregroundStyle(YimaDesign.Color.muted)
                }
            } else if download.state == .verifying {
                ProgressView("正在校验模型文件…")
                    .font(YimaDesign.Typography.metadata)
                    .tint(YimaDesign.Color.ink)
            }

            if download.state == .failed, let error = download.errorMessage {
                Text(error)
                    .font(YimaDesign.Typography.metadata)
                    .foregroundStyle(YimaDesign.Color.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let openDownload, download.state != .ready {
                Button(action: openDownload) {
                    Text(LocalizedStringKey(actionTitle))
                        .font(YimaDesign.Typography.metadata.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: YimaDesign.Layout.primaryHeight)
                        .foregroundStyle(YimaDesign.Color.canvas)
                        .background(YimaDesign.Color.ink, in: RoundedRectangle(cornerRadius: YimaDesign.Radius.control))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("transcription-model-open-download")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(YimaDesign.Space.lg)
        .background(YimaDesign.Color.grouped, in: RoundedRectangle(cornerRadius: YimaDesign.Radius.control))
        .overlay {
            RoundedRectangle(cornerRadius: YimaDesign.Radius.control)
                .strokeBorder(YimaDesign.Color.line, lineWidth: 0.5)
        }
    }

    private var needsAttention: Bool {
        download.state == .notDownloaded || download.state == .failed
    }

    private var title: String {
        switch download.state {
        case .notDownloaded: "下载模型，开启免费转写"
        case .waiting: "模型正在等待下载"
        case .downloading: "正在下载转写模型"
        case .verifying: "正在检查模型文件"
        case .ready: "模型已就绪"
        case .failed: "模型下载未完成"
        }
    }

    private var message: String {
        switch download.state {
        case .notDownloaded:
            String(format: L("首次下载 %@，之后可离线转写。录音和已有文稿仍可使用。"), byteCount(download.totalBytes))
        case .waiting:
            L("正在等待网络或系统调度，可离开此页。录音和已有文稿仍可使用。")
        case .downloading:
            L("下载期间可继续录音、回听或查看已有文稿。")
        case .verifying:
            L("正在检查本机文件，检查通过后可离线转写。")
        case .ready:
            L("可以离线转写，无需重复下载。")
        case .failed:
            L("已下载的模型会保留，请重试补齐剩余文件。")
        }
    }

    private var actionTitle: String {
        switch download.state {
        case .notDownloaded: "前往下载"
        case .failed: "查看并重试下载"
        default: "查看下载进度"
        }
    }

    private var symbol: String {
        switch download.state {
        case .notDownloaded, .downloading: "arrow.down.circle"
        case .waiting: "clock"
        case .verifying: "checkmark.shield"
        case .ready: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)
    }
}

struct TranscriptionModelDownloadSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TranscriptionModelDownloadView()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                    }
                }
        }
    }
}
