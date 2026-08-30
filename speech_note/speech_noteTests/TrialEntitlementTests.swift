import Foundation
import Testing
@testable import speech_note

struct TrialEntitlementTests {
    @Test func firstForegroundOpenStartsSeventyTwoHourClockAndPersists() throws {
        let url = temporaryQuotaURL()
        let keychain = InMemoryTrialStartTimestampStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = TrialTestClock(start)
        let ledger = TrialQuotaLedger(
            fileURL: url,
            keychain: keychain,
            now: { clock.now }
        )
        #expect(ledger.trialStartedAt == nil)
        #expect(ledger.isPurchaseLocked == false)

        let sealed = ledger.ensureTrialStarted(at: start)
        #expect(sealed == start)
        #expect(ledger.trialStartedAt == start)
        #expect(ledger.remainingSeconds == TrialQuotaLedger.trialDuration)
        #expect(ledger.isPurchaseLocked == false)

        // Idempotent: later opens do not reset the clock.
        clock.now = start.addingTimeInterval(3_600)
        _ = ledger.ensureTrialStarted(at: clock.now)
        #expect(ledger.trialStartedAt == start)
        #expect(abs(ledger.remainingSeconds - (TrialQuotaLedger.trialDuration - 3_600)) < 0.5)

        let reloaded = TrialQuotaLedger(
            fileURL: url,
            keychain: InMemoryTrialStartTimestampStore(),
            now: { clock.now }
        )
        #expect(reloaded.trialStartedAt == start)
        #expect(abs(reloaded.remainingSeconds - (TrialQuotaLedger.trialDuration - 3_600)) < 0.5)
    }

    @Test func seventyOneHoursStillOpenSeventyThreeHoursLocks() throws {
        let url = temporaryQuotaURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = TrialTestClock(start)
        let ledger = TrialQuotaLedger(
            fileURL: url,
            keychain: InMemoryTrialStartTimestampStore(),
            now: { clock.now }
        )
        _ = ledger.ensureTrialStarted(at: start)

        clock.now = start.addingTimeInterval(71 * 3600)
        #expect(ledger.isPurchaseLocked == false)
        #expect(ledger.remainingSeconds > 3_500)

        clock.now = start.addingTimeInterval(73 * 3600)
        #expect(ledger.isPurchaseLocked == true)
        #expect(ledger.remainingSeconds == 0)
    }

    @Test func voiceSecondsAreNotBilledDuringTrial() throws {
        let url = temporaryQuotaURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let ledger = TrialQuotaLedger(
            fileURL: url,
            keychain: InMemoryTrialStartTimestampStore(),
            now: { start.addingTimeInterval(60) }
        )
        _ = ledger.ensureTrialStarted(at: start)
        #expect(ledger.recordUsage(jobID: UUID(), seconds: 3_600) == false)
        #expect(ledger.isPurchaseLocked == false)
        #expect(ledger.remainingSeconds > TrialQuotaLedger.trialDuration - 120)
    }

    @Test func unlockClearsPurchaseLockAndSurvivesRestart() throws {
        let url = temporaryQuotaURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let now = start.addingTimeInterval(80 * 3600)
        let ledger = TrialQuotaLedger(
            fileURL: url,
            keychain: InMemoryTrialStartTimestampStore(),
            now: { now }
        )
        _ = ledger.ensureTrialStarted(at: start)
        #expect(ledger.isPurchaseLocked == true)

        ledger.markUnlocked()
        #expect(ledger.isPurchaseLocked == false)
        #expect(ledger.isUnlocked == true)

        let reloaded = TrialQuotaLedger(
            fileURL: url,
            keychain: InMemoryTrialStartTimestampStore(),
            now: { now }
        )
        #expect(reloaded.isUnlocked == true)
        #expect(reloaded.isPurchaseLocked == false)
    }

