import Foundation

/// User-facing SenseVoice language bias for new transcription work.
///
/// Settings changes apply to **new** recordings / imports only. Each
/// `Recording` snapshots the mode at creation so in-flight and completed
/// transcripts are never silently rewritten.
nonisolated enum TranscriptionLanguageMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Autodetect — SenseVoice bilingual / multilingual path (zh / en / yue…).
    case zhEnBilingual = "zh_en_bilingual"
    /// Force English LID hint (`en`) for English-only / English-priority decode.
    case englishOnly = "english_only"

    static let preferenceKey = "settings.transcriptionLanguageMode"
    static let `default`: TranscriptionLanguageMode = .zhEnBilingual

    var id: String { rawValue }

    /// Title shown in Settings.
    var settingsTitle: String {
        switch self {
        case .zhEnBilingual: "中英双语"
        case .englishOnly: "英语优先"
        }
    }

    /// Compact label for detail metadata / export (e.g. ZH-EN).
    var shortLabel: String {
        switch self {
        case .zhEnBilingual: "ZH-EN"
        case .englishOnly: "EN"
        }
    }

    /// BCP-47-ish code for `transcribe_run_params.language`, or `nil` to autodetect.
    var senseVoiceLanguageHint: String? {
        switch self {
        case .zhEnBilingual: nil
        case .englishOnly: "en"
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> TranscriptionLanguageMode {
        guard let raw = defaults.string(forKey: preferenceKey),
              let mode = TranscriptionLanguageMode(rawValue: raw)
        else {
            return .default
        }
        return mode
    }

    static func save(_ mode: TranscriptionLanguageMode, to defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: preferenceKey)
    }

    /// Current Settings value. Prefer snapshotting onto `Recording` at creation
    /// rather than reading this again when a job runs.
    static var current: TranscriptionLanguageMode {
        get { load() }
        set { save(newValue) }
    }
}
