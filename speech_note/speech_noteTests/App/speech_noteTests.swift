//
//  speech_noteTests.swift
//  speech_noteTests
//
//  Created by scott on 2026/8/3.
//

import Testing
@preconcurrency import AVFoundation
import CryptoKit
import Foundation
@testable import speech_note

struct speech_noteTests {

    @Test func onboardingPreferencesKeepCloudChoicesIndependentAndCanFinish() {
        let suiteName = "OnboardingPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var preferences = OnboardingPreferences(defaults: defaults)

        #expect(!preferences.hasCompleted)
        #expect(!preferences.documentSyncEnabled)
        #expect(!preferences.encryptedVoiceprintSyncEnabled)

        preferences.documentSyncEnabled = true
        #expect(preferences.documentSyncEnabled)
        #expect(!preferences.encryptedVoiceprintSyncEnabled)

        preferences.encryptedVoiceprintSyncEnabled = true
        preferences.hasCompleted = true
        #expect(preferences.hasCompleted)
        #expect(preferences.documentSyncEnabled)
        #expect(preferences.encryptedVoiceprintSyncEnabled)
    }

    @Test func offlineLicenseCatalogCoversEveryBundledRuntimeAndModel() {
        let names = Set(ThirdPartyAttribution.catalog.map(\.name))

        #expect(names == [
            "SenseVoice Small / FunASR",
            "transcribe.cpp",
            "sherpa-onnx",
            "ONNX Runtime",
            "Silero VAD",
            "CAM++ / 3D-Speaker",
            "pyannote segmentation 3.0",
        ])
        #expect(ThirdPartyAttribution.catalog.allSatisfy { !$0.license.isEmpty && !$0.reviewStatus.isEmpty })
        #expect(ThirdPartyAttribution.catalog.allSatisfy { !$0.offlineLicenseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        #expect(ThirdPartyAttribution.catalog.allSatisfy { $0.sourceURL.scheme == "https" && $0.licenseURL.scheme == "https" })
    }

    @Test func legalReviewChecklistCoversAttributionsAndPublishGates() {
        let checklistIDs = Set(LegalReviewChecklist.items.map(\.id))
        #expect(checklistIDs == [
            "funasr-model-license",
            "transcribe-cpp-mit",
            "sherpa-onnx-apache",
            "onnxruntime-mit",
            "silero-vad-mit",
            "camplusplus-license",
            "offline-attribution-ui",
            "microphone-usage-copy",
        ])

        let catalogNames = Set(ThirdPartyAttribution.catalog.map(\.name))
        #expect(!LegalReviewChecklist.blocksCommercialRelease)
        #expect(LegalReviewChecklist.items.contains { $0.id == "funasr-model-license" && $0.status == .satisfied })
        #expect(LegalReviewChecklist.items.contains { $0.id == "camplusplus-license" && $0.status == .satisfied })
        #expect(LegalReviewChecklist.items.contains { $0.id == "offline-attribution-ui" && $0.status == .satisfied })
        #expect(LegalReviewChecklist.items.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty })
    }

    @Test func microphoneAccessCopyNeverImpliesRecordingWithoutClick() {
        #expect(MicrophoneAccess.undeterminedHint.contains("开始录音"))
        #expect(MicrophoneAccess.deniedBrowseMessage.contains("仍可浏览"))
        #expect(MicrophoneAccess.deniedStartMessage.contains("无法开始录音"))
        #expect(MicrophoneAccess.description(for: .denied).contains("仍可浏览"))
        #expect(MicrophoneAccess.settingsURL.absoluteString.contains("App-Prefs") || MicrophoneAccess.settingsURL.scheme == "app-settings" || !MicrophoneAccess.settingsURL.absoluteString.isEmpty)
    }

    @Test @MainActor func onboardingMicrophoneContinueAlwaysReachesSystemPrompt() {
        #expect(OnboardingMicrophoneAdvance.shouldRequestSystemPrompt(.undetermined))
        #expect(!OnboardingMicrophoneAdvance.shouldRequestSystemPrompt(.granted))
        #expect(!OnboardingMicrophoneAdvance.shouldRequestSystemPrompt(.denied))

        #expect(
            OnboardingMicrophoneAdvance.action(permissionBefore: .undetermined, permissionAfter: .granted)
            == .advance
        )
        #expect(
            OnboardingMicrophoneAdvance.action(permissionBefore: .undetermined, permissionAfter: .denied)
            == .stayToShowSettings
        )
        #expect(
            OnboardingMicrophoneAdvance.action(permissionBefore: .granted, permissionAfter: .granted)
            == .advance
        )
        #expect(
            OnboardingMicrophoneAdvance.action(permissionBefore: .denied, permissionAfter: .denied)
            == .advance
        )
    }

    @Test func onboardingStepsStayOrderedAndIndependentOfCloud() {
        #expect(OnboardingStep.allCases.map(\.rawValue) == [0, 1, 2, 3])
        #expect(OnboardingStep.privacy.rawValue < OnboardingStep.microphone.rawValue)
        #expect(OnboardingStep.microphone.rawValue < OnboardingStep.iCloud.rawValue)
        #expect(OnboardingStep.iCloud.rawValue < OnboardingStep.trial.rawValue)

        let suiteName = "OnboardingSkipIndependence.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var preferences = OnboardingPreferences(defaults: defaults)
        preferences.hasCompleted = true
        #expect(preferences.hasCompleted)
        #expect(!preferences.documentSyncEnabled)
        #expect(!preferences.encryptedVoiceprintSyncEnabled)
    }

    @Test func modelIntegrityRejectsMissingAndAlteredResources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let bytes = Data("known model bytes".utf8)
        let artifact = ModelArtifact(
            id: "fixture",
            relativePath: "fixture.onnx",
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            sourceURL: URL(string: "https://example.com/model")!,
            licenseURL: URL(string: "https://example.com/license")!
        )

        #expect(throws: ModelIntegrityError.missing("fixture.onnx")) {
            try ModelIntegrity.validate(artifact, in: root)
        }

        let file = root.appendingPathComponent(artifact.relativePath)
        try bytes.write(to: file)
        try ModelIntegrity.validate(artifact, in: root)

        try Data("altered".utf8).write(to: file)
        do {
            try ModelIntegrity.validate(artifact, in: root)
            Issue.record("Altered model resource was accepted")
        } catch let error as ModelIntegrityError {
            guard case .digestMismatch(let id, let expected, let actual) = error else {
                Issue.record("Unexpected validation error: \(error)")
                return
            }
            #expect(id == "fixture")
            #expect(expected == artifact.sha256)
            let alteredDigest = try ModelIntegrity.sha256(of: file)
            #expect(actual == alteredDigest)
        }
    }

    @Test func inferenceGateNeverAdmitsMetalWorkInBackground() async throws {
        let gate = InferenceLifecycleGate()
        try await gate.beginMetalWork()
        await gate.enteredBackground()
        await #expect(throws: InferenceLifecycleGate.Rejection.appIsBackgrounded) {
            try await gate.beginMetalWork()
        }
        #expect(await gate.metrics() == .init(
            acceptsMetalWork: false,
            submittedMetalWork: 1,
            inFlightMetalWork: 1,
            peakInFlightMetalWork: 1
        ))
        await gate.endMetalWork()
        #expect(await gate.metrics().inFlightMetalWork == 0)
    }

    @Test func inferenceGateEnforcesGlobalMetalInFlightMaxOfOne() async throws {
        let gate = InferenceLifecycleGate()
        try await gate.beginMetalWork()
        await #expect(throws: InferenceLifecycleGate.Rejection.metalBusy) {
            try await gate.beginMetalWork()
        }
        #expect(await gate.metrics().inFlightMetalWork == 1)
        #expect(await gate.metrics().peakInFlightMetalWork == 1)
        #expect(await gate.metrics().submittedMetalWork == 1)

        await gate.endMetalWork()
        try await gate.beginMetalWork()
        #expect(await gate.metrics().submittedMetalWork == 2)
        #expect(await gate.metrics().inFlightMetalWork == 1)
        await gate.endMetalWork()
    }

    @Test func sharedGatePreventsTwoConcurrentSchedulersFromExceedingMetalInFlightOne() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metal-inflight-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repositoryA = try RecordingRepository(rootURL: root.appendingPathComponent("a"))
        let repositoryB = try RecordingRepository(rootURL: root.appendingPathComponent("b"))
        let sharedGate = InferenceLifecycleGate()
        let recordingA = Recording(startedAt: .distantPast, state: .processing)
        let recordingB = Recording(startedAt: .distantPast, state: .processing)
        try await repositoryA.createRecording(recordingA, at: recordingA.startedAt)
        try await repositoryB.createRecording(recordingB, at: recordingB.startedAt)

        let peakProbe = MetalPeakProbe(gate: sharedGate)
        let started = MetalStartBarrier(count: 2)

        let admitMetal: @Sendable () async throws -> Void = {
            await started.arriveAndWait()
            // Contending schedulers retry on metalBusy instead of failing the job.
            while true {
                do {
                    try await sharedGate.beginMetalWork()
                    break
                } catch InferenceLifecycleGate.Rejection.metalBusy {
                    await peakProbe.sample()
                    await Task.yield()
                }
            }
            await peakProbe.sample()
            // Yield so the sibling can observe the busy gate before we release.
            await Task.yield()
            await Task.yield()
            await sharedGate.endMetalWork()
        }
        let schedulerA = ForegroundTranscriptionScheduler(
            repository: repositoryA,
            lifecycleGate: sharedGate
        ) { _ in
            try await admitMetal()
        }
        let schedulerB = ForegroundTranscriptionScheduler(
            repository: repositoryB,
            lifecycleGate: sharedGate
        ) { _ in
            try await admitMetal()
        }

        try await schedulerA.enqueue(recordingID: recordingA.id, chunkID: UUID()) { _ in }
        try await schedulerB.enqueue(recordingID: recordingB.id, chunkID: UUID()) { _ in }
        await schedulerA.waitForIdle()
        await schedulerB.waitForIdle()

        #expect(await peakProbe.peak() <= 1)
        #expect(await sharedGate.metrics().peakInFlightMetalWork <= 1)
        #expect(await sharedGate.metrics().inFlightMetalWork == 0)
        #expect(try await repositoryA.jobs(recordingID: recordingA.id)[0].state == .completed)
        #expect(try await repositoryB.jobs(recordingID: recordingB.id)[0].state == .completed)
        #expect(await sharedGate.metrics().submittedMetalWork == 2)
    }

    @Test func admissionPolicyAdmitsUnderThermalAndLocksPurchaseWithoutAdmit() {
        let thermal = TranscriptionAdmissionPolicy(
            thermalState: { .serious },
            isPurchaseLocked: { false }
        )
        #expect(thermal.evaluate() == .admit)

        let critical = TranscriptionAdmissionPolicy(
            thermalState: { .critical },
            isPurchaseLocked: { false }
        )
        #expect(critical.evaluate() == .admit)

        let locked = TranscriptionAdmissionPolicy(
            thermalState: { .nominal },
            isPurchaseLocked: { true }
        )
        #expect(locked.evaluate() == .lockedPendingPurchase)

        let admit = TranscriptionAdmissionPolicy(
            thermalState: { .fair },
            isPurchaseLocked: { false }
        )
        #expect(admit.evaluate() == .admit)
    }

    @Test func transcriptDocumentUsesPassedDetectedLanguageInsteadOfHardcodedZh() {
        let recording = Recording(startedAt: .distantPast, endedAt: .distantPast, state: .processing)
        let chunk = AudioChunk(
            recordingID: recording.id,
            relativePath: "Recordings/a.m4a",
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
        #expect(document.language == "en")
        #expect(document.language != "zh")
    }

    @Test func pcmLoaderReadsAACWithoutAnEOFRead() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sensevoice-fixture.m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096)!
            buffer.frameLength = 4_096
            buffer.floatChannelData![0].initialize(repeating: 0.2, count: Int(buffer.frameLength))
            try file.write(from: buffer)
        }

        let samples = try PCM16KMonoLoader.samples(from: url)
        #expect(!samples.isEmpty)
    }

    @Test func pcmLoaderTreatsTruncatedAACAsUnreadable() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "truncated-\(UUID().uuidString).m4a"
        )
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0, count: 64).write(to: url)

        #expect(!PCM16KMonoLoader.isReadable(url))
        do {
            _ = try PCM16KMonoLoader.samples(from: url)
            Issue.record("expected unreadableAudio")
        } catch SenseVoiceInferenceService.InferenceError.unreadableAudio {
            // Interrupted capture can leave m4a files without a moov atom.
        }
    }

    @Test func vadUtteranceAssemblyKeepsNearbySpeechAndSplitsLongGaps() {
        let source = Array(repeating: Float(0.2), count: 70_000)
        let spans = [
            SpeechAnalysisService.SpeechSpan(startSample: 0, endSample: 8_000),
            SpeechAnalysisService.SpeechSpan(startSample: 12_000, endSample: 20_000),
            SpeechAnalysisService.SpeechSpan(startSample: 50_000, endSample: 60_000),
        ]

        let utterances = SpeechAnalysisService.makeUtterances(from: spans, sourceSamples: source)

        #expect(utterances.count == 2)
        #expect(utterances[0].spanCount == 2)
        #expect(utterances[0].startSample == 0)
        #expect(utterances[0].endSample == 20_000)
        #expect(utterances[0].speechSpans == Array(spans.prefix(2)))
        #expect(utterances[0].samples.count == 20_000)
        #expect(utterances[1].spanCount == 1)
        #expect(utterances[1].startSample == 50_000)
        #expect(utterances[1].endSample == 60_000)
        #expect(utterances[1].samples.count == 10_000)
    }

    @Test func senseVoicePreservesBoundedVADUtterancesAsSeparateMetalInputs() {
        let utterances = [
            SpeechAnalysisService.Utterance(
                startSample: 0,
                endSample: 160_000,
                samples: Array(repeating: 0.1, count: 160_000),
                speechSpans: [.init(startSample: 0, endSample: 160_000)]
            ),
            SpeechAnalysisService.Utterance(
                startSample: 160_000,
                endSample: 400_000,
                samples: Array(repeating: 0.2, count: 240_000),
                speechSpans: [.init(startSample: 160_000, endSample: 400_000)]
            ),
        ]

        let inputs = SenseVoiceInferenceService.inferenceInputs(from: utterances)

        #expect(inputs.map(\.count) == [160_000, 240_000])
        #expect(inputs.count == utterances.count)
    }

    @Test func senseVoiceHardCapsContinuousSpeechBelowTheModelLimit() {
        let hardLimit = Int(SpeechAnalysisService.hardMaximumUtteranceSamples)
        let continuous = SpeechAnalysisService.Utterance(
            startSample: 0,
            endSample: Int64(hardLimit * 2 + 123),
            samples: Array(repeating: 0.1, count: hardLimit * 2 + 123),
            speechSpans: [.init(startSample: 0, endSample: Int64(hardLimit * 2 + 123))]
        )

        let inputs = SenseVoiceInferenceService.inferenceInputs(from: [continuous])

        #expect(inputs.map(\.count) == [hardLimit, hardLimit, 123])
        #expect(inputs.allSatisfy { $0.count <= hardLimit })
    }

    @Test func senseVoiceBoundsLegacyFiveMinuteChunksBeforeSpeechAnalysis() {
        let minute = Int(AACSegmentRecorder.targetSampleRate * 60)

        let ranges = SenseVoiceInferenceService.analysisRanges(sampleCount: minute * 5 + 123)

        #expect(ranges.count == 6)
        #expect(ranges.dropLast().allSatisfy { $0.count == minute })
        #expect(ranges.last?.count == 123)
        #expect(ranges.first?.lowerBound == 0)
        #expect(ranges.last?.upperBound == minute * 5 + 123)
    }

    @Test func utteranceAssemblyPreservesAbsoluteOffsetsAcrossChunks() {
        let chunks = [
            SpeechAnalysisService.SampleChunk(
                startSample: 100_000,
                samples: Array(repeating: Float(0.1), count: 10_000)
            ),
            SpeechAnalysisService.SampleChunk(
                startSample: 110_000,
                samples: Array(repeating: Float(0.2), count: 20_000)
            ),
        ]
        let spans = [
            SpeechAnalysisService.SpeechSpan(startSample: 105_000, endSample: 108_000),
            SpeechAnalysisService.SpeechSpan(startSample: 112_000, endSample: 118_000),
        ]

        let utterances = SpeechAnalysisService.makeUtterances(from: spans, sourceChunks: chunks)

        #expect(utterances.count == 1)
        #expect(utterances[0].startSample == 105_000)
        #expect(utterances[0].endSample == 118_000)
        #expect(utterances[0].speechSpans == spans)
        #expect(utterances[0].samples.count == 13_000)
        #expect(utterances[0].samples.first == 0.1)
        #expect(utterances[0].samples.last == 0.2)
    }

    @Test func utteranceAssemblyHardCutsTwentySixSecondsWithoutLosingAbsoluteOffsets() {
        let start: Int64 = 48_000
        let samples = Array(repeating: Float(0.2), count: 26 * 16_000)
        let spans = [SpeechAnalysisService.SpeechSpan(
            startSample: start,
            endSample: start + Int64(samples.count)
        )]

        let utterances = SpeechAnalysisService.makeUtterances(
            from: spans,
            sourceSamples: samples,
            sourceStartSample: start
        )

        #expect(utterances.count == 2)
        #expect(utterances[0].startSample == start)
        #expect(utterances[0].endSample == start + 25 * 16_000)
        #expect(utterances[0].duration == 25)
        #expect(utterances[1].startSample == utterances[0].endSample)
        #expect(utterances[1].endSample == spans[0].endSample)
        #expect(utterances[1].duration == 1)
        #expect(utterances.flatMap(\.speechSpans) == [
            .init(startSample: start, endSample: start + 25 * 16_000),
            .init(startSample: start + 25 * 16_000, endSample: spans[0].endSample),
        ])
        #expect(utterances.reduce(0) { $0 + $1.samples.count } == samples.count)
    }

    @Test func fourContinuousFifteenSecondVADSpansBecomeTwentyFiveTwentyFiveTen() {
        let seconds: Int64 = 16_000
        let totalSamples = 60 * seconds
        let source = Array(repeating: Float(0.2), count: Int(totalSamples))
        let spans = (0..<4).map { index in
            SpeechAnalysisService.SpeechSpan(
                startSample: Int64(index) * 15 * seconds,
                endSample: Int64(index + 1) * 15 * seconds
            )
        }

        let utterances = SpeechAnalysisService.makeUtterances(
            from: spans,
            sourceSamples: source
        )

        #expect(utterances.map { $0.endSample - $0.startSample } == [
            25 * seconds,
            25 * seconds,
            10 * seconds,
        ])
        #expect(utterances.map(\.startSample) == [0, 25 * seconds, 50 * seconds])
        #expect(utterances.map(\.endSample) == [25 * seconds, 50 * seconds, totalSamples])
        #expect(utterances.reduce(0) { $0 + $1.samples.count } == source.count)
        #expect(zip(utterances, utterances.dropFirst()).allSatisfy {
            $0.endSample == $1.startSample
        })
        #expect(utterances.allSatisfy {
            $0.endSample - $0.startSample <= SpeechAnalysisService.hardMaximumUtteranceSamples
        })
    }

    @Test func utteranceAssemblyRejectsSilenceAndRangesMissingFromChunks() {
        #expect(SpeechAnalysisService.makeUtterances(
            from: [],
            sourceSamples: Array(repeating: 0, count: 16_000)
        ).isEmpty)

        let chunks = [
            SpeechAnalysisService.SampleChunk(startSample: 0, samples: Array(repeating: 0.1, count: 4_000)),
            SpeechAnalysisService.SampleChunk(startSample: 8_000, samples: Array(repeating: 0.1, count: 4_000)),
        ]
        let span = SpeechAnalysisService.SpeechSpan(startSample: 2_000, endSample: 10_000)
        #expect(SpeechAnalysisService.makeUtterances(from: [span], sourceChunks: chunks).isEmpty)
    }

    @Test func incrementalAssemblyCarriesOneUtteranceAcrossTwoMinuteChunks() throws {
        let firstID = UUID()
        let secondID = UUID()
        let boundary: Int64 = 960_000
        let utteranceStart: Int64 = 950_400
        let utteranceEnd: Int64 = 979_200
        let first = analyzedChunk(
            id: firstID,
            sequence: 0,
            range: 0..<boundary,
            speech: [utteranceStart..<boundary],
            endsWithOpenSpeech: true
        )
        let second = analyzedChunk(
            id: secondID,
            sequence: 1,
            range: boundary..<(2 * boundary),
            speech: [boundary..<utteranceEnd],
            endsWithOpenSpeech: false
        )

        let firstResult = try SpeechAnalysisService.assembleIncrementally(chunk: first)
        let carry = try #require(firstResult.carry)
        let secondResult = try SpeechAnalysisService.assembleIncrementally(
            chunk: second,
            carrying: carry
        )
        let utterance = try #require(secondResult.utterances.only)

        #expect(firstResult.utterances.isEmpty)
        #expect(secondResult.carry == nil)
        #expect(utterance.startSample == utteranceStart)
        #expect(utterance.endSample == utteranceEnd)
        #expect(abs(utterance.duration - 1.8) < 0.000_1)
        #expect(utterance.termination == .naturalPause)
        #expect(utterance.sourceRanges == [
            .init(
                chunkID: firstID,
                chunkSequence: 0,
                localStartSample: utteranceStart,
                localEndSample: boundary,
                startSample: utteranceStart,
                endSample: boundary
            ),
            .init(
                chunkID: secondID,
                chunkSequence: 1,
                localStartSample: 0,
                localEndSample: utteranceEnd - boundary,
                startSample: boundary,
                endSample: utteranceEnd
            ),
        ])
    }

    @Test func ordinaryAudioChunkBoundaryDoesNotFlushOpenSpeech() throws {
        let boundary: Int64 = 960_000
        let chunk = analyzedChunk(
            sequence: 0,
            range: 0..<boundary,
            speech: [(boundary - 8_000)..<boundary],
            endsWithOpenSpeech: true
        )

        let result = try SpeechAnalysisService.assembleIncrementally(chunk: chunk)
        let carry = try #require(result.carry)

        #expect(result.utterances.isEmpty)
        #expect(carry.startSample == boundary - 8_000)
        #expect(carry.endSample == boundary)
        #expect(carry.sourceRanges.count == 1)
        #expect(carry.sourceRanges[0].endSample == boundary)
    }

    @Test func incrementalAssemblyHardCutsAtTwentyFiveSecondsWithoutLosingShortTail() throws {
        let sampleRate: Int64 = 16_000
        let sourceEnd = 26 * sampleRate
        let chunk = analyzedChunk(
            sequence: 0,
            range: 0..<(30 * sampleRate),
            speech: [0..<sourceEnd],
            endsWithOpenSpeech: false
        )

        let result = try SpeechAnalysisService.assembleIncrementally(
            chunk: chunk,
            isFinalChunk: true
        )

        #expect(result.carry == nil)
        #expect(result.utterances.count == 2)
        #expect(result.utterances[0].startSample == 0)
        #expect(result.utterances[0].endSample == 25 * sampleRate)
        #expect(result.utterances[0].termination == .hardLimit)
        #expect(result.utterances[1].startSample == 25 * sampleRate)
        #expect(result.utterances[1].endSample == sourceEnd)
        #expect(result.utterances[1].duration == 1)
        #expect(result.utterances[1].termination == .endOfRecording)
        #expect(result.utterances.flatMap(\.sourceRanges).map { $0.endSample - $0.startSample }.reduce(0, +) == sourceEnd)
        #expect(result.utterances[0].endSample == result.utterances[1].startSample)
    }

    @Test func shortCandidateIsNotTargetCutBeforeMinimumDuration() throws {
        let sampleRate: Int64 = 16_000
        let shortEnd = sampleRate
        let nextStart = shortEnd + sampleRate / 2
        let speechEnd = 26 * sampleRate
        let chunk = analyzedChunk(
            sequence: 0,
            range: 0..<(30 * sampleRate),
            speech: [0..<shortEnd, nextStart..<speechEnd],
            endsWithOpenSpeech: false
        )

        let result = try SpeechAnalysisService.assembleIncrementally(
            chunk: chunk,
            isFinalChunk: true
        )

        #expect(result.utterances.count == 2)
        #expect(result.utterances[0].startSample == 0)
        #expect(result.utterances[0].endSample == 25 * sampleRate)
        #expect(result.utterances[0].termination == .hardLimit)
        #expect(!result.utterances.contains { utterance in
            utterance.termination == .targetDuration
                && utterance.endSample - utterance.startSample < 3 * sampleRate
        })
        #expect(result.utterances.last?.endSample == speechEnd)
    }

    @Test func eligibleCandidateUsesShortPauseAsTargetDurationCut() throws {
        let sampleRate: Int64 = 16_000
        let firstEnd = 4 * sampleRate
        let nextStart = firstEnd + sampleRate / 2
        let speechEnd = 16 * sampleRate
        let chunk = analyzedChunk(
            sequence: 0,
            range: 0..<(20 * sampleRate),
            speech: [0..<firstEnd, nextStart..<speechEnd],
            endsWithOpenSpeech: false
        )

        let result = try SpeechAnalysisService.assembleIncrementally(
            chunk: chunk,
            isFinalChunk: true
        )

        #expect(result.utterances.count == 2)
        #expect(result.utterances[0].startSample == 0)
        #expect(result.utterances[0].endSample == firstEnd)
        #expect(result.utterances[0].termination == .targetDuration)
        #expect(result.utterances[1].startSample == nextStart)
        #expect(result.utterances[1].endSample == speechEnd)
        #expect(result.utterances[1].termination == .endOfRecording)
    }

    @Test func explicitGapsAndMissingAudioTerminateCarry() throws {
        let boundary: Int64 = 960_000
        let first = analyzedChunk(
            sequence: 0,
            range: 0..<boundary,
            speech: [(boundary - 8_000)..<boundary],
            endsWithOpenSpeech: true
        )
        let carry = try #require(
            SpeechAnalysisService.assembleIncrementally(chunk: first).carry
        )

        for kind in [
            SpeechAnalysisService.DiscontinuityKind.userPause,
            .systemInterruption,
        ] {
            let next = analyzedChunk(
                sequence: 1,
                range: boundary..<(2 * boundary),
                speech: [boundary..<(boundary + 8_000)],
                endsWithOpenSpeech: false
            )
            let result = try SpeechAnalysisService.assembleIncrementally(
                chunk: next,
                carrying: carry,
                discontinuities: [.init(
                    kind: kind,
                    startSample: boundary,
                    endSample: boundary
                )],
                isFinalChunk: true
            )
            #expect(result.utterances.first?.termination == .discontinuity(kind))
            #expect(result.utterances.first?.endSample == boundary)
            #expect(result.utterances.dropFirst().first?.startSample == boundary)
        }

        let missingStart = boundary + 4_000
        let afterMissingAudio = analyzedChunk(
            sequence: 2,
            range: missingStart..<(missingStart + boundary),
            speech: [missingStart..<(missingStart + 8_000)],
            endsWithOpenSpeech: false
        )
        let missingResult = try SpeechAnalysisService.assembleIncrementally(
            chunk: afterMissingAudio,
            carrying: carry,
            isFinalChunk: true
        )
        #expect(missingResult.utterances.first?.termination == .discontinuity(.missingAudio))
        #expect(missingResult.utterances.first?.endSample == boundary)
        #expect(missingResult.utterances.dropFirst().first?.startSample == missingStart)

        let gapStart: Int64 = 8_000
        let gapEnd: Int64 = 12_000
        let chunkWithMissingRange = analyzedChunk(
            sequence: 3,
            range: 0..<32_000,
            speech: [0..<24_000],
            endsWithOpenSpeech: false
        )
        let rangedMissingResult = try SpeechAnalysisService.assembleIncrementally(
            chunk: chunkWithMissingRange,
            discontinuities: [.init(
                kind: .missingAudio,
                startSample: gapStart,
                endSample: gapEnd
            )],
            isFinalChunk: true
        )
        #expect(rangedMissingResult.utterances.count == 2)
        #expect(rangedMissingResult.utterances[0].endSample == gapStart)
        #expect(rangedMissingResult.utterances[0].termination == .discontinuity(.missingAudio))
        #expect(rangedMissingResult.utterances[1].startSample == gapEnd)
        #expect(rangedMissingResult.utterances.flatMap(\.sourceRanges).allSatisfy { range in
            range.endSample <= gapStart || range.startSample >= gapEnd
        })
    }

    @Test func incrementalCarryCanSpanMoreThanTwoChunks() throws {
        let chunkLength: Int64 = 8 * 16_000
        let ids = [UUID(), UUID(), UUID()]
        var carry: SpeechAnalysisService.OpenUtteranceCarry?
        var finalized: [SpeechAnalysisService.FinalizedUtterance] = []

        for sequence in 0..<3 {
            let start = Int64(sequence) * chunkLength
            let end = start + chunkLength
            let result = try SpeechAnalysisService.assembleIncrementally(
                chunk: analyzedChunk(
                    id: ids[sequence],
                    sequence: sequence,
                    range: start..<end,
                    speech: [start..<end],
                    endsWithOpenSpeech: sequence < 2
                ),
                carrying: carry
            )
            finalized.append(contentsOf: result.utterances)
            carry = result.carry
        }

        let utterance = try #require(finalized.only)
        #expect(carry == nil)
        #expect(utterance.startSample == 0)
        #expect(utterance.endSample == 3 * chunkLength)
        #expect(utterance.duration == 24)
        #expect(utterance.sourceRanges.map(\.chunkID) == ids)
        #expect(utterance.sourceRanges.map(\.chunkSequence) == [0, 1, 2])
        #expect(utterance.sourceRanges.map(\.startSample) == [0, chunkLength, 2 * chunkLength])
        #expect(utterance.sourceRanges.map(\.endSample) == [chunkLength, 2 * chunkLength, 3 * chunkLength])
    }

    @Test func incrementalAssemblyReplayWithSameChunkAndCarryIsIdempotent() throws {
        let boundary: Int64 = 960_000
        let first = analyzedChunk(
            sequence: 0,
            range: 0..<boundary,
            speech: [(boundary - 8_000)..<boundary],
            endsWithOpenSpeech: true
        )
        let carry = try #require(
            SpeechAnalysisService.assembleIncrementally(chunk: first).carry
        )
        let second = analyzedChunk(
            sequence: 1,
            range: boundary..<(2 * boundary),
            speech: [boundary..<(boundary + 8_000)],
            endsWithOpenSpeech: false
        )

        let firstAttempt = try SpeechAnalysisService.assembleIncrementally(
            chunk: second,
            carrying: carry,
            isFinalChunk: true
        )
        let replay = try SpeechAnalysisService.assembleIncrementally(
            chunk: second,
            carrying: carry,
            isFinalChunk: true
        )

        #expect(replay == firstAttempt)
    }

    @Test func incrementalCarryAndFinalizedMetadataSurviveCodableRecovery() throws {
        let boundary: Int64 = 960_000
        let first = analyzedChunk(
            sequence: 0,
            range: 0..<boundary,
            speech: [(boundary - 8_000)..<boundary],
            endsWithOpenSpeech: true
        )
        let carry = try #require(
            SpeechAnalysisService.assembleIncrementally(chunk: first).carry
        )
        let carryData = try JSONEncoder().encode(carry)
        let restoredCarry = try JSONDecoder().decode(
            SpeechAnalysisService.OpenUtteranceCarry.self,
            from: carryData
        )
        #expect(restoredCarry == carry)

        let second = analyzedChunk(
            sequence: 1,
            range: boundary..<(2 * boundary),
            speech: [boundary..<(boundary + 8_000)],
            endsWithOpenSpeech: false
        )
        let finalized = try #require(
            SpeechAnalysisService.assembleIncrementally(
                chunk: second,
                carrying: restoredCarry,
                isFinalChunk: true
            ).utterances.only
        )
        let finalizedData = try JSONEncoder().encode(finalized)
        let restoredFinalized = try JSONDecoder().decode(
            SpeechAnalysisService.FinalizedUtterance.self,
            from: finalizedData
        )
        #expect(restoredFinalized == finalized)
    }

    @Test func unavailableEmbeddingNeverExposesASyntheticVector() {
        let unavailable = SpeakerEmbeddingResult.unavailable(reason: "CAM++ 未就绪")
        #expect(unavailable.vector == nil)

        let embedding = SpeakerEmbeddingResult.embedding([0.25, -0.5])
        #expect(embedding.vector == [0.25, -0.5])
    }

    @Test func camPlusEmbeddingIsL2NormalizedBeforeExposure() {
        let normalized = SpeechAnalysisService.normalizedEmbedding(from: [3, 4])
        guard case let .embedding(vector) = normalized.result else {
            Issue.record("Expected a normalized CAM++ embedding")
            return
        }

        #expect(abs((normalized.rawNorm ?? 0) - 5) < 0.000_1)
        #expect(abs(vector[0] - 0.6) < 0.000_1)
        #expect(abs(vector[1] - 0.8) < 0.000_1)
        #expect(abs((normalized.norm ?? 0) - 1) < 0.000_1)
    }

    @Test func speakerSimilarityUsesCosineAndRejectsInvalidVectors() {
        #expect(abs((SpeakerSimilarity.cosineSimilarity([3, 4], [6, 8]) ?? 0) - 1) < 0.000_1)
        #expect(abs(SpeakerSimilarity.cosineSimilarity([1, 0], [0, 1]) ?? 1) < 0.000_1)
        #expect(SpeakerSimilarity.cosineSimilarity([1], [1, 0]) == nil)
        #expect(SpeakerSimilarity.cosineSimilarity([0, 0], [1, 0]) == nil)
    }

    @Test func speakerSimilarityUsesAConservativeThreeWayDecision() {
        #expect(SpeakerSimilarity.decision(for: 0.80) == .likelySameSpeaker)
        #expect(SpeakerSimilarity.decision(for: 0.65) == .likelySameSpeaker)
        #expect(SpeakerSimilarity.decision(for: 0.60) == .uncertain)
        #expect(SpeakerSimilarity.decision(for: 0.55) == .likelyDifferentSpeaker)
        #expect(SpeakerSimilarity.decision(for: 0.50) == .likelyDifferentSpeaker)
        #expect(SpeakerSimilarity.decision(for: .nan) == nil)
        #expect(SpeakerSimilarity.decision(for: 1.01) == nil)
    }

    @Test func speakerWindowsUseTwoSecondOverlappingInputs() {
        let windows = SpeakerWindowing.makeWindows(
            samples: Array(repeating: Float(0.2), count: 5 * 16_000),
            startingAt: 32_000
        )

        #expect(windows.map(\.startSample) == [32_000, 48_000, 64_000, 80_000])
        #expect(windows.allSatisfy { $0.samples.count == 32_000 })
        #expect(windows.allSatisfy { $0.isEligibleForClustering })
    }

    @Test func speakerWindowQualityGateRejectsUnsafeInputs() {
        let quiet = SpeakerWindowing.makeWindows(
            samples: Array(repeating: Float(0.000_01), count: 2 * 16_000)
        ).first!
        #expect(quiet.exclusionReasons.contains(.lowEnergy))

        let clipped = SpeakerWindowing.makeWindows(
            samples: Array(repeating: Float(1), count: 2 * 16_000)
        ).first!
        #expect(clipped.exclusionReasons.contains(.lowQuality))

        let overlapping = SpeakerWindowing.makeWindows(
            samples: Array(repeating: Float(0.2), count: 2 * 16_000),
            startingAt: 100_000,
            suspectedOverlapRanges: [110_000..<120_000]
        ).first!
        #expect(overlapping.exclusionReasons.contains(.suspectedOverlappingSpeech))

        #expect(SpeakerWindowing.makeWindows(
            samples: Array(repeating: Float(0.2), count: 23_999)
        ).isEmpty)
    }

    @Test func onlineSpeakerClustersRemainTemporaryAndDowngradeUnsafeWindows() {
        let cleanWindow = SpeakerWindowing.makeWindows(
            samples: Array(repeating: Float(0.2), count: 2 * 16_000)
        ).first!
        let noisyWindow = SpeakerWindowing.makeWindows(
            samples: Array(repeating: Float(0.000_01), count: 2 * 16_000)
        ).first!
        var clusterer = OnlineTemporarySpeakerClusterer()

        #expect(clusterer.assign(window: cleanWindow, embedding: .embedding([1, 0])) == .temporaryCluster(id: 1))
        #expect(clusterer.assign(window: cleanWindow, embedding: .embedding([0.99, 0.1])) == .temporaryCluster(id: 1))
        #expect(clusterer.assign(window: cleanWindow, embedding: .embedding([0.6, 0.8])) == .unknown(reason: .ambiguousSimilarity))
        #expect(clusterer.assign(window: cleanWindow, embedding: .embedding([0, 1])) == .temporaryCluster(id: 2))
        #expect(clusterer.assign(window: cleanWindow, embedding: .unavailable(reason: "CAM++ 失败")) == .unknown(reason: .embeddingUnavailable))
        #expect(clusterer.assign(window: noisyWindow, embedding: .embedding([1, 0])) == .unknown(reason: .ineligibleWindow([.lowEnergy])))
        #expect(clusterer.clusters.map(\.id) == [1, 2])
        #expect(clusterer.clusters.allSatisfy { $0.windowCount > 0 })
    }

    @Test func temporarySpeakerLabelingKeepsMultiSpeakerRosterStableAndUnknownOut() {
        let cleanA = SpeakerWindowing.makeWindows(
            samples: Array(repeating: Float(0.2), count: 2 * 16_000),
            startingAt: 0
        ).first!
        let cleanB = SpeakerWindowing.makeWindows(
            samples: Array(repeating: Float(0.2), count: 2 * 16_000),
            startingAt: 32_000
        ).first!
        let quiet = SpeakerWindowing.makeWindows(
            samples: Array(repeating: Float(0.000_01), count: 2 * 16_000),
            startingAt: 64_000
        ).first!
        var clusterer = OnlineTemporarySpeakerClusterer()
        let assignments = TemporarySpeakerLabeling.assign(
            windows: [cleanA, cleanB, quiet, cleanA],
            embeddings: [
                .embedding([1, 0]),
                .embedding([0, 1]),
                .embedding([1, 0]),
                .embedding([0.99, 0.05]),
            ],
            clusterer: &clusterer
        )

        #expect(assignments.map(\.displayLabel) == [
            "说话人 1",
            "说话人 2",
            TemporarySpeakerLabeling.unknownLabel,
            "说话人 1",
        ])
        #expect(TemporarySpeakerLabeling.roster(from: assignments) == ["说话人 1", "说话人 2"])
        #expect(
            TemporarySpeakerLabeling.mergeRosters(["说话人 2"], ["说话人 1", "说话人 3"])
                == ["说话人 1", "说话人 2", "说话人 3"]
        )
        #expect(clusterer.assign(
            window: cleanA,
            embedding: .embedding([Float.nan, 0])
        ) == .unknown(reason: .invalidEmbedding))
    }

    @Test func transcriptDocumentAcceptsOnlineTemporarySpeakerRoster() {
        let recording = Recording(startedAt: .distantPast, endedAt: .distantPast, state: .processing)
        let chunk = AudioChunk(
            recordingID: recording.id,
            relativePath: "Recordings/a.m4a",
            startSample: 0,
            endSample: 16_000,
            startedAt: recording.startedAt,
            endedAt: recording.endedAt!
        )
        let first = TranscriptDocumentV1(
            recording: recording,
            chunks: [chunk],
            segmentTexts: [(chunkID: chunk.id, text: "第一段")],
            language: "zh",
            speakers: ["说话人 2", "说话人 1"]
        )
        #expect(first.speakers == ["说话人 1", "说话人 2"])

        let secondChunk = AudioChunk(
            recordingID: recording.id,
            relativePath: "Recordings/b.m4a",
            startSample: 16_000,
            endSample: 32_000,
            startedAt: recording.startedAt,
            endedAt: recording.endedAt!
        )
        let appended = first.appending(
            recording: recording,
            chunks: [chunk, secondChunk],
            text: "第二段",
            sourceChunkID: secondChunk.id,
            speakers: ["说话人 3"]
        )
        #expect(appended.speakers == ["说话人 1", "说话人 2", "说话人 3"])
        #expect(appended.segments.map(\.text) == ["第一段", "第二段"])
    }

    @Test func offlineReclusterFindsTwoFourAndSixSpeakersWithoutPresetCount() {
        func oneHot(_ index: Int, dimension: Int) -> [Float] {
            (0..<dimension).map { $0 == index ? Float(1) : Float(0) }
        }

        func observations(speakerCount: Int, windowsPerSpeaker: Int = 3) -> [OfflineSpeakerObservation] {
            var values: [OfflineSpeakerObservation] = []
            var sample: Int64 = 0
            for speaker in 0..<speakerCount {
                for _ in 0..<windowsPerSpeaker {
                    values.append(
                        OfflineSpeakerObservation(
                            startSample: sample,
                            endSample: sample + 32_000,
                            embedding: .embedding(oneHot(speaker, dimension: max(speakerCount, 2))),
                            exclusionReasons: [],
                            onlineTemporaryLabel: TemporarySpeakerLabeling.temporaryLabel(id: speaker + 1)
                        )
                    )
                    sample += 32_000
                }
            }
            return values
        }

        for count in [2, 4, 6] {
            let result = OfflineSpeakerReclustering.recluster(observations(speakerCount: count))
            #expect(result.speakers.count == count)
            #expect(result.speakers == (1...count).map(TemporarySpeakerLabeling.temporaryLabel(id:)))
            #expect(result.turns.filter { !$0.isUnknown }.count == count)
            #expect(Set(result.labels.compactMap { $0 }).count == count)
        }
    }

    @Test func offlineReclusterCorrectsUnstableOnlineLabelsAndKeepsProvenance() {
        // Online path renumbers per analyze(): both chunks call their first
        // speaker "说话人 1" even though the embeddings are different people.
        let observations = [
            OfflineSpeakerObservation(
                startSample: 0,
                endSample: 32_000,
                embedding: .embedding([1, 0]),
                exclusionReasons: [],
                onlineTemporaryLabel: "说话人 1"
            ),
            OfflineSpeakerObservation(
                startSample: 32_000,
                endSample: 64_000,
                embedding: .embedding([0.99, 0.05]),
                exclusionReasons: [],
                onlineTemporaryLabel: "说话人 1"
            ),
            OfflineSpeakerObservation(
                startSample: 64_000,
                endSample: 96_000,
                embedding: .embedding([0, 1]),
                exclusionReasons: [],
                onlineTemporaryLabel: "说话人 1"
            ),
            OfflineSpeakerObservation(
                startSample: 96_000,
                endSample: 128_000,
                embedding: .embedding([0.05, 0.99]),
                exclusionReasons: [],
                onlineTemporaryLabel: "说话人 2"
            ),
        ]

        let result = OfflineSpeakerReclustering.recluster(observations)
        #expect(result.speakers == ["说话人 1", "说话人 2"])
        #expect(result.labels == ["说话人 1", "说话人 1", "说话人 2", "说话人 2"])
        #expect(result.turns.map(\.speaker) == ["说话人 1", "说话人 2"])
        #expect(result.turns[0].onlineTemporaryLabels == ["说话人 1"])
        #expect(result.turns[1].onlineTemporaryLabels == ["说话人 1", "说话人 2"])
    }

    @Test func offlineReclusterMarksOverlapAndFailedEmbeddingsUnknown() {
        let observations = [
            OfflineSpeakerObservation(
                startSample: 0,
                endSample: 32_000,
                embedding: .embedding([1, 0]),
                exclusionReasons: [],
                onlineTemporaryLabel: "说话人 1"
            ),
            OfflineSpeakerObservation(
                startSample: 32_000,
                endSample: 64_000,
                embedding: .embedding([1, 0]),
                exclusionReasons: [.suspectedOverlappingSpeech],
                onlineTemporaryLabel: nil
            ),
            OfflineSpeakerObservation(
                startSample: 64_000,
                endSample: 96_000,
                embedding: .unavailable(reason: "CAM++ 失败"),
                exclusionReasons: [],
                onlineTemporaryLabel: nil
            ),
            OfflineSpeakerObservation(
                startSample: 96_000,
                endSample: 128_000,
                embedding: .embedding([0.98, 0.1]),
                exclusionReasons: [],
                onlineTemporaryLabel: "说话人 1"
            ),
        ]

        let result = OfflineSpeakerReclustering.recluster(observations)
        #expect(result.speakers == ["说话人 1"])
        #expect(result.labels == ["说话人 1", nil, nil, "说话人 1"])
        #expect(result.turns.map(\.speaker) == ["说话人 1", nil, "说话人 1"])
        #expect(result.turns.map(\.isUnknown) == [false, true, false])
    }

    @Test func offlineReclusterSmoothsShortJumpsAndMergesAdjacentTurns() {
        let speakerA: [Float] = [1, 0]
        let speakerB: [Float] = [0, 1]
        // A A B A  — the single B window is a short jump and should become A.
        let vectors = [speakerA, speakerA, speakerB, speakerA]
        let observations = vectors.enumerated().map { index, vector in
            OfflineSpeakerObservation(
                startSample: Int64(index) * 32_000,
                endSample: Int64(index + 1) * 32_000,
                embedding: .embedding(vector),
                exclusionReasons: [],
                onlineTemporaryLabel: TemporarySpeakerLabeling.temporaryLabel(id: index + 1)
            )
        }

        let result = OfflineSpeakerReclustering.recluster(observations)
        #expect(result.speakers == ["说话人 1"])
        #expect(result.labels == ["说话人 1", "说话人 1", "说话人 1", "说话人 1"])
        #expect(result.turns.count == 1)
        #expect(result.turns[0].startSample == 0)
        #expect(result.turns[0].endSample == 128_000)
    }

    @Test func transcriptDocumentPersistsOfflineSpeakerTurnsAndDecodesLegacyFiles() throws {
        let recording = Recording(startedAt: .distantPast, endedAt: .distantPast, state: .complete)
        let chunk = AudioChunk(
            recordingID: recording.id,
            relativePath: "Recordings/a.m4a",
            startSample: 0,
            endSample: 16_000,
            startedAt: recording.startedAt,
            endedAt: recording.endedAt!
        )
        let document = TranscriptDocumentV1(
            recording: recording,
            chunks: [chunk],
            segmentTexts: [(chunkID: chunk.id, text: "你好")],
            language: "zh",
            speakers: ["说话人 2", "说话人 1"]
        )
        #expect(document.speakerTurns.isEmpty)

        let updated = document.applyingOfflineRecluster(
            speakers: ["说话人 1"],
            speakerTurns: [
                SpeakerTurn(
                    speaker: "说话人 1",
                    startSample: 0,
                    endSample: 16_000,
                    onlineTemporaryLabels: ["说话人 2", "说话人 1"]
                )
            ]
        )
        #expect(updated.speakers == ["说话人 1"])
        #expect(updated.speakerTurns.count == 1)
        #expect(updated.revision == document.revision + 1)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoded = try encoder.encode(updated)
        let decoded = try decoder.decode(TranscriptDocumentV1.self, from: encoded)
        #expect(decoded.speakerTurns == updated.speakerTurns)
        #expect(decoded.speakerTurns.first?.attribution == .single)

        let legacy = """
        {"schema":"voice-context/transcript@1","recording_id":"\(recording.id.uuidString)","kind":"recording","state":"complete","revision":1,"title":null,"tags":[],"started_at":"2026-08-05T07:00:00Z","ended_at":"2026-08-05T07:02:00Z","timezone":"Asia/Shanghai","language":"zh","audio":{"local_only":true,"available_on_this_device":true,"retention":"seven_days"},"speech_spans":[],"speakers":["说话人 1"],"segments":[{"id":"BA485C93-6D6E-42E9-ADDA-B8DA00000001","sequence":1,"started_at":"2026-08-05T07:00:00Z","offset_milliseconds":0,"text":"hi","start_sample":0,"end_sample":16000,"source_chunk_id":"\(chunk.id.uuidString)","source_ranges":[{"source_kind":"audio_chunk","source_id":"\(chunk.id.uuidString)","start_sample":0,"end_sample":16000}],"speech_span_ids":[]}],"gaps":[]}
        """.data(using: .utf8)!
        let legacyDocument = try decoder.decode(TranscriptDocumentV1.self, from: legacy)
        #expect(legacyDocument.speakerTurns.isEmpty)
        #expect(legacyDocument.speakers == ["说话人 1"])
    }

    @Test func inputMetricsExposeRMSPeakAndDocumentedMeterScale() {
        let metrics = AudioInputMetrics.from(samples: [0.5, -0.5, 0, 0])

        #expect(abs(metrics.peakDecibels + 6.02) < 0.01)
        #expect(abs(metrics.rmsDecibels + 9.03) < 0.01)
        #expect(metrics.displayLevel > 0.8)
        #expect(AudioInputMetrics.from(samples: []).rmsDecibels == -120)
    }

    @Test func backgroundGateProbeRejectsWithoutAddingASubmission() async {
        let transcriber = SenseVoiceInferenceService()
        let probe = await transcriber.enteredBackground()

        #expect(probe.rejected)
        #expect(probe.submissionsBefore == probe.submissionsAfter)

        await transcriber.enteredForeground()
    }

    private func analyzedChunk(
        id: UUID = UUID(),
        sequence: Int,
        range: Range<Int64>,
        speech: [Range<Int64>],
        endsWithOpenSpeech: Bool
    ) -> SpeechAnalysisService.AnalyzedAudioChunk {
        SpeechAnalysisService.AnalyzedAudioChunk(
            id: id,
            sequence: sequence,
            startSample: range.lowerBound,
            endSample: range.upperBound,
            speechSpans: speech.map {
                SpeechAnalysisService.SpeechSpan(
                    startSample: $0.lowerBound,
                    endSample: $0.upperBound
                )
            },
            endsWithOpenSpeech: endsWithOpenSpeech
        )
    }

}


private actor MetalPeakProbe {
    private let gate: InferenceLifecycleGate
    private var observedPeak = 0

    init(gate: InferenceLifecycleGate) {
        self.gate = gate
    }

    func sample() async {
        let inFlight = await gate.metrics().inFlightMetalWork
        observedPeak = max(observedPeak, inFlight)
    }

    func peak() -> Int { observedPeak }
}

private actor MetalStartBarrier {
    private let count: Int
    private var arrived = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    init(count: Int) {
        self.count = count
    }

    func arriveAndWait() async {
        arrived += 1
        if arrived >= count {
            let pending = continuations
            continuations.removeAll()
            for continuation in pending {
                continuation.resume()
            }
            return
        }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }
}


private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}
