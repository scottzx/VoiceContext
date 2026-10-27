import Foundation
import Testing
@testable import speech_note

struct BackgroundTranscriptionContinuationTests {
    @Test func permittedIdentifierUsesContinuedProcessingWildcardPrefix() throws {
        let identifiers = try #require(
            Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers")
                as? [String]
        )
        #expect(identifiers == [
            "\(BackgroundTranscriptionContinuation.taskIdentifierPrefix).*"
        ])
    }

    @Test func preferenceDefaultsDisabledAndPersistsOptIn() throws {
        let suiteName = "BackgroundTranscriptionContinuationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = BackgroundTranscriptionPreferences(defaults: defaults)

        #expect(preferences.isEnabled == false)
        preferences.isEnabled = true
        #expect(BackgroundTranscriptionPreferences(defaults: defaults).isEnabled)
    }

    @Test func queueProgressClampsCountsAndReportsCompletion() {
        let active = BackgroundTranscriptionQueueProgress(
            pendingCount: 2,
            runningCount: 1,
            completedCount: 5,
            failedCount: -1
        )
        #expect(active.totalCount == 8)
        #expect(active.remainingCount == 3)
        #expect(active.completedUnitCount == 5)
        #expect(active.totalUnitCount == 8)
        #expect(!active.finishedSuccessfully)

        let successful = BackgroundTranscriptionQueueProgress(
            pendingCount: 0,
            runningCount: 0,
            completedCount: 7,
            failedCount: 0
        )
        #expect(successful.finishedSuccessfully)

        let failed = BackgroundTranscriptionQueueProgress(
            pendingCount: 0,
            runningCount: 0,
            completedCount: 6,
            failedCount: 1
        )
        #expect(!failed.finishedSuccessfully)
    }

    @Test func emptyQueueStillHasValidProgressTotal() {
        let progress = BackgroundTranscriptionQueueProgress(
            pendingCount: 0,
            runningCount: 0,
            completedCount: 0,
            failedCount: 0
        )
        #expect(progress.totalUnitCount == 1)
        #expect(progress.completedUnitCount == 0)
        #expect(progress.finishedSuccessfully)
    }
}
