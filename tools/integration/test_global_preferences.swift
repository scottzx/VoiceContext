import Foundation

/// Runs on macOS; no iOS application, device, or simulator is launched.
@main
struct GlobalPreferencesTests {
    @MainActor
    static func main() {
        let suite = "Yima.PreferenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        for (legacy, expected) in [("zh-Hans", "zh-Hans"), ("en", "en"), ("system", "")] {
            defaults.removePersistentDomain(forName: suite)
            defaults.set(legacy, forKey: "app_preferred_language")
            FusionPreferences.migrateLanguage(defaults: defaults)
            precondition(defaults.string(forKey: "appLanguage") == expected)
            defaults.set("en", forKey: "app_preferred_language")
            FusionPreferences.migrateLanguage(defaults: defaults)
            precondition(defaults.string(forKey: "appLanguage") == expected, "Migration must be idempotent")
        }
        for host in ["", "en", "zh-Hans", "ja"] {
            defaults.set(host, forKey: "appLanguage")
            defaults.set("zh-Hans", forKey: "app_preferred_language")
            FusionPreferences.migrateLanguage(defaults: defaults)
            precondition(defaults.string(forKey: "appLanguage") == host, "Explicit host choice must win")
        }
        defaults.removePersistentDomain(forName: suite)
        FusionPreferences.migrateLanguage(defaults: defaults)
        precondition(defaults.string(forKey: "appLanguage") == "")

        // Compile with the actual recording localization source. Check that
        // both its visible chrome and background formatters read the host key.
        let shared = UserDefaults.standard
        let oldHost = shared.object(forKey: "appLanguage")
        let oldLegacy = shared.object(forKey: "app_preferred_language")
        defer {
            shared.set(oldHost, forKey: "appLanguage")
            shared.set(oldLegacy, forKey: "app_preferred_language")
        }
        shared.set("zh-Hans", forKey: "app_preferred_language")
        for language in ["en", "zh-Hans", "ja", ""] {
            shared.set(language, forKey: "appLanguage")
            let expected = language.isEmpty ? Locale.current : Locale(identifier: language)
            precondition(AppLanguageCenter.preferredLocale() == expected)
            precondition(AppLanguageCenter.shared.currentLocale == expected)
            precondition(AppLanguageCenter.shared.isChinese == expected.identifier.hasPrefix("zh"))
        }
        print("PASS: language migration, conflict preservation, idempotency, and recording locale propagation")
    }
}
