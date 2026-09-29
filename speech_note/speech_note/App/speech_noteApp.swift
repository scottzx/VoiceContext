//
//  speech_noteApp.swift
//  speech_note
//
//  Created by scott on 2026/8/3.
//

import SwiftUI

#if !VOICE_AGENT_FUSION
@main
struct speech_noteApp: App {
    @AppStorage(OnboardingPreferences.completedKey) private var hasCompletedOnboarding = false
    /// Stashed across cold start / onboarding so Widget taps are not lost.
    @State private var pendingStartRecording = false
    @State private var pendingStopRecording = false

    init() {
        if ScreenshotAutomation.isEnabled {
            let preferences = OnboardingPreferences()
            preferences.hasCompleted = true
            preferences.documentSyncEnabled = false
            preferences.encryptedVoiceprintSyncEnabled = false
        } else if ProcessInfo.processInfo.arguments.contains("-uiTestingResetOnboarding") {
            let preferences = OnboardingPreferences()
            preferences.hasCompleted = false
            preferences.documentSyncEnabled = false
            preferences.encryptedVoiceprintSyncEnabled = false
        }
    }

    var body: some Scene {
        WindowGroup {
            AppLanguageGate {
                Group {
                    if hasCompletedOnboarding {
                        ContentView(
                            openStartRecording: $pendingStartRecording,
                            openStopRecording: $pendingStopRecording
                        )
                    } else {
                        OnboardingFlowView()
                    }
                }
                .onOpenURL { url in
                    guard let link = AppDeepLink.parse(url) else { return }
                    switch link {
                    case .startRecording:
                        pendingStartRecording = true
                    case .stopRecording:
                        pendingStopRecording = true
                    case .openRecording:
                        break
                    }
                }
            }
        }
    }
}

#endif

/// Pushes the in-app language onto SwiftUI's locale environment so `Text("中文")`
/// lookups in `Localizable.xcstrings` update immediately.
struct AppLanguageGate<Content: View>: View {
    @ObservedObject private var languageCenter = AppLanguageCenter.shared
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .environment(\.locale, languageCenter.currentLocale)
            .environmentObject(languageCenter)
    }
}
