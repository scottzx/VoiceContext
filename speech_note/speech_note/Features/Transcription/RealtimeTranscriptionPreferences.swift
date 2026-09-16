import Foundation

/// Whether closed capture chunks enqueue ASR immediately, or wait until stop.
/// Default is on, matching the historical minute-level queue.
nonisolated struct RealtimeTranscriptionPreferences {
    static let enabledKey = "transcription.realtimeDuringCaptureEnabled"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        get {
            guard defaults.object(forKey: Self.enabledKey) != nil else { return true }
            return defaults.bool(forKey: Self.enabledKey)
        }
        nonmutating set { defaults.set(newValue, forKey: Self.enabledKey) }
    }
}
