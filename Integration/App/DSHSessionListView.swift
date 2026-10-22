import SwiftUI

@MainActor
private final class DSHSessionListModel: ObservableObject {
    @Published private(set) var sessions: [DSHSessionSummary] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var searchResults: [String: String]?
    @Published private(set) var searchError: String?
    private var client: DSHClient?
    private let service: DSHService
    private var generation = UUID()
    private var activeQuery = ""

    init(service: DSHService) { self.service = service }

    func refresh() async {
        guard !isLoading else { return }
        let run = generation
        isLoading = true
        defer { if generation == run { isLoading = false } }
        do {
            if client == nil {
                guard DSHServiceStore.shared.services.contains(where: { $0.id == service.id && $0.url == service.url }) else {
                    throw DSHServiceError.missingService
                }
                let connection = DSHClient(baseURL: service.url, token: DSHServiceStore.shared.token(for: service.id, matching: service.url) ?? "")
                client = connection
                try await connection.connect()
                guard generation == run, !Task.isCancelled else { connection.disconnect(); return }
            }
            guard let client else { return }
            let result = try await client.listSessions()
            guard generation == run, !Task.isCancelled else { return }
            sessions = result.sorted { $0.updatedAt > $1.updatedAt }
            error = nil
            if !activeQuery.isEmpty { await search(activeQuery) }
        } catch {
            guard generation == run, !Task.isCancelled else { return }
            self.error = error.localizedDescription
            client?.disconnect()
            client = nil
        }
    }

    func search(_ text: String) async {
        activeQuery = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = activeQuery
        guard !query.isEmpty else { searchResults = nil; searchError = nil; return }
        guard let client else { return }
        let run = generation
        do {
            let matches = try await client.searchSessions(query: query)
            guard run == generation, query == activeQuery, !Task.isCancelled else { return }
            searchResults = Dictionary(matches.map { ($0.id, $0.snippet) }, uniquingKeysWith: { first, _ in first })
            searchError = nil
        } catch {
            guard run == generation, query == activeQuery, !Task.isCancelled else { return }
            searchResults = nil
            searchError = AppLocalized("远程全文搜索暂不可用，当前仅匹配会话标题和目录。")
        }
    }

    func disconnect() {
        generation = UUID()
        client?.disconnect()
        client = nil
        isLoading = false
    }
}

/// Uses the same native list/search/navigation pattern as local conversations.
struct DSHSessionListView: View {
    let service: DSHService
    let onOpen: (DSHSessionSummary) -> Void
    let onManage: () -> Void
    @StateObject private var model: DSHSessionListModel
    @State private var query = ""
    @State private var isVisible = false
    @FocusState private var searchFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    init(service: DSHService, onOpen: @escaping (DSHSessionSummary) -> Void, onManage: @escaping () -> Void) {
        self.service = service
        self.onOpen = onOpen
        self.onManage = onManage
        _model = StateObject(wrappedValue: DSHSessionListModel(service: service))
    }

    private var filtered: [DSHSessionSummary] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return model.sessions }
        return model.sessions.filter {
            $0.title.localizedStandardContains(text) || ($0.cwd?.localizedStandardContains(text) ?? false)
                || model.searchResults?[$0.id] != nil
        }
    }

    var body: some View {
        List {
            if let error = model.error {
                Section {
                    Text(error).foregroundStyle(.secondary)
                    Button("重试") { Task { await model.refresh() } }
                    Button("管理远程服务", action: onManage)
                } header: { Text("无法连接远程服务") }
            }
            if let warning = model.searchError, !query.isEmpty {
                Text(warning).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(filtered) { session in
                Button {
                    searchFocused = false
                    onOpen(session)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .foregroundStyle(.secondary)
                            .frame(width: 32)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.title.isEmpty ? AppLocalized("新会话") : session.title)
                                .font(.headline).foregroundStyle(.primary).lineLimit(2)
                            if let snippet = model.searchResults?[session.id], !query.isEmpty {
                                Text(snippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            }
                            if let cwd = session.cwd, !cwd.isEmpty {
                                Text(cwd).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                            HStack {
                                Text(session.updatedAt, style: .date)
                                Spacer()
                                if session.isRunning { Text("执行中") }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .frame(minHeight: 60)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .overlay {
            if model.isLoading, model.sessions.isEmpty { ProgressView("正在连接远程服务…") }
            else if model.error == nil, filtered.isEmpty {
                Text(query.isEmpty ? AppLocalized("还没有远程会话，点击右上角新建。") : AppLocalized("没有匹配的会话。"))
                    .font(.subheadline).foregroundStyle(.secondary).padding(24)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { searchBar }
        .refreshable { await model.refresh() }
        .tint(YimaDesign.Color.ink)
        .appFontScale()
        .background {
            Button { searchFocused = true } label: { EmptyView() }
                .keyboardShortcut("f", modifiers: .command).opacity(0).accessibilityHidden(true)
        }
        .navigationBarTitleDisplayMode(.inline)
        .task(id: isVisible && scenePhase == .active) {
            guard isVisible, scenePhase == .active else { model.disconnect(); return }
            await model.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { break }
                guard !Task.isCancelled else { break }
                await model.refresh()
            }
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false; model.disconnect() }
        .task(id: query) {
            do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
            await model.search(query)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("Yima.dshSessionDidCreate"))) { notification in
            guard notification.userInfo?["serviceID"] as? String == service.id.uuidString else { return }
            Task { await model.refresh() }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索远程会话", text: $query)
                .textFieldStyle(.plain).frame(minHeight: 44)
                .autocorrectionDisabled().focused($searchFocused).submitLabel(.search)
                .onSubmit { searchFocused = false }
                .accessibilityLabel("搜索远程会话")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("清除搜索")
            }
        }
        .padding(.leading, 12).padding(.trailing, query.isEmpty ? 12 : 0)
        .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color(UIColor.systemBackground))
    }
}
