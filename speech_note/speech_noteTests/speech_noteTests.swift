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
        ])
        #expect(ThirdPartyAttribution.catalog.allSatisfy { !$0.license.isEmpty && !$0.reviewStatus.isEmpty })
        #expect(ThirdPartyAttribution.catalog.allSatisfy { $0.sourceURL.scheme == "https" && $0.licenseURL.scheme == "https" })
    }

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
        // Swift Testing Documentation
        // https://developer.apple.com/documentation/testing
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
        #expect(await gate.metrics() == .init(acceptsMetalWork: false, submittedMetalWork: 1))
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

    @Test func utteranceAssemblyKeepsLongSpeechWithoutAHardThreshold() {
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

        #expect(utterances.count == 1)
        #expect(utterances[0].startSample == start)
        #expect(utterances[0].endSample == spans[0].endSample)
        #expect(utterances[0].duration == 26)
        #expect(utterances[0].speechSpans == spans)
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

}
