import SwiftUI
import MapKit

@MainActor
struct YimaPlacesSaveConfirmationView: View {
    let request: YimaPlacesSaveConfirmation.Request
    @ObservedObject private var confirmation = YimaPlacesSaveConfirmation.shared
    @ObservedObject private var store = YimaPlacesStore.shared

    private var currentRequest: YimaPlacesSaveConfirmation.Request {
        if let current = confirmation.request, current.id == request.id { return current }
        return request
    }
    private var existing: YimaPlace? { store.savedMatch(for: currentRequest.place) }
    private var coordinate: CLLocationCoordinate2D {
        .init(latitude: currentRequest.place.latitude, longitude: currentRequest.place.longitude)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("地点名称") {
                    Text(currentRequest.place.name).font(.headline).textSelection(.enabled)
                }
                Section("完整地址") {
                    Text(currentRequest.place.address).textSelection(.enabled)
                    Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 1_200, longitudinalMeters: 1_200)),
                        interactionModes: [.pan, .zoom]) {
                        Marker(currentRequest.place.name, coordinate: coordinate).tint(YimaDesign.Color.ink)
                    }
                    .mapStyle(.standard(elevation: .flat))
                    .mapControls { MapScaleView() }
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: YimaDesign.Radius.control))
                    .accessibilityLabel("地点位置，\(currentRequest.place.name)，\(currentRequest.place.address)")
                    .accessibilityHint("可在地图中平移或缩放，查看周边位置。")
                }
                Section {
                    if currentRequest.tags.isEmpty {
                        Text("不添加标签").foregroundStyle(YimaDesign.Color.muted)
                    } else {
                        ForEach(currentRequest.tags, id: \.self) { Text($0) }
                    }
                } header: {
                    Text("收藏标签")
                } footer: {
                    Text(existing == nil ? "确认后保存到 Yima · 仅本机。" : "此地点已收藏，确认后将合并标签，不会重复添加。")
                }
                if let error = confirmation.error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(YimaDesign.Color.recordingText)
                    }
                }
                if !store.available, let error = store.readError {
                    Section {
                        Text(error).foregroundStyle(YimaDesign.Color.recordingText)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    VStack(spacing: YimaDesign.Space.sm) {
                        Button { confirmation.confirm(id: request.id) } label: {
                            Text("确认收藏")
                                .frame(maxWidth: .infinity, minHeight: YimaDesign.Layout.primaryHeight)
                                .background(YimaDesign.Color.ink, in: RoundedRectangle(cornerRadius: YimaDesign.Radius.control))
                                .foregroundStyle(YimaDesign.Color.canvas)
                        }
                        .buttonStyle(.plain)
                        .disabled(!store.available || confirmation.request?.id != request.id)
                        Button("取消") { confirmation.cancel(id: request.id) }
                            .frame(maxWidth: .infinity, minHeight: YimaDesign.Layout.hitTarget)
                    }
                    .padding(.horizontal, YimaDesign.Layout.pageInset)
                    .padding(.vertical, YimaDesign.Space.sm)
                }
                .background(YimaDesign.Color.canvas)
            }
            .navigationTitle("核对收藏地点")
            .navigationBarTitleDisplayMode(.inline)
        }
        .foregroundStyle(YimaDesign.Color.ink)
        .tint(YimaDesign.Color.ink)
        .onAppear { confirmation.didAppear(id: request.id) }
    }
}
