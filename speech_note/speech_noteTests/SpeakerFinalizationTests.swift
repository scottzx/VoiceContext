import Foundation
import Testing
@testable import speech_note

struct SpeakerFinalizationTests {
    @Test func observationWritersUseCompactJSON() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recordingID = UUID()
        let batchID = UUID()
        let value = observation(start: 0, end: 16_000, vector: [1, 0])

        SpeakerObservationStore.save([value], rootURL: root, recordingID: recordingID)
        try SpeakerObservationStore.replaceBatch(
            [value],
            rootURL: root,
            recordingID: recordingID,
            batchID: batchID
        )

        for url in [
            SpeakerObservationStore.storageURL(rootURL: root, recordingID: recordingID),
            SpeakerObservationStore.batchURL(
                rootURL: root,
                recordingID: recordingID,
                batchID: batchID
            ),
        ] {
            let json = try String(contentsOf: url, encoding: .utf8)
            #expect(!json.contains("\n"))
            #expect(!json.contains("  \""))
        }
    }

    @Test func observationBatchesReplaceOnlyTheirOwnMinuteAndOverrideLegacyOverlap() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recordingID = UUID()
        let firstBatchID = UUID()
        let secondBatchID = UUID()

        let legacy = observation(start: 0, end: 16_000, vector: [1, 0])
        SpeakerObservationStore.save([legacy], rootURL: root, recordingID: recordingID)

        let first = observation(start: 0, end: 16_000, vector: [0.9, 0.1])
        let second = observation(start: 16_000, end: 32_000, vector: [0, 1])
        try SpeakerObservationStore.replaceBatch(
            [first],
            rootURL: root,
            recordingID: recordingID,
            batchID: firstBatchID
        )
        try SpeakerObservationStore.replaceBatch(
            [second],
            rootURL: root,
            recordingID: recordingID,
            batchID: secondBatchID
        )
        let secondURL = SpeakerObservationStore.batchURL(
            rootURL: root,
            recordingID: recordingID,
            batchID: secondBatchID
        )
        let untouchedSecondData = try Data(contentsOf: secondURL)

        let retriedFirst = observation(start: 0, end: 16_000, vector: [0.8, 0.2])
        try SpeakerObservationStore.replaceBatch(
            [retriedFirst],
            rootURL: root,
            recordingID: recordingID,
            batchID: firstBatchID
        )

        let loaded = SpeakerObservationStore.load(rootURL: root, recordingID: recordingID)
        #expect(loaded == [retriedFirst, second])
        #expect(try Data(contentsOf: secondURL) == untouchedSecondData)
    }

    @Test func stageMetricsRoundTripAtStableShardedPaths() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recordingID = UUID()
        let batchID = UUID()
        let now = Date(timeIntervalSince1970: 1_787_500_000)

        let transcription = TranscriptionStageMetrics(
            recordingID: recordingID,
            batchID: batchID,
            audioDurationMilliseconds: 60_000,
            vadMilliseconds: 120,
            asrLoadMilliseconds: 15,
            asrInferenceMilliseconds: 3_500,
            embeddingMilliseconds: 240,
            commitMilliseconds: 18,
            thermalState: "nominal",
            completedAt: now
        )
        try TranscriptionStageMetricsStore.save(transcription, rootURL: root)
        #expect(try TranscriptionStageMetricsStore.loadTranscription(
            rootURL: root,
            recordingID: recordingID,
            batchID: batchID
        ) == transcription)

        let finalization = SpeakerFinalizationMetrics(
            recordingID: recordingID,
            pipelineVersion: SpeakerFinalizationJob.currentPipelineVersion,
            diarizationEngineID: "cam-plus-observation-clustering-v1",
            observationCount: 60,
            speakerCount: 4,
            offlineSpeakerPassCount: 1,
            offlineSpeakerPassMilliseconds: 1_200,
            acousticStrategy: "cam-plus-only",
            sherpaWindowCount: 0,
            sparseEmbeddingCount: 52,
            sparseEmbeddingMilliseconds: 420,
            candidateSegmentCount: 40,
            audioDecodeMilliseconds: 310,
            unknownSegmentCount: 3,
            multipleSegmentCount: 2,
            weakMatchedSegmentCount: 5,
            observationLoadMilliseconds: 2,
            reclusterMilliseconds: 50,
            bindingMilliseconds: 4,
            transcriptCommitMilliseconds: 8,
            publicPublishMilliseconds: 12,
            totalMilliseconds: 76,
            completedAt: now
        )
        try TranscriptionStageMetricsStore.save(finalization, rootURL: root)
        #expect(try TranscriptionStageMetricsStore.loadSpeakerFinalization(
            rootURL: root,
            job: SpeakerFinalizationJob(recordingID: recordingID)
        ) == finalization)
    }

    @Test func transcriptionPurposeNeverRunsSpeakerEmbedding() {
        #expect(!SpeechAnalysisService.AnalysisPurpose.transcription.includesSpeakerAnalysis)
        #expect(SpeechAnalysisService.AnalysisPurpose.speakerFinalization.includesSpeakerAnalysis)
        #expect(!SenseVoiceInferenceService.analysisPurpose.includesSpeakerAnalysis)
    }

    @Test func legacyFinalizationMetricsDecodeWithoutOfflinePassFields() throws {
        let metrics = SpeakerFinalizationMetrics(
            recordingID: UUID(),
            pipelineVersion: 1,
            diarizationEngineID: "cam-plus-observation-clustering-v1",
            observationCount: 10,
            speakerCount: 2,
            offlineSpeakerPassCount: 1,
            offlineSpeakerPassMilliseconds: 800,
            acousticStrategy: nil,
            sherpaWindowCount: nil,
            sparseEmbeddingCount: nil,
            sparseEmbeddingMilliseconds: nil,
            candidateSegmentCount: nil,
            audioDecodeMilliseconds: nil,
            unknownSegmentCount: nil,
            multipleSegmentCount: nil,
            weakMatchedSegmentCount: nil,
            observationLoadMilliseconds: 2,
            reclusterMilliseconds: 50,
            bindingMilliseconds: 4,
            transcriptCommitMilliseconds: 8,
            publicPublishMilliseconds: 12,
            totalMilliseconds: 876,
            completedAt: Date(timeIntervalSince1970: 1_787_500_000)
        )
        let encoded = try JSONEncoder().encode(metrics)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "offlineSpeakerPassCount")
        object.removeValue(forKey: "offlineSpeakerPassMilliseconds")
        object.removeValue(forKey: "candidateSegmentCount")
        object.removeValue(forKey: "audioDecodeMilliseconds")
        object.removeValue(forKey: "unknownSegmentCount")
        object.removeValue(forKey: "multipleSegmentCount")
        object.removeValue(forKey: "weakMatchedSegmentCount")

        let decoded = try JSONDecoder().decode(
            SpeakerFinalizationMetrics.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.offlineSpeakerPassCount == nil)
        #expect(decoded.offlineSpeakerPassMilliseconds == nil)
        #expect(decoded.candidateSegmentCount == nil)
        #expect(decoded.audioDecodeMilliseconds == nil)
        #expect(decoded.unknownSegmentCount == nil)
        #expect(decoded.multipleSegmentCount == nil)
        #expect(decoded.weakMatchedSegmentCount == nil)
    }

    @Test func baselineDiarizationUsesObservationsWithoutAudioDependency() async throws {
        let observations = [
            observation(start: 0, end: 16_000, vector: [1, 0]),
            observation(start: 16_000, end: 32_000, vector: [0.99, 0.01]),
            observation(start: 32_000, end: 48_000, vector: [0, 1]),
        ]
        let output = try await CAMPlusObservationDiarizationEngine().diarize(
            SpeakerDiarizationInput(samples: [], observations: observations)
        )
        #expect(output.engineID == "cam-plus-observation-clustering-v1")
        #expect(output.result.speakers.count == 2)
        #expect(output.result.labels.count == observations.count)
    }

    @Test func reclusteringFiveHundredAnchorsFindsFiveStableSpeakers() {
        let observations = (0..<500).map { index -> OfflineSpeakerObservation in
            let speaker = index % 5
            var vector = Array(repeating: Float.zero, count: 32)
            vector[speaker] = 1
            vector[5 + (index / 5) % 27] = 0.02
            return OfflineSpeakerObservation(
                startSample: Int64(index * 32_000),
                endSample: Int64((index + 1) * 32_000),
                embedding: .embedding(vector),
                exclusionReasons: [],
                onlineTemporaryLabel: nil
            )
        }

        let result = OfflineSpeakerReclustering.recluster(
            observations,
            mergeSimilarityThreshold: 0.65,
            shortJumpMaxWindows: 0
        )

        #expect(result.speakers.count == 5)
        #expect(result.labels.count == 500)
        #expect(Set(result.labels.compactMap { $0 }).count == 5)
    }

    @Test func speakerDiarizationWindowsStayBoundedForOneHour() {
        let hour = Int64(60 * 60 * 16_000)
        let windows = SpeakerDiarizationWindowing.ranges(totalSamples: hour)

        #expect(windows.count == 60)
        #expect(windows.first?.startSample == 0)
        #expect(windows.last?.endSample == hour)
        #expect(windows.allSatisfy {
            $0.endSample - $0.startSample <= SpeakerDiarizationWindowing.maximumSamples
        })
    }

    @Test func segmentAnchorCountsAreBoundedByASRSentenceDuration() {
        let short = segmentAudio(seconds: 1, amplitude: 0.2)
        let ordinary = segmentAudio(seconds: 4, amplitude: 0.2)
        let long = segmentAudio(seconds: 8, amplitude: 0.2)
        let veryLong = segmentAudio(seconds: 15, amplitude: 0.2)

        let shortAnchors = SegmentSpeakerAnchorPlanner.anchors(for: short)
        #expect(shortAnchors.count == 1)
        #expect(shortAnchors[0].window.exclusionReasons == [.tooShort])
        #expect(!shortAnchors[0].window.isEligibleForClustering)
        #expect(shortAnchors[0].window.isEligibleForWeakMatching)
        #expect(SegmentSpeakerAnchorPlanner.anchors(for: ordinary).count == 3)
        #expect(SegmentSpeakerAnchorPlanner.anchors(for: long).count == 5)
        #expect(SegmentSpeakerAnchorPlanner.anchors(for: veryLong).count == 5)
        #expect(SegmentSpeakerAnchorPlanner.anchors(
            for: [short, ordinary, long, veryLong]
        ).count <= 20)
    }

    @Test func segmentAnchorsRejectLowEnergyAndClippedAudio() {
        let lowEnergy = segmentAudio(seconds: 4, amplitude: 0)
        let clipped = segmentAudio(seconds: 4, amplitude: 1)

        #expect(SegmentSpeakerAnchorPlanner.anchors(for: lowEnergy).isEmpty)
        #expect(SegmentSpeakerAnchorPlanner.anchors(for: clipped).isEmpty)
    }

    @Test func fivePointGateKeepsSingleSentenceAndExcludesABASentence() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let observations = [
            segmentObservation(segmentID: first, index: 0, vector: [1, 0]),
            segmentObservation(segmentID: first, index: 1, vector: [0.99, 0.01]),
            segmentObservation(segmentID: first, index: 2, vector: [1, 0]),
            segmentObservation(segmentID: first, index: 3, vector: [0.99, 0.01]),
            segmentObservation(segmentID: first, index: 4, vector: [1, 0]),
            segmentObservation(segmentID: second, index: 5, vector: [1, 0]),
            segmentObservation(segmentID: second, index: 6, vector: [1, 0]),
            segmentObservation(segmentID: second, index: 7, vector: [0, 1]),
            segmentObservation(segmentID: second, index: 8, vector: [1, 0]),
            segmentObservation(segmentID: second, index: 9, vector: [1, 0]),
            segmentObservation(segmentID: third, index: 10, vector: [0, 1]),
            segmentObservation(segmentID: third, index: 11, vector: [0.01, 0.99]),
            segmentObservation(segmentID: third, index: 12, vector: [0, 1]),
            segmentObservation(segmentID: third, index: 13, vector: [0.01, 0.99]),
            segmentObservation(segmentID: third, index: 14, vector: [0, 1]),
        ]

        let result = SegmentSpeakerSentenceGate.evaluate(
            segmentIDs: [first, second, third],
            observations: observations
        )
        let global = OfflineSpeakerReclustering.recluster(
            result.representatives,
            mergeSimilarityThreshold: 0.65,
            shortJumpMaxWindows: 0
        )
        let validated = SegmentSpeakerSentenceGate.validatingUnknowns(
            result,
            observations: observations,
            representativeLabels: global.labels
        )

        #expect(result.attributions[first] == .single)
        #expect(result.attributions[second] == .unknown)
        #expect(result.attributions[third] == .single)
        #expect(validated[second] == .multiple)
        #expect(result.representatives.count == 2)
        #expect(result.representatives.first?.onlineTemporaryLabel == first.uuidString.lowercased())

    }

    @Test func sentenceGateRequiresTwoCleanWindowsBeforeGlobalClustering() {
        let segmentID = UUID()
        let result = SegmentSpeakerSentenceGate.evaluate(
            segmentIDs: [segmentID],
            observations: [segmentObservation(segmentID: segmentID, index: 0, vector: [1, 0])]
        )

        #expect(result.attributions[segmentID] == .unknown)
        #expect(result.representatives.isEmpty)
    }

    @Test func finalCleanupMatchesOneAnchorOnlyToEstablishedSpeakers() {
        let matched = UUID()
        let ambiguous = UUID()
        let lowScore = UUID()
        let multiAnchor = UUID()
        let alreadyMultiple = UUID()
        let representativeA = segmentObservation(
            segmentID: UUID(), index: 10, vector: [1, 0, 0]
        )
        let representativeB = segmentObservation(
            segmentID: UUID(), index: 11, vector: [0, 1, 0]
        )
        let observations = [
            segmentObservation(
                segmentID: matched,
                index: 0,
                vector: [0.99, 0.05, 0],
                exclusionReasons: [.tooShort]
            ),
            segmentObservation(
                segmentID: ambiguous,
                index: 1,
                vector: [0.72, 0.69, 0],
                exclusionReasons: [.tooShort]
            ),
            segmentObservation(
                segmentID: lowScore,
                index: 2,
                vector: [0.65, 0, 0.76],
                exclusionReasons: [.tooShort]
            ),
            segmentObservation(segmentID: multiAnchor, index: 3, vector: [1, 0, 0]),
            segmentObservation(segmentID: multiAnchor, index: 4, vector: [1, 0, 0]),
            segmentObservation(
                segmentID: alreadyMultiple,
                index: 5,
                vector: [1, 0, 0],
                exclusionReasons: [.tooShort]
            ),
        ]
        let cleanup = SegmentSpeakerSentenceGate.matchingSingleAnchorUnknowns(
            attributions: [
                matched: .unknown,
                ambiguous: .unknown,
                lowScore: .unknown,
                multiAnchor: .unknown,
                alreadyMultiple: .multiple,
            ],
            observations: observations,
            representatives: [representativeA, representativeB],
            representativeLabels: ["A", "B"]
        )

        #expect(cleanup.attributions[matched] == .single)
        #expect(cleanup.supplementalLabels == [matched: "A"])
        #expect(cleanup.attributions[ambiguous] == .unknown)
        #expect(cleanup.attributions[lowScore] == .unknown)
        #expect(cleanup.attributions[multiAnchor] == .unknown)
        #expect(cleanup.attributions[alreadyMultiple] == .multiple)

        let assignment = SegmentSpeakerAssignmentResolver.resolve(
            segments: [.init(id: matched, startSample: 0, endSample: 12_000)],
            attributions: cleanup.attributions,
            representativeSegmentIDs: [],
            representativeLabels: [],
            supplementalLabels: cleanup.supplementalLabels
        )
        #expect(assignment.turns.map(\.speaker) == ["A"])
        #expect(assignment.turns.map(\.attribution) == [.single])
    }

    @Test func assignmentPersistsMultipleAndNeverFillsItFromNeighbors() {
        let first = UUID()
        let multiple = UUID()
        let third = UUID()
        let result = SegmentSpeakerAssignmentResolver.resolve(
            segments: [
                .init(id: first, startSample: 0, endSample: 16_000),
                .init(id: multiple, startSample: 20_000, endSample: 28_000),
                .init(id: third, startSample: 64_000, endSample: 80_000),
            ],
            attributions: [first: .single, multiple: .multiple, third: .single],
            representativeSegmentIDs: [first, third],
            representativeLabels: ["A", "A"]
        )

        #expect(result.speakers == ["A"])
        #expect(result.turns.map(\.speaker) == ["A", nil, "A"])
        #expect(result.turns.map(\.attribution) == [.single, .multiple, .single])
        #expect(result.unknownSegmentCount == 0)
        #expect(result.multipleSegmentCount == 1)
    }

    @Test func adjacentMatchingSegmentsMergeAcrossLongSilence() {
        let ids = (0..<2).map { _ in UUID() }
        let result = SegmentSpeakerAssignmentResolver.resolve(
            segments: [
                .init(id: ids[0], startSample: 0, endSample: 16_000),
                .init(id: ids[1], startSample: 64_000, endSample: 80_000),
            ],
            attributions: [ids[0]: .single, ids[1]: .single],
            representativeSegmentIDs: ids.map(Optional.some),
            representativeLabels: ["A", "A"]
        )

        #expect(result.turns == [turn("A", 0, 80_000)])
    }

    @Test func segmentSpeakerInputsAreStableAcrossTranscriptTextEdits() {
        let segmentID = UUID()
        let audioBeforeEdit = SegmentSpeakerAudio(
            segmentID: segmentID,
            startSample: 10_000,
            endSample: 74_000,
            samples: Array(repeating: 0.2, count: 64_000)
        )
        // A text edit cannot enter this acoustic-only input type. Identical
        // IDs, timing and samples therefore produce exactly the same anchors.
        let audioAfterEdit = SegmentSpeakerAudio(
            segmentID: segmentID,
            startSample: 10_000,
            endSample: 74_000,
            samples: Array(repeating: 0.2, count: 64_000)
        )

        #expect(SegmentSpeakerAnchorPlanner.anchors(for: audioBeforeEdit)
            == SegmentSpeakerAnchorPlanner.anchors(for: audioAfterEdit))
    }

    @Test func windowLocalSpeakersAlignToGlobalCAMPlusLabels() {
        let observations = [
            observation(start: 0, end: 10, vector: [1, 0]),
            observation(start: 10, end: 20, vector: [0, 1]),
            observation(start: 60, end: 70, vector: [0, 1]),
            observation(start: 70, end: 80, vector: [1, 0]),
        ]
        let baseline = OfflineSpeakerReclustering.Result(
            speakers: ["A", "B"],
            turns: [
                turn("A", 0, 10),
                turn("B", 10, 20),
                turn("B", 60, 70),
                turn("A", 70, 80),
            ],
            labels: ["A", "B", "B", "A"]
        )
        // Sherpa restarts local IDs in the second window and gives the first
        // local ID to B. Alignment must not leak that swap into the meeting.
        let firstWindow = OfflineSpeakerReclustering.Result(
            speakers: ["local-1", "local-2"],
            turns: [turn("local-1", 0, 10), turn("local-2", 10, 20)],
            labels: ["local-1", "local-2"]
        )
        let secondWindow = OfflineSpeakerReclustering.Result(
            speakers: ["local-1", "local-2"],
            turns: [turn("local-1", 60, 70), turn("local-2", 70, 80)],
            labels: ["local-1", "local-2"]
        )

        let aligned = SpeakerDiarizationWindowing.align(
            baseline: baseline,
            observations: observations,
            windowResults: [firstWindow, secondWindow]
        )

        #expect(aligned.speakers == ["A", "B"])
        #expect(aligned.labels == baseline.labels)
        #expect(aligned.turns.compactMap(\.speaker) == ["A", "B", "B", "A"])
    }

    @Test func packagedSherpaDiarizationRunsOnBundledFixture() async throws {
        let fixtureURL = try #require(
            Bundle.main.url(forResource: "SenseVoiceFixture", withExtension: "m4a")
        )
        let engine = try #require(
            SpeakerDiarizationEngineFactory.approvedSherpaEngine(bundle: .main)
        )
        let samples = try PCM16KMonoLoader.samples(from: fixtureURL)

        let output = try await engine.diarize(
            SpeakerDiarizationInput(samples: samples, observations: [])
        )

        #expect(output.engineID == "sherpa-pyannote3-int8-cam-plus-v1")
        #expect(!output.result.speakers.isEmpty)
        #expect(!output.result.turns.isEmpty)
    }

    private func observation(
        start: Int64,
        end: Int64,
        vector: [Float]
    ) -> OfflineSpeakerObservation {
        OfflineSpeakerObservation(
            startSample: start,
            endSample: end,
            embedding: .embedding(vector),
            exclusionReasons: [],
            onlineTemporaryLabel: nil
        )
    }

    private func segmentObservation(
        segmentID: UUID,
        index: Int,
        vector: [Float],
        exclusionReasons: [SpeakerWindow.ExclusionReason] = []
    ) -> OfflineSpeakerObservation {
        OfflineSpeakerObservation(
            startSample: Int64(index * 32_000),
            endSample: Int64((index + 1) * 32_000),
            embedding: .embedding(vector),
            exclusionReasons: exclusionReasons,
            onlineTemporaryLabel: segmentID.uuidString.lowercased()
        )
    }

    private func turn(_ speaker: String, _ start: Int64, _ end: Int64) -> SpeakerTurn {
        SpeakerTurn(
            speaker: speaker,
            startSample: start,
            endSample: end,
            onlineTemporaryLabels: []
        )
    }

    private func segmentAudio(seconds: Double, amplitude: Float) -> SegmentSpeakerAudio {
        let sampleCount = Int(seconds * 16_000)
        return SegmentSpeakerAudio(
            segmentID: UUID(),
            startSample: 0,
            endSample: Int64(sampleCount),
            samples: Array(repeating: amplitude, count: sampleCount)
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerFinalizationTests-\(UUID().uuidString)", isDirectory: true)
    }
}
