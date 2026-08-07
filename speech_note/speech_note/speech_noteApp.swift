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

    init() {
        guard ProcessInfo.processInfo.arguments.contains("-uiTestingResetOnboarding") else { return }
        let preferences = OnboardingPreferences()
        preferences.hasCompleted = false
        preferences.documentSyncEnabled = false
        preferences.encryptedVoiceprintSyncEnabled = false
    }

    var body: some Scene {
        WindowGroup {
            if hasCompletedOnboarding {
                ContentView()
            } else {
                OnboardingFlowView()
            }
        }
    }
}
