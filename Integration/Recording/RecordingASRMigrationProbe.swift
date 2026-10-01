#if DEBUG
import Foundation

/// Exercises the real recording pipeline with bundled audio, without writing meetings.
@MainActor
public enum RecordingASRMigrationProbe {
    public static func fixtureSamples() throws -> [Float] {
        guard let url = Bundle.main.url(forResource: "SenseVoiceFixture", withExtension: "m4a") else {
            throw failure("Missing bundled audio fixture")
        }
        return try PCM16KMonoLoader.samples(from: url)
    }

    public static func run(extended: Bool) async throws -> Data {
        let samples = try fixtureSamples()
        let service = SenseVoiceInferenceService()
        let short = try await service.transcribe(samples: samples, startingAt: 16_000, languageMode: .chinese)
        // This pinned ggml runtime reports the Metal device as MTL0.
        try check(!short.text.isEmpty && short.backend == "MTL0", "Meeting text/Metal backend: backend=\(short.backend), text=\(short.text)")
        try check(!short.sentenceResults.isEmpty, "Meeting sentence timestamps")
        try check(short.sentenceResults.allSatisfy {
            $0.startSample >= 16_000 && $0.endSample > $0.startSample && $0.endSample <= Int64(samples.count) + 16_000
        }, "Meeting timestamp bounds and source offset")
        var cases: [String: Any] = [
            "short": ["text": short.text, "rawText": short.rawText, "language": short.detectedLanguage,
                      "backend": short.backend, "sentenceCount": short.sentenceResults.count,
                      "inferenceMs": short.inferenceMilliseconds],
        ]
        if extended {
            let auto = try await service.transcribe(samples: samples, startingAt: 0, languageMode: .zhEnBilingual)
            try check(!auto.text.isEmpty && !auto.detectedLanguage.isEmpty, "Meeting language autodetect")
            cases["autodetect"] = ["text": auto.text, "language": auto.detectedLanguage]
            let longSamples = Array(repeating: samples, count: 4).flatMap { $0 }
            let long = try await service.transcribe(samples: longSamples, startingAt: 0, languageMode: .chinese)
            try check(long.audioDuration > 60 && long.text.count > short.text.count * 2, "Meeting longer than one minute")
            cases["long"] = ["text": long.text, "duration": long.audioDuration,
                             "sentenceCount": long.sentenceResults.count]
            do {
                _ = try await service.transcribe(samples: [Float](repeating: 0, count: 16_000), startingAt: 0)
                throw failure("Silent meeting was accepted")
            } catch SpeechAnalysisService.AnalysisError.noSpeechDetected {
                cases["silence"] = "rejected by VAD as noSpeechDetected"
            }
            let work = Task { try await service.transcribe(samples: longSamples, startingAt: 0) }
            for _ in 0..<400 {
                if await service.metrics().inFlightMetalWork > 0 { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            try check(await service.metrics().inFlightMetalWork == 1, "Cancellation reached native work")
            let background = await service.enteredBackground()
            try check(background.rejected && background.submissionsBefore == background.submissionsAfter,
                      "Background must reject new Metal submissions")
            do {
                _ = try await work.value
                throw failure("In-flight meeting was not cancelled")
            } catch SenseVoiceInferenceService.InferenceError.abortedForBackground {
                cases["backgroundCancellation"] = "abortedForBackground"
            }
            await service.enteredForeground()
            let resumed = try await service.transcribe(samples: samples, startingAt: 0)
            try check(!resumed.text.isEmpty, "Foreground recovery")
            cases["foregroundRecovery"] = resumed.text
        }
        let metrics = await service.metrics()
        try check(metrics.inFlightMetalWork == 0 && metrics.peakInFlightMetalWork == 1,
                  "Metal lease cleanup and serial execution")
        cases["lifecycle"] = ["inFlight": metrics.inFlightMetalWork, "peakInFlight": metrics.peakInFlightMetalWork]
        return try JSONSerialization.data(withJSONObject: cases, options: [.sortedKeys])
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw failure(message) }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "RecordingASRMigrationProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
#endif
