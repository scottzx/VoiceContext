import SwiftUI
import MapKit
import UIKit

/// MapKit candidates remain temporary until a successful write to the shared store.
struct YimaPlacesView: View {
    let presentationID: UUID?
    @ObservedObject private var store = YimaPlacesStore.shared
    @ObservedObject private var navigation = AppNavigationCenter.shared
    @State private var mode = DisplayMode.map
    @State private var query = ""
    @State private var tag: String?
    @State private var camera: MapCameraPosition = .automatic
    @State private var selection: YimaPlace?
    @State private var searchRequest: YimaPlaceSearchRequest?
    @State private var detailEditing = false
    @State private var modalMounted = false
    @State private var presentedPlaces: [YimaPlace] = []
    @State private var savedIDs: [UUID: UUID] = [:]
    @State private var presentationTitle = ""
    @State private var isSearchResult = false
    @State private var appliedPresentationID: UUID?
    @State private var presentationError: String?

    init(presentationID: UUID? = nil) { self.presentationID = presentationID }

    private enum DisplayMode: String, CaseIterable {
        case map = "地图", list = "收藏"
    }
    private var routeID: String { presentationID == nil ? "extension.places" : "extension.places.show" }
    private var routeParams: [String: String] { presentationID.map { ["presentation_id": $0.uuidString] } ?? [:] }
    private var presentationApplied: Bool { presentationID == nil || appliedPresentationID == presentationID }
    private var hasPresentation: Bool { modalMounted || selection != nil || searchRequest != nil }
    private var hasRequestedPresentation: Bool { selection != nil || searchRequest != nil }
    private var isReady: Bool { presentationApplied && !hasPresentation }
    private var source: [YimaPlace] {
        guard presentationID != nil else { return store.items }
        var seen: Set<UUID> = []
        return presentedPlaces.compactMap { place in
            let resolved: YimaPlace?
            if !isSearchResult { resolved = store.get(place.id) }
            else if let saved = store.savedMatch(for: place) { resolved = saved }
            else if let savedID = savedIDs[place.id] { resolved = store.get(savedID) }
            else { resolved = place }
            guard let resolved, seen.insert(resolved.id).inserted else { return nil }
            return resolved
        }
    }
    private var visiblePlaces: [YimaPlace] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return source.filter { place in
            (tag == nil || place.tags.contains(tag!)) &&
                (text.isEmpty || place.name.localizedStandardContains(text) || place.address.localizedStandardContains(text))
        }
    }
    private var visibleSavedCount: Int { visiblePlaces.filter { store.savedMatch(for: $0) != nil }.count }
    private var visibleCollectionSummary: String {
        "已收藏 \(visibleSavedCount) 个 · 未收藏 \(visiblePlaces.count - visibleSavedCount) 个"
    }
    private var tags: [String] { Array(Set(source.flatMap(\.tags))).sorted() }

    var body: some View {
        VStack(spacing: 0) {
            controls
            if let presentationError {
                ContentUnavailableView("无法展示地点", systemImage: "map", description: Text(presentationError))
            } else if !presentationApplied {
                ProgressView("正在展示地点")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if source.isEmpty, let error = store.readError, !isSearchResult {
                ContentUnavailableView("无法读取收藏", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if visiblePlaces.isEmpty {
                emptyState
            } else if mode == .map {
                map
            } else {
                placesList
            }
        }
        .background(YimaDesign.Color.canvas)
        .foregroundStyle(YimaDesign.Color.ink)
        .tint(YimaDesign.Color.ink)
        .navigationTitle("美食地图")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { searchRequest = YimaPlaceSearchRequest() } label: {
                    Label("添加地点", systemImage: "plus")
                        .frame(minWidth: YimaDesign.Layout.hitTarget, minHeight: YimaDesign.Layout.hitTarget)
                }
                .disabled(!store.available)
            }
        }
        .appNavigationPage(routeID, params: routeParams, isReady: isReady)
        .task(id: presentationID) { applyPresentation() }
        .onChange(of: navigation.command) { _, command in
            if presentationError != nil, let command, command.routeID == routeID, command.params == routeParams {
                navigation.fail(commandID: command.id, message: presentationError ?? "地点展示请求已失效。")
            }
        }
        .onChange(of: store.items) { _, _ in reconcileSavedIDs() }
        .onChange(of: visiblePlaces) { _, _ in camera = .automatic }
        .onChange(of: tags) { _, values in if let tag, !values.contains(tag) { self.tag = nil } }
        .pausesXiaolanVoice(while: searchRequest != nil || detailEditing)
        .onChange(of: hasRequestedPresentation) { _, active in
            if active { modalMounted = true; publishPresentation() }
        }
        .onChange(of: detailEditing) { _, _ in publishPresentation() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("Yima.dismissExtensionPresentation"))) { _ in
            guard !detailEditing, searchRequest == nil else { return }
            selection = nil
        }
        .protectedYimaSheet(item: $selection, onDismiss: presentationDidDismiss) { place in
            YimaPlaceDetailSheet(place: place, onSaved: didSave) { editing in detailEditing = editing }
        }
        .protectedYimaSheet(item: $searchRequest, onDismiss: presentationDidDismiss) { _ in
            YimaPlaceSearchSheet { place in
                didSave(place, replacing: nil)
                query = ""
                tag = nil
                camera = .automatic
            }
        }
    }

    private var controls: some View {
        VStack(spacing: YimaDesign.Space.md) {
            Picker("显示方式", selection: $mode) {
                ForEach(DisplayMode.allCases, id: \.self) {
                    Text(isSearchResult && $0 == .list ? "列表" : $0.rawValue).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .frame(minHeight: YimaDesign.Layout.hitTarget)
            HStack(spacing: YimaDesign.Space.sm) {
                Image(systemName: "magnifyingglass").foregroundStyle(YimaDesign.Color.muted).accessibilityHidden(true)
                TextField("查找店名或地址", text: $query)
                    .submitLabel(.search)
                    .accessibilityLabel("查找地图中的店名或地址")
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .frame(minWidth: 44, minHeight: 44)
                    }.accessibilityLabel("清除查找文字")
                }
            }
            .padding(.horizontal, YimaDesign.Space.md)
            .frame(minHeight: YimaDesign.Layout.hitTarget)
            .background(YimaDesign.Color.grouped, in: RoundedRectangle(cornerRadius: YimaDesign.Radius.control))
            if !tags.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: YimaDesign.Space.sm) {
                        filterButton("全部", value: nil)
                        ForEach(tags, id: \.self) { filterButton($0, value: $0) }
                    }
                }.scrollIndicators(.hidden)
            }
            if presentationID != nil, presentationApplied {
                HStack(alignment: .top, spacing: YimaDesign.Space.sm) {
                    Text(presentationTitle).font(.subheadline)
                    Spacer(minLength: 0)
                    if isSearchResult { Text("搜索结果").font(.caption).foregroundStyle(YimaDesign.Color.muted) }
                }.accessibilityElement(children: .combine)
            }
            if let error = store.readError, !source.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(YimaDesign.Color.recordingText)
            }
        }
        .padding(.horizontal, YimaDesign.Layout.listInset)
        .padding(.bottom, YimaDesign.Space.sm)
    }

    private func filterButton(_ title: String, value: String?) -> some View {
        let selected = tag == value
        let count = source.filter { value == nil || $0.tags.contains(value!) }.count
        return Button { tag = value } label: {
            HStack(spacing: YimaDesign.Space.xs) {
                Text(title)
                Text(count, format: .number).font(.caption).monospacedDigit()
            }
            .font(.subheadline)
            .padding(.horizontal, YimaDesign.Space.md)
            .frame(minHeight: YimaDesign.Layout.hitTarget)
            .background(selected ? YimaDesign.Color.ink : YimaDesign.Color.canvas,
                        in: RoundedRectangle(cornerRadius: YimaDesign.Radius.control))
            .foregroundStyle(selected ? YimaDesign.Color.canvas : YimaDesign.Color.ink)
            .overlay(RoundedRectangle(cornerRadius: YimaDesign.Radius.control).strokeBorder(YimaDesign.Color.line))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)，\(count) 个地点")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var map: some View {
        VStack(spacing: 0) {
            Map(position: $camera) {
                ForEach(visiblePlaces) { place in
                    Annotation(place.name, coordinate: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)) {
                        Button { selection = place } label: {
                            VStack(spacing: YimaDesign.Space.xs) {
                                Image(systemName: "mappin.circle.fill").font(.title)
                                    .background(YimaDesign.Color.canvas, in: Circle())
                                Text(place.name).font(.caption.weight(.semibold)).lineLimit(2)
                                    .padding(.horizontal, YimaDesign.Space.sm).padding(.vertical, YimaDesign.Space.xs)
                                    .background(YimaDesign.Color.surface, in: RoundedRectangle(cornerRadius: 6))
                            }
                            .foregroundStyle(YimaDesign.Color.ink)
                            .frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(place.name)，\(place.address)")
                        .accessibilityHint("查看地点详情")
                    }.annotationTitles(.hidden)
                }
            }
            .mapStyle(.standard(elevation: .flat))
            .mapControls { MapCompass(); MapScaleView() }
            .accessibilityLabel(isSearchResult ? "地点地图，可切换列表查看搜索结果及收藏状态" : "地点地图，可切换收藏列表查看全部地点")
            HStack(alignment: .center, spacing: YimaDesign.Space.md) {
                VStack(alignment: .leading, spacing: YimaDesign.Space.xs) {
                    Text("\(visiblePlaces.count) 个地点").font(.subheadline.weight(.semibold))
                    Text(isSearchResult ? visibleCollectionSummary : "点选标记查看详情与导航")
                        .font(.caption).foregroundStyle(YimaDesign.Color.muted)
                }
                Spacer(minLength: 0)
                Button("查看列表") { mode = .list }.font(.subheadline).frame(minHeight: 44)
            }
            .padding(.horizontal, YimaDesign.Layout.pageInset).padding(.vertical, YimaDesign.Space.sm)
            .background(YimaDesign.Color.canvas)
        }
    }

    private var placesList: some View {
        List {
            Section {
                ForEach(visiblePlaces) { place in
                    Button { selection = place } label: {
                        YimaPlaceRow(place: place, showsTags: true,
                                     collectionStatus: isSearchResult ? (store.savedMatch(for: place) == nil ? "未收藏" : "已收藏") : nil)
                    }.buttonStyle(.plain).accessibilityHint("查看地点详情与导航")
                }
            } header: {
                Text(isSearchResult ? "\(visiblePlaces.count) 个搜索结果 · \(visibleCollectionSummary)" : "\(visiblePlaces.count) 个地点")
            }
        }.listStyle(.plain).scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(source.isEmpty ? (isSearchResult ? "没有搜索结果" : "还没有收藏地点") : "没有匹配的地点", systemImage: "map")
        } description: {
            Text(source.isEmpty ? (isSearchResult ? "请补充店名、城市或地址后重新查找。" : "告诉小蓝具体店名或地址，或者添加地点。收藏和标签保存在 Yima。") : "试试其他店名、地址或标签。")
        } actions: {
            if source.isEmpty {
                Button("添加地点") { searchRequest = YimaPlaceSearchRequest() }.buttonStyle(.bordered).disabled(!store.available)
            } else {
                Button("清除筛选") { query = ""; tag = nil }.buttonStyle(.bordered)
            }
        }
    }

    private func applyPresentation() {
        guard let presentationID else { return }
        guard appliedPresentationID != presentationID else { return }
        guard let request = YimaPlacesPresentation.shared.request(id: presentationID) else {
            presentationError = "这次地点展示已失效，请让小蓝重新查找或打开收藏。"
            if let command = navigation.command, command.routeID == routeID, command.params == routeParams {
                navigation.fail(commandID: command.id, message: presentationError!)
            }
            return
        }
        presentedPlaces = request.places
        presentationTitle = request.title
        isSearchResult = request.isSearchResult
        query = ""
        tag = nil
        savedIDs = [:]
        reconcileSavedIDs()
        mode = .map
        camera = .automatic
        presentationError = nil
        appliedPresentationID = presentationID
    }

    private func publishPresentation() {
        if hasPresentation { navigation.unmount(routeID: routeID, params: routeParams) }
        NotificationCenter.default.post(name: Notification.Name("Yima.extensionPresentationChanged"), object: nil,
                                        userInfo: ["active": hasPresentation, "editing": searchRequest != nil || detailEditing, "source": "places"])
    }

    private func presentationDidDismiss() {
        modalMounted = hasRequestedPresentation
        detailEditing = false
        publishPresentation()
        if !hasPresentation {
            NotificationCenter.default.post(name: Notification.Name("Yima.navigationPresentationDismissed"), object: nil)
        }
    }

    private func reconcileSavedIDs() {
        guard isSearchResult else { return }
        for place in presentedPlaces {
            if let saved = store.savedMatch(for: place) { savedIDs[place.id] = saved.id }
            // Keep a known alias when deleted so its candidate does not reappear as unsaved.
        }
    }

    private func didSave(_ place: YimaPlace, replacing original: YimaPlace?) {
        if let original { savedIDs[original.id] = place.id }
        reconcileSavedIDs()
        if presentationID != nil, !source.contains(where: { $0.id == place.id }) {
            presentedPlaces.append(place)
        }
    }
}

