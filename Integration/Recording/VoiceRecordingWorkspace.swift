import SwiftUI
import Combine

@MainActor
public final class VoiceRecordingWorkspace: ObservableObject {
    private let model: RecordingCoreModel
    public let startupError: String?
    private var prepared = false
    @Published private var ready = false

    public init() {
        do {
            model = try RecordingCoreModel()
            startupError = nil
        } catch {
            model = RecordingCoreModel.makePlaceholder()
            startupError = error.localizedDescription
        }
    }

    public var showsRecording: Bool { model.showsSessionChrome }

    public func meetings(start: Binding<Bool>, stop: Binding<Bool>) -> AnyView {
        AnyView(WorkspaceMeetings(model: model, error: startupError, ready: ready, start: start, stop: stop))
    }

    public func settings() -> AnyView {
        AnyView(AppLanguageGate { SettingsScreen(model: model, reduceMotion: UIAccessibility.isReduceMotionEnabled) })
    }

    public func recordingBar() -> AnyView {
        AnyView(AppLanguageGate { RecordingBar(model: model, reduceMotion: UIAccessibility.isReduceMotionEnabled) })
    }

    public func sceneChanged(_ phase: ScenePhase) {
        switch phase {
        case .active: model.scenePhaseChanged(to: .active)
        case .inactive: model.scenePhaseChanged(to: .inactive)
        case .background: model.scenePhaseChanged(to: .background)
        @unknown default: break
        }
    }

    public func prepare() async {
        guard !prepared, startupError == nil else { return }
        prepared = true
        await model.recoverOnLaunch()
        ready = true
    }

    public func stop() async { await model.stop() }

    public static var documentsURL: URL { PublicDocumentContainer.localRootURL() }
}

private struct WorkspaceMeetings: View {
    let model: RecordingCoreModel
    let error: String?
    let ready: Bool
    @Binding var start: Bool
    @Binding var stop: Bool
    @AppStorage(OnboardingPreferences.completedKey) private var onboarded = false

    var body: some View {
        AppLanguageGate {
            if let error {
                ContentUnavailableView("无法打开录音资料", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if !ready {
                ProgressView("正在恢复录音资料…")
            } else if onboarded {
                ContentView(openStartRecording: $start, openStopRecording: $stop, sharedModel: model)
            } else {
                OnboardingFlowView()
            }
        }
    }
}
