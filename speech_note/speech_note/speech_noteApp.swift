//
//  speech_noteApp.swift
//  speech_note
//
//  Created by scott on 2026/8/3.
//

import SwiftUI

@main
struct speech_noteApp: App {
    @AppStorage(OnboardingPreferences.completedKey) private var hasCompletedOnboarding = false
    /// Stashed across cold start / onboarding so Widget taps are not lost.
    @State private var pendingStartRecording = false

    init() {
        guard ProcessInfo.processInfo.arguments.contains("-uiTestingResetOnboarding") else { return }
        let preferences = OnboardingPreferences()
        preferences.hasCompleted = false
        preferences.documentSyncEnabled = false
        preferences.encryptedVoiceprintSyncEnabled = false
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if hasCompletedOnboarding {
                    ContentView(openStartRecording: $pendingStartRecording)
                } else {
                    OnboardingFlowView()
                }
            }
            .onOpenURL { url in
                guard AppDeepLink.parse(url) == .startRecording else { return }
                pendingStartRecording = true
            }
        }
    }
}