private struct YimaPlaceSearchRequest: Identifiable { let id = UUID() }

private struct YimaPlaceRow: View {
    let place: YimaPlace
    var showsTags = false
    var collectionStatus: String? = nil
    var body: some View {
        HStack(alignment: .top, spacing: YimaDesign.Space.md) {
            Image(systemName: "mappin.and.ellipse")
                .foregroundStyle(YimaDesign.Color.muted).frame(width: 28, height: 44).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: YimaDesign.Space.xs) {
                Text(place.name).font(.body.weight(.semibold)).foregroundStyle(YimaDesign.Color.ink)
                Text(place.address).font(.subheadline).foregroundStyle(YimaDesign.Color.muted)
                if let collectionStatus {
                    Text(([collectionStatus] + (showsTags ? place.tags : [])).joined(separator: " · "))
                        .font(.caption).foregroundStyle(YimaDesign.Color.muted)
                } else if showsTags, !place.tags.isEmpty {
                    Text(place.tags.joined(separator: " · ")).font(.caption).foregroundStyle(YimaDesign.Color.muted)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(YimaDesign.Color.muted)
                .frame(minHeight: 44).accessibilityHidden(true)
        }
        .padding(.vertical, YimaDesign.Space.sm)
        .frame(minHeight: YimaDesign.Layout.rowMinHeight).contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct YimaPlaceDetailSheet: View {
    let place: YimaPlace
    let onSaved: (YimaPlace, YimaPlace?) -> Void
    let onEditingChanged: (Bool) -> Void
    @ObservedObject private var store = YimaPlacesStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var resolvedID: UUID
    @State private var wasSaved: Bool
    @State private var editing: YimaPlace?
    @State private var confirmDelete = false
    @State private var deletionRevision: Int?
    @State private var openingMaps = false
    @State private var mapsTask: Task<Void, Never>?
    @State private var error: String?

    init(place: YimaPlace, onSaved: @escaping (YimaPlace, YimaPlace?) -> Void, onEditingChanged: @escaping (Bool) -> Void) {
        self.place = place
        self.onSaved = onSaved
        self.onEditingChanged = onEditingChanged
        let saved = YimaPlacesStore.shared.savedMatch(for: place)
        _resolvedID = State(initialValue: saved?.id ?? place.id)
        _wasSaved = State(initialValue: saved != nil)
    }
    private var saved: YimaPlace? { store.get(resolvedID) ?? store.savedMatch(for: place) }
    private var current: YimaPlace { saved ?? place }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: YimaDesign.Space.section) {
                    VStack(alignment: .leading, spacing: YimaDesign.Space.sm) {
                        Text(current.name).font(.title2.weight(.bold)).textSelection(.enabled)
                        Label(current.address, systemImage: "mappin.and.ellipse")
                            .font(.subheadline).foregroundStyle(YimaDesign.Color.muted).textSelection(.enabled)
                    }
                    Divider()
                    HStack(alignment: .top, spacing: YimaDesign.Space.md) {
                        VStack(alignment: .leading, spacing: YimaDesign.Space.sm) {
                            Text("我的标签").font(.caption).foregroundStyle(YimaDesign.Color.muted)
                            Text(current.tags.isEmpty ? "暂未添加标签" : current.tags.joined(separator: " · "))
                                .font(.body)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        if let saved {
                            Button("编辑标签") { editing = saved }.frame(minHeight: 44).disabled(!store.available)
                        }
                    }
                    if saved == nil, !wasSaved {
                        Button { editing = current } label: {
                            Label("收藏地点", systemImage: "bookmark")
                                .frame(maxWidth: .infinity, minHeight: YimaDesign.Layout.primaryHeight)
                                .background(YimaDesign.Color.ink, in: RoundedRectangle(cornerRadius: YimaDesign.Radius.control))
                                .foregroundStyle(YimaDesign.Color.canvas)
                        }.buttonStyle(.plain).disabled(!store.available)
                    }
                    Button(action: openMaps) {
                        HStack {
                            if openingMaps { ProgressView().tint(.white) }
                            Label("用苹果地图导航", systemImage: "arrow.triangle.turn.up.right.diamond")
                        }
                        .frame(maxWidth: .infinity, minHeight: YimaDesign.Layout.primaryHeight)
                        .foregroundStyle(.white)
                        .background(YimaDesign.Color.info, in: RoundedRectangle(cornerRadius: YimaDesign.Radius.control))
                    }.buttonStyle(.plain).disabled(openingMaps)
                    Text("导航将交给苹果地图，由你选择路线。")
                        .font(.caption).foregroundStyle(YimaDesign.Color.muted)
                    Text(saved != nil ? "已保存在 Yima · 仅本机" : (wasSaved ? "这条收藏已被移除。" : "地点尚未收藏。"))
                        .font(.caption).foregroundStyle(YimaDesign.Color.muted)
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.subheadline).foregroundStyle(YimaDesign.Color.recordingText)
                    }
                    if !store.available, let error = store.readError {
                        Text(error).font(.subheadline).foregroundStyle(YimaDesign.Color.recordingText)
                    }
                }
                .padding(YimaDesign.Layout.pageInset)
            }
            .navigationTitle("地点详情").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.frame(minHeight: 44) }
                if let saved {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("编辑标签", systemImage: "tag") { editing = saved }
                            Button("删除收藏", systemImage: "trash", role: .destructive) { deletionRevision = saved.revision; confirmDelete = true }
                        } label: {
                            Label("更多地点操作", systemImage: "ellipsis.circle").frame(minWidth: 44, minHeight: 44)
                        }.disabled(!store.available)
                    }
                }
            }
            .confirmationDialog("删除这个收藏地点？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除收藏", role: .destructive) {
                    guard let saved, let deletionRevision else { return }
                    do { try store.delete(id: saved.id, expectedRevision: deletionRevision); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
                Button("取消", role: .cancel) {}
            } message: { Text("仅从美食地图移除「\(current.name)」。") }
            .onChange(of: editing != nil) { _, active in if active { onEditingChanged(true) } }
            .onChange(of: confirmDelete) { _, active in onEditingChanged(active || editing != nil) }
            .protectedYimaSheet(item: $editing, onDismiss: { onEditingChanged(confirmDelete) }) { value in
                NavigationStack {
                    YimaPlaceTagEditor(place: value, isNew: saved == nil) { savedPlace in
                        resolvedID = savedPlace.id
                        wasSaved = true
                        onSaved(savedPlace, place)
                        editing = nil
                    }
                }
            }
        }.tint(YimaDesign.Color.ink)
            .onChange(of: store.items) { _, _ in
                if let saved { resolvedID = saved.id; wasSaved = true }
            }
            .onDisappear { mapsTask?.cancel() }
    }

    private func openMaps() {
        guard AppNavigationCenter.shared.available, UIApplication.shared.applicationState == .active else {
            error = "请在解锁并打开 Yima 后发起导航。"
            return
        }
        let destination = current
        openingMaps = true
        error = nil
        mapsTask = Task { @MainActor in
            guard !Task.isCancelled, AppNavigationCenter.shared.available,
                  UIApplication.shared.applicationState == .active else {
                openingMaps = false
                error = "请在解锁并打开 Yima 后发起导航。"
                return
            }
            let opened = await YimaPlaceSearch.openInMaps(destination)
            guard !Task.isCancelled else { return }
            openingMaps = false
            if !opened { error = "未能打开苹果地图，收藏仍然保留。请稍后重试。" }
        }
    }
}

