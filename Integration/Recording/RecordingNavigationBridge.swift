import SwiftUI
import Combine

/// The recording module retains its native stack; the host exchanges route receipts only.
@MainActor
public final class RecordingNavigationBridge: ObservableObject {
    public static let shared = RecordingNavigationBridge()
    @Published public var isActive = false
    @Published public private(set) var command: Command?
    public private(set) var visibleRoute: String?
    public private(set) var visibleParams: [String: String] = [:]

    public struct Command: Equatable {
        public let id: UUID
        public let routeID: String
        public let params: [String: String]
        public let isBack: Bool
        public let requiresReceipt: Bool
    }

    public func perform(id: UUID, routeID: String, params: [String: String], isBack: Bool = false, requiresReceipt: Bool = true) {
        command = Command(id: id, routeID: routeID, params: params, isBack: isBack, requiresReceipt: requiresReceipt)
    }

    public func clearCommand() { command = nil }

    func mount(_ route: String, params: [String: String], canGoBack: Bool) {
        guard isActive else { return }
        visibleRoute = route; visibleParams = params
        var receipt: [String: Any] = ["routeID": route, "params": params, "canGoBack": canGoBack]
        if let command, command.requiresReceipt, (command.isBack && command.routeID != route) ||
            (!command.isBack && command.routeID == route && command.params == params) {
            receipt["commandID"] = command.id
        }
        if let command, !command.requiresReceipt, command.routeID == route, command.params == params { self.command = nil }
        NotificationCenter.default.post(name: Notification.Name("Yima.recordingRouteMounted"), object: nil, userInfo: receipt)
    }

    func unmount(_ route: String, params: [String: String]) {
        guard visibleRoute == route, visibleParams == params else { return }
        visibleRoute = nil; visibleParams = [:]
        NotificationCenter.default.post(name: Notification.Name("Yima.recordingRouteUnmounted"), object: nil,
                                        userInfo: ["routeID": route, "params": params])
    }

    func fail(_ command: Command, message: String) {
        NotificationCenter.default.post(name: Notification.Name("Yima.recordingRouteFailed"), object: nil,
                                        userInfo: ["commandID": command.id, "message": message])
    }
}

private struct RecordingNavigationPage: ViewModifier {
    let routeID: String
    let params: [String: String]
    let canGoBack: Bool
    @ObservedObject private var bridge = RecordingNavigationBridge.shared
    @Environment(\.dismiss) private var dismiss
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .onAppear { appeared = true; mount() }
            .onDisappear { appeared = false; bridge.unmount(routeID, params: params) }
            .onChange(of: bridge.isActive) { _, active in
                if active { mount() } else { bridge.unmount(routeID, params: params) }
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("Yima.navigationPresentationDismissed"))) { _ in mount() }
            .onChange(of: bridge.command) { _, command in
                guard appeared, bridge.isActive, let command else { return }
                if command.isBack, canGoBack, bridge.visibleRoute == routeID, bridge.visibleParams == params { dismiss() }
                else if !command.isBack, command.routeID == routeID, command.params == params { mount() }
            }
    }

    private func mount() {
        guard appeared else { return }
        bridge.mount(routeID, params: params, canGoBack: canGoBack)
    }
}

extension View {
    func recordingNavigationPage(_ routeID: String, params: [String: String] = [:], canGoBack: Bool = true) -> some View {
        modifier(RecordingNavigationPage(routeID: routeID, params: params, canGoBack: canGoBack))
    }
}
