import SwiftUI
import UIKit

/// Detail export menu: consumer txt/srt/audio first, MD/JSON/Codex advanced.
struct ExportDocumentsView: View {
    let title: String
    let relativeJSONPath: String
    let relativeMarkdownPath: String
    let jsonURL: URL?
    let markdownURL: URL?
    let plainTextURL: URL?
    let subtitlesURL: URL?
    let audioURL: URL?
    let plainTextDisabledReason: String?
    let subtitlesDisabledReason: String?
    let audioDisabledReason: String?
    let isMeeting: Bool
    @State private var syncAttention: DocumentSyncAttention?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("导出")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(title.isEmpty ? (isMeeting ? "未命名会议" : "未命名录音") : title)
                        .font(.title3.weight(.semibold))
                    Text("常用格式走系统分享；Markdown / JSON 留给进阶与 Codex。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let syncAttention {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color(red: 1.0, green: 0.62, blue: 0.04))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(syncAttention.title)
                                .font(.subheadline.weight(.semibold))
                            Text(syncAttention.message)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("状态：\(DocumentSyncAttention.needsAttentionState)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("export-sync-needs-attention")
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(red: 1.0, green: 0.96, blue: 0.90), in: RoundedRectangle(cornerRadius: 12))
                }

                consumerExports

                advancedExports
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("导出")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            syncAttention = DocumentSyncStatusCenter.shared.attention
        }
    }

    @ViewBuilder
    private var consumerExports: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("常用导出")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if let plainTextURL, FileManager.default.fileExists(atPath: plainTextURL.path) {
                ShareLink(item: plainTextURL) {
                    Text("导出文本 (.txt)")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(.primary)
                .accessibilityIdentifier("export-txt")
            } else {
                disabledExportButton(
                    "导出文本 (.txt)",
                    reason: plainTextDisabledReason ?? "文本尚不可用"
                )
            }

            if let subtitlesURL, FileManager.default.fileExists(atPath: subtitlesURL.path) {
                ShareLink(item: subtitlesURL) {
                    Text("导出字幕 (.srt)")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.bordered)
                .tint(.primary)
                .accessibilityIdentifier("export-srt")
            } else {
                disabledExportButton(
                    "导出字幕 (.srt)",
                    reason: subtitlesDisabledReason ?? "字幕尚不可用"
                )
            }

            if let audioURL, FileManager.default.fileExists(atPath: audioURL.path) {
                ShareLink(item: audioURL) {
                    Text("分享音频")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.bordered)
                .tint(.primary)
                .accessibilityIdentifier("export-audio")
            } else {
                disabledExportButton(
                    "分享音频",
                    reason: audioDisabledReason ?? "音频尚不可用"
                )
            }

            Text("通过系统分享面板 AirDrop、存储到文件或发到其他 App。导出副本不会改动原始录音。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var advancedExports: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("高级导出 / 给 Codex")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(Color(red: 0, green: 0.48, blue: 1))
                VStack(alignment: .leading, spacing: 4) {
                    Text("文档仍保存在本机")
                        .font(.subheadline.weight(.semibold))
                    Text("iCloud 不可用不会影响本地导出。可在“文件”App 的“我的 iPhone”中查看 VoiceContext。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(red: 0.94, green: 0.96, blue: 1.0), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 8) {
                pathRow(label: "Markdown", path: relativeMarkdownPath)
                pathRow(label: "JSON", path: relativeJSONPath)
            }

            if let markdownURL, FileManager.default.fileExists(atPath: markdownURL.path) {
                ShareLink(item: markdownURL) {
                    Text("导出 transcript.md")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.bordered)
                .tint(.primary)
                .accessibilityIdentifier("export-markdown")
            } else {
                disabledExportButton("导出 transcript.md", reason: "文件尚不可用")
            }

            if let jsonURL, FileManager.default.fileExists(atPath: jsonURL.path) {
                ShareLink(item: jsonURL) {
                    Text("导出 transcript.json")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.bordered)
                .tint(.primary)
                .accessibilityIdentifier("export-json")
            } else {
                disabledExportButton("导出 transcript.json", reason: "文件尚不可用")
            }

            if isMeeting {
                Text("会议目录已写入本地 Meetings；Codex Skill 只读取 complete 会议文档，并写入 generated/ 派生纪要。可在设置中导出 VoiceContext Skill 包。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("需要 Codex / Skill 时，可在设置中导出 VoiceContext 包。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func pathRow(label: String, path: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(path)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private func disabledExportButton(_ title: String, reason: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 50)
                .foregroundStyle(.secondary)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("\(title)，\(reason)")
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("export-disabled-reason")
        }
    }
}

struct ExportDocumentsDestination: View {
    let model: RecordingCoreModel
    let recordingID: UUID

    @State private var package: PublicExportPackage?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let package {
                ExportDocumentsView(
                    title: package.title,
                    relativeJSONPath: package.relativeJSONPath,
                    relativeMarkdownPath: package.relativeMarkdownPath,
                    jsonURL: package.jsonURL,
                    markdownURL: package.markdownURL,
                    plainTextURL: package.plainTextURL,
                    subtitlesURL: package.subtitlesURL,
                    audioURL: package.audioURL,
                    plainTextDisabledReason: package.plainTextDisabledReason,
                    subtitlesDisabledReason: package.subtitlesDisabledReason,
                    audioDisabledReason: package.audioDisabledReason,
                    isMeeting: package.isMeeting
                )
            } else if let errorMessage {
                ContentUnavailableView(
                    "无法准备导出",
                    systemImage: "square.and.arrow.up",
                    description: Text(errorMessage)
                )
            } else {
                ProgressView("正在准备本地文档…")
            }
        }
        .task(id: recordingID) {
            do {
                package = try await model.exportPackage(recordingID: recordingID)
                errorMessage = nil
            } catch {
                package = nil
                errorMessage = error.localizedDescription
            }
        }
    }
}
