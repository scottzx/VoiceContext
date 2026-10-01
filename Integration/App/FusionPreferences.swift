import Foundation

/// The host owns display preferences for both the agent and recording modules.
enum FusionPreferences {
    static func migrateLanguage(defaults: UserDefaults = .standard) {
        // Preserve an explicit host choice, including “follow system”. Only
        // import the recording app's preference when the host has no choice.
        guard defaults.object(forKey: "appLanguage") == nil else { return }
        let legacy = defaults.string(forKey: "app_preferred_language") ?? "system"
        defaults.set(legacy == "system" ? "" : legacy, forKey: "appLanguage")
    }
}
