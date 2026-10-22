import SwiftUI

struct DSHServiceSettingsView: View {
    @ObservedObject private var store = DSHServiceStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showingAdd = false
    @State private var editingService: DSHService?
    @State private var deletingService: DSHService?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let readError = store.readError {
                        Text(readError).foregroundStyle(YimaDesign.Color.muted)
                    } else if store.services.isEmpty {
                        Text("尚未添加远程服务。")
                            .foregroundStyle(YimaDesign.Color.muted)
                    }
                    ForEach(store.services) { service in
                        Button { editingService = service } label: {
                            HStack(spacing: YimaDesign.Space.md) {
                                VStack(alignment: .leading, spacing: YimaDesign.Space.xs) {
                                    Text(service.name).font(YimaDesign.Typography.itemTitle)
                                        .foregroundStyle(YimaDesign.Color.ink)
                                    Text(service.url.absoluteString)
                                        .font(YimaDesign.Typography.compactMetadata)
                                        .foregroundStyle(YimaDesign.Color.muted)
                                        .lineLimit(2)
                                }
                                Spacer(minLength: YimaDesign.Space.sm)
                                Image(systemName: "chevron.right")
                                    .font(.caption).foregroundStyle(YimaDesign.Color.muted)
                                    .accessibilityHidden(true)
                            }
                            .frame(minHeight: YimaDesign.Layout.hitTarget)
                            .contentShape(Rectangle())
                        }
                        .accessibilityHint("编辑服务地址和连接令牌")
                        .swipeActions {
                            Button("移除", role: .destructive) { deletingService = service }
                        }
                    }
                    Button { showingAdd = true } label: {
                        Label("添加远程服务", systemImage: "plus")
                            .frame(minHeight: YimaDesign.Layout.hitTarget)
                    }
                    .disabled(!store.available)
                } header: {
                    Text("DSH 服务")
                } footer: {
                    Text("在聊天页顶部切换本机与远程服务。远程会话的执行和工具由所选电脑处理。")
                }
                Section {
                    Text("请先在 iPhone 和远程电脑上连接同一 Tailscale 网络，并确保电脑上的 DSH 服务可通过 Tailscale 地址访问。")
                    Text("服务地址填写 Tailscale IP 或域名及端口。localhost 指向 iPhone 本机。")
                } header: {
                    Text("Tailscale 连接")
                } footer: {
                    Text("本功能不创建公网隧道。连接令牌和登录凭据保存在这台 iPhone 的钥匙串中。")
                }
            }
            .navigationTitle(AppLocalized("远程聊天服务"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .sheet(isPresented: $showingAdd) { DSHServiceEditor(store: store) }
            .sheet(item: $editingService) { DSHServiceEditor(store: store, service: $0) }
            .alert("移除远程服务？", isPresented: Binding(
                get: { deletingService != nil }, set: { if !$0 { deletingService = nil } }
            )) {
                Button("取消", role: .cancel) { deletingService = nil }
                Button("移除", role: .destructive) { removeService() }
            } message: {
                Text("将移除这台 iPhone 上的连接设置与凭据，远程电脑上的会话仍会保留。")
            }
            .alert("无法移除服务", isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } }
            )) {
                Button("好", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
        .tint(YimaDesign.Color.ink)
        .appFontScale()
    }

    private func removeService() {
        guard let service = deletingService else { return }
        deletingService = nil
        do { try store.remove(id: service.id) }
        catch { self.error = error.localizedDescription }
    }
}

private struct DSHServiceEditor: View {
    @ObservedObject var store: DSHServiceStore
    let service: DSHService?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var address: String
    @State private var token = ""
    @State private var isTesting = false
    @State private var connectionStatus: String?
    @State private var testTask: Task<Void, Never>?
    @State private var error: String?

    init(store: DSHServiceStore, service: DSHService? = nil) {
        self.store = store
        self.service = service
        _name = State(initialValue: service?.name ?? "")
        _address = State(initialValue: service?.url.absoluteString ?? "")
    }

    private var validatedURL: URL? { try? DSHService.validatedURL(address) }

    private var addressError: String? {
        guard !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do { _ = try DSHService.validatedURL(address); return nil }
        catch { return error.localizedDescription }
    }

    private var credential: String? {
        let entered = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !entered.isEmpty { return entered }
        guard let service, service.url == validatedURL else { return nil }
        return store.token(for: service.id, matching: service.url)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称", text: $name)
                    TextField("服务地址", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityHint("填写远程电脑的 Tailscale IP 或域名，可包含端口")
                } footer: {
                    VStack(alignment: .leading, spacing: YimaDesign.Space.sm) {
                        Text("仅填写 http:// 或 https:// 服务地址和端口，不要粘贴含连接令牌的完整启动链接。")
                        if let addressError {
                            Text(addressError).foregroundStyle(YimaDesign.Color.warningText)
                        }
                    }
                }
                .disabled(isTesting)

                Section {
                    SecureField(service == nil ? AppLocalized("连接令牌") : AppLocalized("新的连接令牌（留空保留）"), text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()
                        .accessibilityLabel("连接令牌")
                } footer: {
                    Text("填写 DSH 服务提供的连接令牌。更换服务地址时需要重新填写，令牌仅保存在钥匙串中。")
                }
                .disabled(isTesting)

                Section {
                    Button(action: testConnection) {
                        HStack(spacing: YimaDesign.Space.sm) {
                            if isTesting { ProgressView().accessibilityHidden(true) }
                            Text(isTesting ? AppLocalized("正在连接…") : AppLocalized("测试连接"))
                        }
                        .frame(minHeight: YimaDesign.Layout.hitTarget)
                    }
                    .disabled(isTesting || validatedURL == nil || credential == nil)
                    .accessibilityHint("连接服务并读取会话列表，不发送聊天消息")
                    if let connectionStatus {
                        Text(connectionStatus)
                            .font(YimaDesign.Typography.metadata)
                            .foregroundStyle(YimaDesign.Color.muted)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                } footer: {
                    Text("测试连接会验证登录并读取会话列表，不会发送消息或启动远程任务。")
                }
            }
            .navigationTitle(AppLocalized(service == nil ? "添加远程服务" : "编辑远程服务"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(isTesting || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || validatedURL == nil || credential == nil)
                }
            }
            .onChange(of: address) { _, _ in connectionStatus = nil }
            .onChange(of: token) { _, _ in connectionStatus = nil }
            .onDisappear { testTask?.cancel() }
            .alert("无法保存或连接", isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } }
            )) {
                Button("好", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
        .tint(YimaDesign.Color.ink)
        .appFontScale()
    }

    private func save() {
        do {
            let url = try DSHService.validatedURL(address)
            let entered = token.trimmingCharacters(in: .whitespacesAndNewlines)
            try store.save(service: DSHService(id: service?.id ?? UUID(), name: name, url: url),
                           token: entered.isEmpty ? nil : entered)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func testConnection() {
        guard let url = validatedURL, let credential else { return }
        let useSavedCookie = token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        isTesting = true
        connectionStatus = nil
        testTask = Task { @MainActor in
            let client = DSHClient(baseURL: url, token: credential,
                                   cookieLoader: { useSavedCookie ? DSHCookieCredentialStore.cookie(for: $0) : nil },
                                   cookieSaver: { _, _ in })
            defer { client.disconnect(); isTesting = false }
            do {
                try await client.connect()
                try Task.checkCancellation()
                let sessions = try await client.listSessions()
                try Task.checkCancellation()
                connectionStatus = AppLocalized("连接成功，可读取 \(sessions.count) 个会话。")
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }
}
