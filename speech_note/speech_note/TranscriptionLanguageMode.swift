import Foundation

/// User-facing SenseVoice language bias for new transcription work.
///
/// Settings changes apply to **new** recordings / imports only. Each
/// `Recording` snapshots the mode at creation so in-flight and completed
/// transcripts are never silently rewritten.
nonisolated enum TranscriptionLanguageMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Force Mandarin Chinese LID (`zh`). This is the default for new work.
    case chinese = "chinese"
    /// Autodetect across the languages supported by the bundled model.
    /// Keep the legacy raw value so existing recording snapshots remain valid.
    case zhEnBilingual = "zh_en_bilingual"
    /// Force Cantonese LID (`yue`).
    case cantonese = "cantonese"
    /// Force English LID (`en`). Keep the legacy raw value for compatibility.
    case englishOnly = "english_only"
    /// Force Japanese LID (`ja`).
    case japanese = "japanese"
    /// Force Korean LID (`ko`).
    case korean = "korean"

    static let preferenceKey = "settings.transcriptionLanguageMode"
    static let `default`: TranscriptionLanguageMode = .chinese

    var id: String { rawValue }

    /// Title shown in Settings.
    var settingsTitle: String {
        switch self {
        case .chinese: "中文"
        case .zhEnBilingual: "自动识别"
        case .cantonese: "粤语"
        case .englishOnly: "英语"
        case .japanese: "日语"
        case .korean: "韩语"
        }
    }

    /// Compact label for detail metadata / export (e.g. ZH-EN).
    var shortLabel: String {
        switch self {
        case .chinese: "ZH"
        case .zhEnBilingual: "AUTO"
        case .cantonese: "YUE"
        case .englishOnly: "EN"
        case .japanese: "JA"
        case .korean: "KO"
        }
    }

    /// BCP-47-ish code for `transcribe_run_params.language`, or `nil` to autodetect.
    var senseVoiceLanguageHint: String? {
        switch self {
        case .chinese: "zh"
        case .zhEnBilingual: nil
        case .cantonese: "yue"
        case .englishOnly: "en"
        case .japanese: "ja"
        case .korean: "ko"
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
