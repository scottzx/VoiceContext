import Foundation
import Testing
@testable import speech_note

struct TranscriptionLanguageModeTests {
    @Test func defaultIsChineseAndEveryBundledLanguageMapsToSenseVoice() {
        #expect(TranscriptionLanguageMode.default == .chinese)
        #expect(TranscriptionLanguageMode.chinese.senseVoiceLanguageHint == "zh")
        #expect(TranscriptionLanguageMode.zhEnBilingual.senseVoiceLanguageHint == nil)
        #expect(TranscriptionLanguageMode.cantonese.senseVoiceLanguageHint == "yue")
        #expect(TranscriptionLanguageMode.englishOnly.senseVoiceLanguageHint == "en")
        #expect(TranscriptionLanguageMode.japanese.senseVoiceLanguageHint == "ja")
        #expect(TranscriptionLanguageMode.korean.senseVoiceLanguageHint == "ko")
        #expect(TranscriptionLanguageMode.chinese.settingsTitle == "中文")
        #expect(TranscriptionLanguageMode.zhEnBilingual.settingsTitle == "自动识别")
        #expect(TranscriptionLanguageMode.englishOnly.settingsTitle == "英语")
        #expect(TranscriptionLanguageMode.zhEnBilingual.shortLabel == "AUTO")
        #expect(TranscriptionLanguageMode.englishOnly.shortLabel == "EN")
    }

    @Test func preferenceRoundTripUsesDedicatedDefaultsSuite() {
        let suiteName = "TranscriptionLanguageModeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(TranscriptionLanguageMode.load(from: defaults) == .chinese)

        TranscriptionLanguageMode.save(.englishOnly, to: defaults)
        #expect(TranscriptionLanguageMode.load(from: defaults) == .englishOnly)

        TranscriptionLanguageMode.save(.zhEnBilingual, to: defaults)
        #expect(TranscriptionLanguageMode.load(from: defaults) == .zhEnBilingual)

        defaults.set("not-a-mode", forKey: TranscriptionLanguageMode.preferenceKey)
        #expect(TranscriptionLanguageMode.load(from: defaults) == .chinese)
    }

    @Test func recordingSnapshotsLanguageModeAndPreservesLegacyAutodetectRows() throws {
        let english = Recording(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            languageMode: .englishOnly
        )
        #expect(english.languageMode == .englishOnly)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let encoded = try encoder.encode(english)
        let decoded = try decoder.decode(Recording.self, from: encoded)
        #expect(decoded.languageMode == .englishOnly)
        #expect(!decoded.speakerProcessingEnabled)

        // Legacy journal rows retain the old autodetect and speaker-processing behavior.
        var legacyObject = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacyObject.removeValue(forKey: "languageMode")
        legacyObject.removeValue(forKey: "speakerProcessingEnabled")
        let legacyJSON = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacy = try decoder.decode(Recording.self, from: legacyJSON)
        #expect(legacy.languageMode == .zhEnBilingual)
        #expect(legacy.speakerProcessingEnabled)
    }

    @Test func transcriptDocumentPersistsLanguageModeIndependentlyOfDetectedLanguage() throws {
        let recording = Recording(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_060),
            state: .complete,
            languageMode: .englishOnly
        )
        let chunk = AudioChunk(
            recordingID: recording.id,
            relativePath: "audio/000.m4a",
            startSample: 0,
            endSample: 16_000,
            startedAt: recording.startedAt,
            endedAt: recording.endedAt!
        )
        let document = TranscriptDocumentV1(
            recording: recording,
            chunks: [chunk],
            segmentTexts: [(chunkID: chunk.id, text: "hello")],
            language: "en"
        )
        #expect(document.languageMode == .englishOnly)
        #expect(document.language == "en")

        let encoded = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(TranscriptDocumentV1.self, from: encoded)
        #expect(decoded.languageMode == .englishOnly)

        let markdown = TranscriptMarkdownRenderer.render(document)
        #expect(markdown.contains("language_mode: english_only"))
        #expect(markdown.contains("language: en"))
    }

    @Test func sqliteIndexPersistsLanguageModeAcrossJournalReplay() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lang-mode-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let journal = try RecordingJournal(url: root.appendingPathComponent("events.jsonl"))
        let index = try RecordingIndex(url: root.appendingPathComponent("index.sqlite"))
        #expect(index.schemaVersion == 9)

        let recording = Recording(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            languageMode: .englishOnly
        )
        let created = RecordingJournalEvent(
            occurredAt: recording.startedAt,
            payload: .recordingCreated(recording)
        )
        try journal.append(created)
        _ = try index.apply(created)

        let loaded = try index.recording(id: recording.id)
        #expect(loaded?.languageMode == .englishOnly)
        #expect(loaded == recording)
    }

    @Test func changingPreferenceDoesNotMutateExistingRecordingSnapshot() {
        let suiteName = "TranscriptionLanguageModeTests.snapshot.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        TranscriptionLanguageMode.save(.zhEnBilingual, to: defaults)
        let snapped = TranscriptionLanguageMode.load(from: defaults)
        let recording = Recording(
            startedAt: Date(),
            languageMode: snapped
        )

        TranscriptionLanguageMode.save(.englishOnly, to: defaults)
        #expect(recording.languageMode == .zhEnBilingual)
        #expect(TranscriptionLanguageMode.load(from: defaults) == .englishOnly)
    }
}
