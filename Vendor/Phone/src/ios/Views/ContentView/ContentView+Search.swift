//
//  ContentView+Search.swift
//  Minis - home screen (session list, navigation, settings entry)
//
//  ContentView, search: debounced session search (titles, then message
//  content), dismissing it, and focusing the field (Cmd-F).
//
//  Map of the ContentView files: ContentView/ContentView.swift.
//

import SwiftUI

extension ContentView {
    // MARK: - Search Bar

    func scheduleSearch() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            searchMatchedIds = nil
            searchMatchSnippets = [:]
            searchMatchedFolderIds = []
            searchFolderPages = [:]
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms debounce
            guard !Task.isCancelled else { return }
            let results = await ChatStore.shared.searchSessions(query: query)
            if !Task.isCancelled {
                // [T-search-folder-expand] A folder whose name matches brings
                // all its members along — the folder is the reason they match.
                // [T-search-multi-keyword] ... for any of the keywords, the
                // same OR rule the sessions are matched by.
                let terms = SearchKeywords.terms(query)
                let folderHits = Set(folders.filter {
                    SearchKeywords.firstHit(in: $0.name, terms: terms) != nil
                }.map(\.id))
                var ids = Set(results.map(\.session.id))
                if !folderHits.isEmpty {
                    ids.formUnion(sessions.filter { $0.folderId.map(folderHits.contains) == true }.map(\.id))
                }
                searchMatchedFolderIds = folderHits
                searchFolderPages = [:]
                searchMatchedIds = ids
                // [T-search-hit-line] sessionId → the line that holds the
                // query, for every session with a message hit — including
                // those whose title matched too, so the row shows where in the
                // conversation the keyword is. Title-only matches keep the
                // normal preview under the highlighted title.
                var snippets: [String: String] = [:]
                for r in results {
                    if let snip = r.matchSnippet, !snip.isEmpty {
                        snippets[r.session.id] = snip
                    }
                }
                searchMatchSnippets = snippets
            }
        }
    }

    func dismissSearch() {
        searchText = ""
        searchMatchedIds = nil
        searchMatchSnippets = [:]
        searchMatchedFolderIds = []
        searchFolderPages = [:]
        searchTask?.cancel()
        searchFocused = false
    }

    /// Clear an empty search on navigation; keep an actual query for returning to results.
    func dismissSearchIfEmptyOnNavigate() {
        guard searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        dismissSearch()
    }

    /// Focus the persistent search field for the hardware ⌘F shortcut.
    func focusSearch() {
        DispatchQueue.main.async { searchFocused = true }
    }

    /// Persistent search field pinned under the navigation bar of the session
    /// list. Replaces the old expandable search FAB.
    var sessionSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search chats...", text: $searchText)
                .textFieldStyle(.plain)
                .frame(minHeight: 44)
                .autocorrectionDisabled()
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit { searchFocused = false }
                .onChange(of: searchText) { _ in scheduleSearch() }
                .accessibilityLabel(Text("Search chats..."))
            if !searchText.isEmpty {
                Button { dismissSearch() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear"))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, searchText.isEmpty ? 12 : 0)
        .frame(minHeight: 44)
        .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(UIColor.systemBackground))
    }
}
