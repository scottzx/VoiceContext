import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import ImageIO
import WebKit

struct CustomExtensionBrowserView: View {
    let item: CustomExtensionItem
    @StateObject private var pool = BrowserTabPool()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let manager = pool.activeManager {
                    ZStack {
                        BrowserWebView(manager: manager)
                        BrowserLoadErrorOverlay(manager: manager)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: YimaDesign.Space.md) {
                        Text("浏览器暂不可用，请关闭部分标签页后重试。")
                            .foregroundStyle(YimaDesign.Color.muted)
                        Button("重试", action: open)
                            .frame(minHeight: YimaDesign.Layout.hitTarget)
                    }
                    .padding(YimaDesign.Layout.pageInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(YimaDesign.Color.canvas)
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Label("Back", systemImage: "chevron.left")
                            .frame(minHeight: YimaDesign.Layout.hitTarget)
                    }
                }
            }
            .onAppear(perform: open)
            .onDisappear {
                for tab in pool.tabs {
                    tab.manager.stopLoading()
                    tab.manager.webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)
                    tab.manager.webView.setMicrophoneCaptureState(.none, completionHandler: nil)
                    tab.manager.webView.setCameraCaptureState(.none, completionHandler: nil)
                    _ = pool.closeTab(id: tab.id)
                }
            }
        }
        .tint(YimaDesign.Color.ink)
    }

    private func open() {
        guard pool.tabs.isEmpty, pool.newTab().success, let manager = pool.activeManager else { return }
        // Keep new-window links on this page, without creating hidden tabs.
        manager.newWindowHandler = nil
        manager.closeHandler = { [dismiss] _ in dismiss() }
        manager.webView.allowsBackForwardNavigationGestures = false
        manager.loadURL(item.url.absoluteString)
    }
}

struct CustomExtensionIcon: View {
    let name: String
    let logoData: Data?

    var body: some View {
        if let logoData, let image = UIImage(data: logoData) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
        } else {
            Text(name.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? "?")
                .font(.title2.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.3)
                .foregroundStyle(YimaDesign.Color.ink)
        }
    }
}

struct CustomExtensionEditor: View {
    @ObservedObject var store: CustomExtensionsStore
    let item: CustomExtensionItem?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var address: String
    @State private var logoData: Data?
    @State private var photo: PhotosPickerItem?
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var loadingLogo = false
    @State private var error: String?

