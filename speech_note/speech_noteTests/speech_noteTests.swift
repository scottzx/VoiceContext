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

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}