private struct YimaPlaceSearchSheet: View {
    let onSaved: (YimaPlace) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var area = ""
    @State private var candidates: [YimaPlace] = []
    @State private var selected: YimaPlace?
    @State private var searching = false
    @State private var searched = false
    @State private var error: String?
    @State private var searchID = UUID()
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("具体店名或地址", text: $query).submitLabel(.search).onSubmit(search)
                    TextField("城市或区域（可选）", text: $area).submitLabel(.search).onSubmit(search)
                    Button(action: search) {
                        HStack(spacing: YimaDesign.Space.sm) {
                            if searching { ProgressView() }
                            Text(searching ? "正在查找地点" : "查找地点")
                        }.frame(minHeight: 44)
                    }.disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || searching)
                } header: { Text("1 / 2 · 查找真实地点") } footer: {
                    Text("填写城市或完整地址有助于找到正确分店。不会获取当前位置。地点搜索需要网络。")
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(YimaDesign.Color.recordingText) }
                }
                if !candidates.isEmpty {
                    Section {
                        ForEach(candidates) { candidate in
                            Button { selected = candidate } label: { YimaPlaceRow(place: candidate) }
                                .buttonStyle(.plain).accessibilityHint("选择此地点并添加标签")
                        }
                    } header: { Text("核对名称和完整地址，选择具体地点") } footer: {
                        Text("选择后可添加标签；保存成功后才会加入收藏。")
                    }
                } else if searched, !searching, error == nil {
                    Section { Text("没有找到地点。请补充城市、区域或更完整的地址后重试。").foregroundStyle(YimaDesign.Color.muted) }
                }
            }
            .navigationTitle("添加地点").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.frame(minHeight: 44) } }
            .navigationDestination(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                if let selected {
                    YimaPlaceTagEditor(place: selected, isNew: true) { saved in
                        onSaved(saved)
                        dismiss()
                    }
                }
            }
        }
        .tint(YimaDesign.Color.ink)
        .onChange(of: query) { _, _ in resetSearch() }
        .onChange(of: area) { _, _ in resetSearch() }
        .onDisappear { searchTask?.cancel(); searchID = UUID() }
    }

    private func resetSearch() {
        searchTask?.cancel()
        searchID = UUID()
        searching = false
        searched = false
        candidates = []
        error = nil
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        searchTask?.cancel()
        let region = area.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = UUID()
        searchID = id
        searching = true
        searched = true
        candidates = []
        error = nil
        searchTask = Task { @MainActor in
            do {
                let results = try await YimaPlaceSearch.search(query: text, area: region.isEmpty ? nil : region)
                guard !Task.isCancelled, searchID == id else { return }
                candidates = results
                searching = false
            } catch {
                guard !Task.isCancelled, searchID == id else { return }
                self.error = error.localizedDescription
                searching = false
            }
        }
    }
}

