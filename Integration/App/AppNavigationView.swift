import SwiftUI

private struct AppNavigationIsActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var appNavigationIsActive: Bool {
        get { self[AppNavigationIsActiveKey.self] }
        set { self[AppNavigationIsActiveKey.self] = newValue }
    }
}

/// A route is visible only while its existing native page is actually mounted.
private struct AppNavigationPageModifier: ViewModifier {
    let routeID: String
    let params: [String: String]
    let canGoBack: Bool
    let isReady: Bool
    let onBack: (() -> Void)?
    @ObservedObject private var navigation = AppNavigationCenter.shared
    @Environment(\.appNavigationIsActive) private var isActive
    @Environment(\.dismiss) private var dismiss
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .onAppear { appeared = true; mount() }
            .onDisappear {
                appeared = false
                if isActive { navigation.unmount(routeID: routeID, params: params) }
            }
            .onChange(of: isActive) { _, active in
                if active { mount() }
                else { navigation.unmount(routeID: routeID, params: params) }
            }
            .onChange(of: params) { _, _ in mount() }
            .onChange(of: routeID) { _, _ in mount() }
            .onChange(of: isReady) { _, ready in if ready { mount() } }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("Yima.navigationPresentationDismissed"))) { _ in mount() }
            .onChange(of: navigation.command) { _, command in
                guard appeared, isActive, let command, navigation.isCurrent(command) else { return }
                if command.action == .navigate, command.routeID == routeID, command.params == params {
                    mount()
                } else if command.action == .back, canGoBack,
                          navigation.state.routeID == routeID, navigation.state.params == params {
                    if let onBack { onBack() } else { dismiss() }
                }
            }
    }

    private func mount() {
        guard appeared, isActive, isReady else { return }
        navigation.mount(routeID: routeID, params: params, canGoBack: canGoBack)
        if routeID == "extension.settings" { XiaolanVoiceController.shared.pause() }
    }
}

extension View {
    func appNavigationPage(_ routeID: String, params: [String: String] = [:], canGoBack: Bool = true,
                           isReady: Bool = true, onBack: (() -> Void)? = nil) -> some View {
        modifier(AppNavigationPageModifier(routeID: routeID, params: params, canGoBack: canGoBack, isReady: isReady, onBack: onBack))
    }
}