    @Test func keychainRestoresStartWhenLocalFileMissing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("trial-quota-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("quota.json")
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let keychain = InMemoryTrialStartTimestampStore(value: start)

        let ledger = TrialQuotaLedger(
            fileURL: url,
            keychain: keychain,
            now: { start.addingTimeInterval(2 * 3600) }
        )
        #expect(ledger.trialStartedAt == start)
        #expect(ledger.isPurchaseLocked == false)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func migratesLegacySixtyMinuteLedgerKeepingUnlock() throws {
        let url = temporaryQuotaURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let legacy: [String: Any] = [
            "usedSeconds": 3600.0,
            "billedJobIDs": ["job-1"],
            "isUnlocked": true,
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        try data.write(to: url)

        let ledger = TrialQuotaLedger(
            fileURL: url,
            keychain: InMemoryTrialStartTimestampStore(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        #expect(ledger.isUnlocked == true)
        #expect(ledger.isPurchaseLocked == false)
        #expect(ledger.currentSnapshot().legacyUsedSeconds == 3600)
    }

    @Test func migratesLegacyLockedUserWithoutReliableTimestampUntilFirstOpen() throws {
        let url = temporaryQuotaURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let legacy: [String: Any] = [
            "usedSeconds": 3600.0,
            "billedJobIDs": ["job-1"],
            "isUnlocked": false,
        ]
        try JSONSerialization.data(withJSONObject: legacy).write(to: url)

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = TrialTestClock(start)
        let ledger = TrialQuotaLedger(
            fileURL: url,
            keychain: InMemoryTrialStartTimestampStore(),
            now: { clock.now }
        )
        // FR-ADD-TRL-006: no reliable first-open stamp → wait for upgrade first open.
        #expect(ledger.trialStartedAt == nil)
        #expect(ledger.isPurchaseLocked == false)

        _ = ledger.ensureTrialStarted(at: start)
        #expect(ledger.trialStartedAt == start)
        clock.now = start.addingTimeInterval(71 * 3600)
        #expect(ledger.isPurchaseLocked == false)
        clock.now = start.addingTimeInterval(73 * 3600)
        #expect(ledger.isPurchaseLocked == true)
    }

    @Test func clockRollbackDoesNotExtendRemainingTrial() throws {
        let url = temporaryQuotaURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = TrialTestClock(start)
        let ledger = TrialQuotaLedger(
            fileURL: url,
            keychain: InMemoryTrialStartTimestampStore(),
            now: { clock.now }
        )
        _ = ledger.ensureTrialStarted(at: start)
        clock.now = start.addingTimeInterval(10 * 3600)
        let remainingAfterTenHours = ledger.remainingSeconds
        #expect(abs(remainingAfterTenHours - (TrialQuotaLedger.trialDuration - 10 * 3600)) < 0.5)

        // Roll wall clock backwards by 5 hours.
        clock.now = start.addingTimeInterval(5 * 3600)
        #expect(abs(ledger.remainingSeconds - remainingAfterTenHours) < 0.5)
    }

    @Test func admissionPolicyReadsLedgerLockState() throws {
        let url = temporaryQuotaURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = TrialTestClock(start)
        let ledger = TrialQuotaLedger(
            fileURL: url,
            keychain: InMemoryTrialStartTimestampStore(),
            now: { clock.now }
        )
        _ = ledger.ensureTrialStarted(at: start)
        let policy = TranscriptionAdmissionPolicy(
            thermalState: { .nominal },
            isPurchaseLocked: { ledger.isPurchaseLocked }
        )
        #expect(policy.evaluate() == .admit)

        clock.now = start.addingTimeInterval(73 * 3600)
        #expect(policy.evaluate() == .lockedPendingPurchase)

        ledger.markUnlocked()
        #expect(policy.evaluate() == .admit)
    }

    @Test @MainActor
    func purchaseAndRestoreUnlockThroughFakeStoreKitClient() async throws {
        let url = temporaryQuotaURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let now = start.addingTimeInterval(80 * 3600)
        let ledger = TrialQuotaLedger(
            fileURL: url,
            keychain: InMemoryTrialStartTimestampStore(),
            now: { now }
        )
        _ = ledger.ensureTrialStarted(at: start)
        let client = FakePurchaseUnlockClient(entitled: false, price: "¥30")
        let controller = TrialEntitlementController(ledger: ledger, client: client)
        controller.start()
        await controller.refreshFromStore()

        #expect(controller.isPurchaseLocked == true)
        #expect(controller.displayPrice == "¥30")
        #expect(controller.remainingTimeText == "已到期")

        var unlockedCalls = 0
        controller.onUnlocked = { unlockedCalls += 1 }
        await controller.purchase()
        #expect(controller.isUnlocked == true)
        #expect(controller.isPurchaseLocked == false)
        #expect(unlockedCalls == 1)
        #expect(controller.statusMessage?.contains("永久解锁") == true)

        let restoreLedger = TrialQuotaLedger(
            fileURL: temporaryQuotaURL(),
            keychain: InMemoryTrialStartTimestampStore(),
            now: { now }
        )
        _ = restoreLedger.ensureTrialStarted(at: start)
        let restoreClient = FakePurchaseUnlockClient(entitled: true, price: "¥30")
        let restoreController = TrialEntitlementController(ledger: restoreLedger, client: restoreClient)
        var restoreUnlocks = 0
        restoreController.onUnlocked = { restoreUnlocks += 1 }
        await restoreController.restore()
        #expect(restoreController.isUnlocked == true)
        #expect(restoreUnlocks == 1)
    }

    @Test @MainActor
    func storeOfflinePurchaseSurfacesErrorWithoutUnlocking() async throws {
        let url = temporaryQuotaURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let now = start.addingTimeInterval(80 * 3600)
        let ledger = TrialQuotaLedger(
            fileURL: url,
            keychain: InMemoryTrialStartTimestampStore(),
            now: { now }
        )
        _ = ledger.ensureTrialStarted(at: start)
        let client = FakePurchaseUnlockClient(shouldFailPurchase: true)
        let controller = TrialEntitlementController(ledger: ledger, client: client)
        await controller.purchase()
        #expect(controller.isUnlocked == false)
        #expect(controller.isPurchaseLocked == true)
        #expect(controller.statusMessage?.contains("App Store") == true)
    }

    @Test @MainActor
    func remainingTimeTextUsesHoursAndMinutesNotVoiceQuota() throws {
        let url = temporaryQuotaURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let now = start.addingTimeInterval(2 * 3600 + 15 * 60)
        let ledger = TrialQuotaLedger(
            fileURL: url,
            keychain: InMemoryTrialStartTimestampStore(),
            now: { now }
        )
        _ = ledger.ensureTrialStarted(at: start)
        let controller = TrialEntitlementController(
            ledger: ledger,
            client: FakePurchaseUnlockClient(entitled: false)
        )
        controller.noteAppBecameActive()
        #expect(controller.remainingTimeText.contains("小时"))
        #expect(controller.remainingTimeText.contains("分钟"))
        #expect(!controller.remainingTimeText.contains("60"))
        #expect(!controller.availabilityCaption.contains("语音秒"))
        #expect(!controller.availabilityCaption.contains("60 分钟"))
    }

    @Test func schedulerFreezesWhenTrialExpiredAndResumesAfterUnlock() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("trial-scheduler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let ledgerURL = root.appendingPathComponent("quota.json")
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let now = start.addingTimeInterval(80 * 3600)
        let ledger = TrialQuotaLedger(
            fileURL: ledgerURL,
            keychain: InMemoryTrialStartTimestampStore(),
            now: { now }
        )
        _ = ledger.ensureTrialStarted(at: start)
        #expect(ledger.isPurchaseLocked == true)

        let repository = try RecordingRepository(rootURL: root.appendingPathComponent("repo"))
        let recording = Recording(startedAt: .distantPast, state: .processing)
        try await repository.createRecording(recording, at: recording.startedAt)
        let gate = InferenceLifecycleGate()
        let executor = TrialSchedulerExecutorProbe()
        let scheduler = ForegroundTranscriptionScheduler(
            repository: repository,
            lifecycleGate: gate,
            admissionPolicy: TranscriptionAdmissionPolicy(
                thermalState: { .nominal },
                isPurchaseLocked: { ledger.isPurchaseLocked }
            )
        ) { lease in
            try await gate.beginMetalWork()
            await executor.record(lease.recordingID)
            await gate.endMetalWork()
        }

        try await scheduler.enqueue(recordingID: recording.id, chunkID: UUID()) { _ in }
        await scheduler.waitForIdle()
        #expect(await executor.recordingIDs.isEmpty)
        let lockedJob = try #require(await repository.jobs(recordingID: recording.id).first)
        #expect(lockedJob.state == .pending)
        #expect(lockedJob.lastError == "lockedPendingPurchase")

        ledger.markUnlocked()
        await scheduler.requestDrain()
        await scheduler.waitForIdle()

        #expect(await executor.recordingIDs == [recording.id])
        let completed = try #require(await repository.jobs(recordingID: recording.id).first)
        #expect(completed.state == .completed)
        #expect(await gate.metrics().submittedMetalWork == 1)
    }

    @Test @MainActor
    func recordingCoreModelWiresAdmissionLockFromInjectedLedger() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("trial-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let now = start.addingTimeInterval(80 * 3600)
        let ledger = TrialQuotaLedger(
            fileURL: root.appendingPathComponent("quota.json"),
            keychain: InMemoryTrialStartTimestampStore(),
            now: { now }
        )
        _ = ledger.ensureTrialStarted(at: start)
        let client = FakePurchaseUnlockClient(entitled: false, price: "¥30")
        let model = try RecordingCoreModel(
            rootURL: root.appendingPathComponent("VoiceContext"),
            trialLedger: ledger,
            purchaseClient: client
        )
        #expect(model.trialEntitlement.isPurchaseLocked == true)

        await model.trialEntitlement.purchase()
        await model.resumeTranscriptionAfterUnlock()
        #expect(model.trialEntitlement.isPurchaseLocked == false)
        #expect(model.trialEntitlement.isUnlocked == true)
    }

    @Test @MainActor
    func scenePhaseActiveStartsManualTrialClockWhenActive() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("trial-scene-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let ledger = TrialQuotaLedger(
            fileURL: root.appendingPathComponent("quota.json"),
            keychain: InMemoryTrialStartTimestampStore()
        )
        #expect(ledger.trialStartedAt == nil)
        let model = try RecordingCoreModel(
            rootURL: root.appendingPathComponent("VoiceContext"),
            trialLedger: ledger,
            purchaseClient: FakePurchaseUnlockClient(entitled: false, price: "¥30")
        )
        model.scenePhaseChanged(to: .active)
        #expect(TrialQuotaLedger.isManualTrialEnabled == true)
        #expect(ledger.trialStartedAt != nil)
        #expect(model.trialEntitlement.trialStartedAt != nil)
    }

    @Test func productionAdmissionHonorsPurchaseLockWhenTrialEnabled() {
        #expect(TrialQuotaLedger.isManualTrialEnabled == true)
        let policy = TranscriptionAdmissionPolicy(
            isPurchaseLocked: {
                TrialQuotaLedger.isManualTrialEnabled && true
            }
        )
        #expect(policy.evaluate() == .lockedPendingPurchase)
    }

    @Test
    func multiRecordingTranscriptionBlocksDuringLockAndDrainsSequentiallyAfterUnlock() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("trial-multi-sched-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let ledgerURL = root.appendingPathComponent("quota.json")
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let now = start.addingTimeInterval(73 * 3600) // expired
        let ledger = TrialQuotaLedger(
            fileURL: ledgerURL,
            keychain: InMemoryTrialStartTimestampStore(),
            now: { now }
        )
        _ = ledger.ensureTrialStarted(at: start)
        #expect(ledger.isPurchaseLocked == true)

        let repository = try RecordingRepository(rootURL: root.appendingPathComponent("repo"))
        let recordingA = Recording(startedAt: start, state: .processing)
        let recordingB = Recording(startedAt: start.addingTimeInterval(60), state: .processing)
        try await repository.createRecording(recordingA, at: recordingA.startedAt)
        try await repository.createRecording(recordingB, at: recordingB.startedAt)

        let gate = InferenceLifecycleGate()
        let executor = TrialSchedulerExecutorProbe()
        let scheduler = ForegroundTranscriptionScheduler(
            repository: repository,
            lifecycleGate: gate,
            admissionPolicy: TranscriptionAdmissionPolicy(
                thermalState: { .nominal },
                isPurchaseLocked: { ledger.isPurchaseLocked }
            )
        ) { lease in
            try await gate.beginMetalWork()
            await executor.record(lease.recordingID)
            await gate.endMetalWork()
        }

        // Enqueue 2 chunks for Recording A and 2 chunks for Recording B
        let chunkA1 = UUID()
        let chunkA2 = UUID()
        let chunkB1 = UUID()
        let chunkB2 = UUID()

        try await scheduler.enqueue(recordingID: recordingA.id, chunkID: chunkA1) { _ in }
        try await scheduler.enqueue(recordingID: recordingA.id, chunkID: chunkA2) { _ in }
        try await scheduler.enqueue(recordingID: recordingB.id, chunkID: chunkB1) { _ in }
        try await scheduler.enqueue(recordingID: recordingB.id, chunkID: chunkB2) { _ in }
        await scheduler.waitForIdle()

        // Admission gate must block all 4 jobs during lock
        #expect(await executor.recordingIDs.isEmpty)
        let jobsA = try await repository.jobs(recordingID: recordingA.id)
        let jobsB = try await repository.jobs(recordingID: recordingB.id)
        #expect(jobsA.count == 2)
        #expect(jobsB.count == 2)
        #expect(jobsA.allSatisfy { $0.state == .pending })
        #expect(jobsB.allSatisfy { $0.state == .pending })

        // Unlock and drain
        ledger.markUnlocked()
        await scheduler.requestDrain()
        await scheduler.waitForIdle()

        // All 4 jobs must execute
        let executed = await executor.recordingIDs
        #expect(executed.count == 4)
        #expect(executed.filter { $0 == recordingA.id }.count == 2)
        #expect(executed.filter { $0 == recordingB.id }.count == 2)

        let completedA = try await repository.jobs(recordingID: recordingA.id)
        let completedB = try await repository.jobs(recordingID: recordingB.id)
        #expect(completedA.allSatisfy { $0.state == .completed })
        #expect(completedB.allSatisfy { $0.state == .completed })
    }

    @Test @MainActor
    func trialEntitlementTestingHelpersTriggerStateChange() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("trial-helper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let ledger = TrialQuotaLedger(
            fileURL: root.appendingPathComponent("quota.json"),
            keychain: InMemoryTrialStartTimestampStore()
        )
        let controller = TrialEntitlementController(
            ledger: ledger,
            client: FakePurchaseUnlockClient(entitled: false, price: "¥30")
        )

        var changeNotified = false
        controller.onTrialStateChanged = {
            changeNotified = true
        }

        controller.simulateExhaustionForTesting()
        #expect(controller.isPurchaseLocked == true)

        controller.resetTrialForTesting()
        #expect(controller.isPurchaseLocked == false)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(changeNotified == true)
    }
}

private actor TrialSchedulerExecutorProbe {
    private(set) var recordingIDs: [UUID] = []

    func record(_ recordingID: UUID) {
        recordingIDs.append(recordingID)
    }
}

/// Mutable clock for wall-time trial tests (avoids capturing `var` in @Sendable closures).
private final class TrialTestClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

private func temporaryQuotaURL() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("trial-quota-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("quota.json")
}