private struct YimaPlaceTagEditor: View {
    let place: YimaPlace
    let isNew: Bool
    let onSaved: (YimaPlace) -> Void
    @ObservedObject private var store = YimaPlacesStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var tags: [String]
    @State private var extraTags: [String] = []
    @State private var newTag = ""
    @State private var revision: Int
    @State private var error: String?

    init(place: YimaPlace, isNew: Bool, onSaved: @escaping (YimaPlace) -> Void) {
        self.place = place
        self.isNew = isNew
        self.onSaved = onSaved
        _tags = State(initialValue: place.tags)
        _revision = State(initialValue: place.revision)
    }
    private var options: [String] { Array(Set(store.allTags + tags + extraTags)).sorted() }

    var body: some View {
        Form {
            Section {
                Text(place.name).font(.headline)
                Text(place.address).font(.subheadline).foregroundStyle(YimaDesign.Color.muted)
            } header: { if isNew { Text("2 / 2 · 保存到美食地图") } }
            Section {
                if options.isEmpty { Text("暂时没有标签，可以在下方新建。").foregroundStyle(YimaDesign.Color.muted) }
                ForEach(options, id: \.self) { tag in
                    Button {
                        if tags.contains(tag) { tags.removeAll { $0 == tag } }
                        else { tags.append(tag) }
                    } label: {
                        HStack(spacing: YimaDesign.Space.md) {
                            Text(tag).frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: tags.contains(tag) ? "checkmark.circle.fill" : "circle")
                        }.frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityAddTraits(tags.contains(tag) ? .isSelected : [])
                }
            } header: { Text("选择标签") } footer: { Text("可以选择多个标签，也可以不加标签。") }
            Section("新建标签") {
                TextField("例如：周末去", text: $newTag).submitLabel(.done).onSubmit(addTag)
                Button("添加标签", action: addTag).frame(minHeight: 44)
                    .disabled(newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(YimaDesign.Color.recordingText)
                    if !isNew, let saved = store.get(place.id) {
                        Button("重新载入已保存标签") { tags = saved.tags; revision = saved.revision; self.error = nil }
                            .frame(minHeight: 44)
                    }
                }
            }
            if !store.available, let error = store.readError {
                Section { Text(error).foregroundStyle(YimaDesign.Color.recordingText) }
            }
        }
        .foregroundStyle(YimaDesign.Color.ink)
        .navigationTitle(isNew ? "添加标签" : "编辑标签")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.frame(minHeight: 44) }
            ToolbarItem(placement: .confirmationAction) {
                Button(isNew ? "保存收藏" : "保存", action: save).frame(minHeight: 44).disabled(!store.available)
            }
        }
    }

    private func addTag() {
        let value = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        guard value.count <= 12 else { error = "标签最多 12 个字。"; return }
        if !tags.contains(value) { tags.append(value) }
        if !extraTags.contains(value) { extraTags.append(value) }
        newTag = ""
        error = nil
    }

    private func save() {
        let pending = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pending.isEmpty {
            guard pending.count <= 12 else { error = "标签最多 12 个字。"; return }
            if !tags.contains(pending) { tags.append(pending) }
        }
        do {
            let saved: YimaPlace
            if isNew { saved = try store.save(place, tags: tags) }
            else { saved = try store.updateTags(id: place.id, tags: tags, expectedRevision: revision) }
            onSaved(saved)
        } catch { self.error = error.localizedDescription }
    }
}