    init(store: CustomExtensionsStore, item: CustomExtensionItem? = nil) {
        self.store = store
        self.item = item
        _name = State(initialValue: item?.name ?? "")
        _address = State(initialValue: item?.url.absoluteString ?? "")
        _logoData = State(initialValue: item?.logoData)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称", text: $name)
                    TextField("URL", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("填写完整的 http:// 或 https:// 地址，可包含端口和路径。电脑上的服务请使用电脑的局域网或 Tailscale 地址；localhost 指 iPhone 本机。")
                }
                Section {
                    HStack(spacing: YimaDesign.Space.md) {
                        CustomExtensionIcon(name: name, logoData: logoData)
                            .frame(width: 52, height: 52)
                            .background(YimaDesign.Color.grouped, in: RoundedRectangle(cornerRadius: YimaDesign.Radius.control))
                            .clipShape(RoundedRectangle(cornerRadius: YimaDesign.Radius.control))
                            .accessibilityHidden(true)
                        Menu {
                            Button("选择照片", systemImage: "photo") { showPhotos = true }
                            Button("选择文件", systemImage: "folder") { showFiles = true }
                            if logoData != nil {
                                Button("移除 Logo", role: .destructive) { logoData = nil; photo = nil }
                            }
                        } label: {
                            Label("选择 Logo", systemImage: "photo.badge.plus")
                                .frame(minHeight: YimaDesign.Layout.hitTarget)
                        }
                        .disabled(loadingLogo)
                        if loadingLogo { ProgressView().accessibilityLabel("正在读取图片") }
                    }
                } header: {
                    Text("Logo（可选）")
                } footer: {
                    Text("没有 Logo 时，显示名称的首字或首字母。")
                }
            }
            .navigationTitle(AppLocalized(item == nil ? "添加自定义功能" : "编辑自定义功能"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || (try? CustomExtensionItem.validatedURL(address)) == nil || loadingLogo)
                }
            }
            .photosPicker(isPresented: $showPhotos, selection: $photo, matching: .images)
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image]) { result in
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    try applyLogo(Data(contentsOf: url))
                } catch { self.error = error.localizedDescription }
            }
            .task(id: photo) {
                guard let photo else { return }
                loadingLogo = true
                defer { loadingLogo = false; self.photo = nil }
                do {
                    guard let data = try await photo.loadTransferable(type: Data.self) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    try Task.checkCancellation()
                    try applyLogo(data)
                } catch is CancellationError {
                } catch { self.error = error.localizedDescription }
            }
            .alert("无法保存或读取", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    private func applyLogo(_ data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 256
              ] as CFDictionary),
              let thumbnail = UIImage(cgImage: image).pngData() else {
            throw CocoaError(.fileReadCorruptFile)
        }
        logoData = thumbnail
    }

    private func save() {
        do {
            let url = try CustomExtensionItem.validatedURL(address)
            if var item {
                item.name = name
                item.url = url
                item.logoData = logoData
                try store.update(item, expected: self.item)
            } else {
                _ = try store.add(name: name, url: url, logoData: logoData)
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct CustomExtensionsManagementView: View {
    @ObservedObject var store: CustomExtensionsStore
    @Environment(\.dismiss) private var dismiss
    @State private var editingItem: CustomExtensionItem?
    @State private var deletingItem: CustomExtensionItem?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                ForEach(store.items) { item in
                    Button { editingItem = item } label: {
                        HStack(spacing: YimaDesign.Space.md) {
                            CustomExtensionIcon(name: item.name, logoData: item.logoData)
                                .frame(width: 44, height: 44)
                                .background(YimaDesign.Color.grouped, in: RoundedRectangle(cornerRadius: YimaDesign.Radius.control))
                                .clipShape(RoundedRectangle(cornerRadius: YimaDesign.Radius.control))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: YimaDesign.Space.xs) {
                                Text(item.name).font(YimaDesign.Typography.itemTitle)
                                Text(item.url.absoluteString)
                                    .font(YimaDesign.Typography.compactMetadata)
                                    .foregroundStyle(YimaDesign.Color.muted)
                            }
                        }
                        .frame(minHeight: YimaDesign.Layout.hitTarget)
                        .foregroundStyle(YimaDesign.Color.ink)
                    }
                    .accessibilityHint("编辑名称、URL 和 Logo")
                    .accessibilityAction(named: Text("上移")) { move(item, by: -1) }
                    .accessibilityAction(named: Text("下移")) { move(item, by: 1) }
                    .accessibilityAction(named: Text("删除")) { deletingItem = item }
                }
                .onMove { offsets, destination in
                    do { try store.move(fromOffsets: offsets, toOffset: destination) }
                    catch { self.error = error.localizedDescription }
                }
                .onDelete { offsets in
                    if let index = offsets.first { deletingItem = store.items[index] }
                }
            } footer: {
                Text(AppLocalized(store.items.isEmpty ? "还没有自定义功能。返回拓展页面添加。" : "拖动右侧手柄调整顺序，点按名称可编辑。"))
            }
        }
        .environment(\.editMode, .constant(.active))
        .listStyle(.plain)
        .navigationTitle("调整自定义功能")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        .sheet(item: $editingItem) { CustomExtensionEditor(store: store, item: $0) }
        .alert("删除自定义功能？", isPresented: Binding(get: { deletingItem != nil }, set: { if !$0 { deletingItem = nil } })) {
            Button("取消", role: .cancel) { deletingItem = nil }
            Button("删除", role: .destructive) {
                guard let deletingItem else { return }
                do { try store.delete(id: deletingItem.id) }
                catch { self.error = error.localizedDescription }
                self.deletingItem = nil
            }
        } message: {
            Text("只移除这里的入口，不会删除对应产品或服务。")
        }
        .alert("无法保存调整", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func move(_ item: CustomExtensionItem, by offset: Int) {
        guard let index = store.items.firstIndex(where: { $0.id == item.id }),
              store.items.indices.contains(index + offset) else { return }
        do { try store.move(fromOffsets: IndexSet(integer: index), toOffset: offset < 0 ? index - 1 : index + 2) }
        catch { self.error = error.localizedDescription }
    }
}
