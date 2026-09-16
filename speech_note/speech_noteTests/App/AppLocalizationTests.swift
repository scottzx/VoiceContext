import Foundation
import Testing
@testable import speech_note

struct AppLocalizationTests {
    @Test func preferredLocaleFollowsStoredLanguageOverride() {
        #expect(AppLanguageCenter.locale(forStoredRaw: "en").identifier.hasPrefix("en"))
        #expect(AppLanguageCenter.locale(forStoredRaw: "zh-Hans").identifier.hasPrefix("zh"))
        #expect(AppLanguageCenter.isChinese(locale: Locale(identifier: "zh-Hans")))
        #expect(!AppLanguageCenter.isChinese(locale: Locale(identifier: "en")))
    }

    @Test func englishCatalogTranslatesCoreChrome() {
        let bundle = Bundle(for: AppLanguageCenter.self)
        let english = Locale(identifier: "en")
        #expect(String(localized: String.LocalizationValue("开始录音"), bundle: bundle, locale: english) == "Start Recording")
        #expect(String(localized: String.LocalizationValue("中英双语"), bundle: bundle, locale: english) == "Chinese & English")
        #expect(String(localized: String.LocalizationValue("界面语言"), bundle: bundle, locale: english) == "App Language")
        #expect(String(localized: String.LocalizationValue("语言模式"), bundle: bundle, locale: english) == "Language Mode")
    }
}
