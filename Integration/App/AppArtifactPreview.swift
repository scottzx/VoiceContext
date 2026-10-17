import SwiftUI
import Charts
import ImageIO

/// A regular app content preview, shared by chat and voice navigation.
struct AppArtifactPreview: View {
    let artifact: AppArtifact
    let commandID: UUID?
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var navigation = AppNavigationCenter.shared
    @State private var image: UIImage?
    @State private var htmlURL: URL?
    @State private var error: String?
    @State private var appeared = false
    @State private var ready = false
    @State private var chartKind = "bar"

    var body: some View {
        NavigationStack {
            Group {
                if let error {
                    ContentUnavailableView("内容暂不可用", systemImage: "exclamationmark.triangle", description: Text(error))
                } else if artifact.kind == .html {
                    if let file = htmlURL {
                        AppArtifactHTMLView(fileURL: file, onReady: contentReady, onError: failed)
                    } else { ProgressView() }
                } else if artifact.kind == .image {
                    if let image {
                        ImagePreviewContent(image: image, onDismiss: { dismiss() })
                            .accessibilityLabel(artifact.title)
                            .onAppear(perform: contentReady)
                    } else { ProgressView() }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: YimaDesign.Layout.sectionGap) {
                            if let text = artifact.text {
                                Text(text).font(YimaDesign.Typography.body).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if let plot = artifact.chart { chart(plot) }
                        }
                        .padding(YimaDesign.Layout.pageInset)
                    }
                    .onAppear(perform: contentReady)
                }
            }
            .background(YimaDesign.Color.canvas)
            .navigationTitle(artifact.title)
            .navigationBarTitleDisplayMode(.inline)
            .tint(YimaDesign.Color.ink)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("返回", systemImage: "chevron.left") { navigation.userNavigationBegan(); dismiss() }
                }
            }
            .offloadPermissionDialog()
        }
        .onAppear {
            appeared = true
            if let source = navigation.state.routeID, source != "artifact.preview" {
                navigation.unmount(routeID: source, params: navigation.state.params)
            }
            chartKind = artifact.chart?.kind ?? "bar"
            if artifact.kind == .image { loadImage() }
            if artifact.kind == .html {
                do { htmlURL = try AppArtifactStore.shared.fileURL(for: artifact) }
                catch { failed(error.localizedDescription) }
            }
            if ready { mount() }
        }
        .onDisappear {
            appeared = false
            navigation.unmount(routeID: "artifact.preview", params: ["artifact_id": artifact.id])
        }
        .onChange(of: navigation.command) { _, command in
            guard appeared, let command, navigation.isCurrent(command) else { return }
            if command.action == .navigate, command.routeID == "artifact.preview", command.params["artifact_id"] == artifact.id, ready {
                mount()
            } else if command.action == .back, navigation.state.routeID == "artifact.preview", navigation.state.params["artifact_id"] == artifact.id {
                dismiss()
            }
        }
    }

    @ViewBuilder private func chart(_ plot: AppArtifact.Plot) -> some View {
        Picker("图表类型", selection: $chartKind) {
            Text("柱状图").tag("bar")
            Text("折线图").tag("line")
        }.pickerStyle(.segmented)
        Text(plot.unit).font(YimaDesign.Typography.metadata).foregroundStyle(YimaDesign.Color.muted)
        Chart(plot.points) { point in
            if chartKind == "line" {
                LineMark(x: .value("项目", point.label), y: .value(plot.unit, point.value))
                    .foregroundStyle(YimaDesign.Color.ink).symbol(.circle)
            } else {
                BarMark(x: .value("项目", point.label), y: .value(plot.unit, point.value))
                    .foregroundStyle(YimaDesign.Color.ink)
            }
        }
        .frame(minHeight: 240)
        .accessibilityLabel(artifact.title)
        DisclosureGroup("查看数据与来源") {
            Text(plot.source).font(YimaDesign.Typography.metadata).foregroundStyle(YimaDesign.Color.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(plot.points) { point in
                LabeledContent(point.label, value: "\(point.value.formatted()) \(plot.unit)")
                    .font(YimaDesign.Typography.body)
                    .frame(minHeight: YimaDesign.Layout.hitTarget)
            }
        }
    }

    private func loadImage() {
        do {
            let url = try AppArtifactStore.shared.fileURL(for: artifact)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 4_096,
                    kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary) else { throw AppArtifactError.invalid("无法解码图片。") }
            image = UIImage(cgImage: thumbnail)
        } catch { failed(error.localizedDescription) }
    }

    private func contentReady() { ready = true; if appeared { mount() } }
    private func mount() {
        navigation.mount(routeID: "artifact.preview", params: ["artifact_id": artifact.id], canGoBack: true,
                         commandID: navigation.command?.id == commandID ? commandID : nil)
    }
    private func failed(_ message: String) {
        error = message
        if let commandID { navigation.fail(commandID: commandID, message: message) }
    }
}
