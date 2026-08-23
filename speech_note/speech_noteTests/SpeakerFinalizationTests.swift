import Foundation
import Testing
@testable import speech_note

struct SpeakerFinalizationTests {
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
            pipelineVersion: 1,
            diarizationEngineID: "cam-plus-observation-clustering-v1",
            observationCount: 60,
            speakerCount: 4,
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

    private func turn(_ speaker: String, _ start: Int64, _ end: Int64) -> SpeakerTurn {
        SpeakerTurn(
            speaker: speaker,
            startSample: start,
            endSample: end,
            onlineTemporaryLabels: []
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerFinalizationTests-\(UUID().uuidString)", isDirectory: true)
    }
}
