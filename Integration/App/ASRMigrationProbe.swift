#if DEBUG
import Foundation
import TranscribeNative
import VoiceRecording

/// Opt-in device regression probe; invoked only by an explicit launch argument.
@MainActor
enum ASRMigrationProbe {
    static func run(stage: String) async {
        guard ["dependency", "chat", "meeting"].contains(stage) else { return }
        let started = Date()
        var report: [String: Any] = ["stage": stage, "startedAt": started.description,
                                   "nativeVersion": Transcribe.version(), "headerHash": Transcribe.headerHash()]
        do {
            try Transcribe.ensureCompatible()
            let samples = try RecordingASRMigrationProbe.fixtureSamples()
            let pcm = pcm16(samples)
            let short = try await HardwareVoiceTranscriber.shared.transcribe(pcm16: pcm)
            try check(!short.isEmpty, "Hardware PCM transcription")
            let chat = try await SenseVoiceProvider.shared.transcribe(VoiceInputRequest(audioData: wav(pcm, rate: 16_000)))
            try check(chat.text == short, "Chat WAV and hardware PCM agree")
            report["hardware"] = ["text": short]
            report["chat"] = ["text": chat.text]
            if stage != "dependency" {
                let pcm48k = pcm16(samples.flatMap { [$0, $0, $0] })
                let resampled = try await SenseVoiceProvider.shared.transcribe(VoiceInputRequest(audioData: wav(pcm48k, rate: 48_000)))
                try check(!resampled.text.isEmpty, "Chat 48 kHz input resampling")
                report["chat48k"] = resampled.text
                let longPCM = Array(repeating: pcm, count: 4).reduce(into: Data()) { $0.append($1) }
                let long = try await HardwareVoiceTranscriber.shared.transcribeSegmented(pcm16: longPCM)
                try check(longPCM.count > 60 * 32_000 && long.count > short.count * 2, "Long hardware recording preserves text")
                report["hardwareLong"] = ["text": long, "duration": Double(longPCM.count) / 32_000]
                do {
                    _ = try await HardwareVoiceTranscriber.shared.transcribe(pcm16: Data())
                    throw failure("Empty hardware audio was accepted")
                } catch HardwareVoiceTranscriber.TranscriberError.emptyTranscript {
                    report["emptyAudio"] = "rejected as emptyTranscript"
                }
                do {
                    _ = try await SenseVoiceProvider.shared.transcribe(VoiceInputRequest(audioData: Data("invalid WAV".utf8)))
                    throw failure("Malformed WAV was accepted")
                } catch let error as VoiceProviderError {
                    report["invalidWAV"] = error.localizedDescription
                }
            }
            let meetingData = try await RecordingASRMigrationProbe.run(extended: stage == "meeting")
            report["meeting"] = try JSONSerialization.jsonObject(with: meetingData)
            report["passed"] = true
        } catch {
            report["passed"] = false
            report["error"] = String(describing: error)
        }
        report["elapsedSeconds"] = Date().timeIntervalSince(started)
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let folder = documents.appendingPathComponent("ASRMigration", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appendingPathComponent("\(stage).json"), options: .atomic)
            print("[ASR_MIGRATION_RESULT] \(String(decoding: data, as: UTF8.self))")
        } catch {
            print("[ASR_MIGRATION_WRITE_FAILED] \(error)")
        }
    }

    private static func pcm16(_ samples: [Float]) -> Data {
        var result = Data(capacity: samples.count * 2)
        for sample in samples {
            var value = Int16(clamping: Int((sample * 32768).rounded())).littleEndian
            withUnsafeBytes(of: &value) { result.append(contentsOf: $0) }
        }
        return result
    }

    private static func wav(_ pcm: Data, rate: UInt32) -> Data {
        var data = Data("RIFF".utf8)
        func uint32(_ value: UInt32) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        func uint16(_ value: UInt16) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        uint32(UInt32(pcm.count) + 36)
        data.append(contentsOf: "WAVEfmt ".utf8)
        uint32(16); uint16(1); uint16(1); uint32(rate); uint32(rate * 2); uint16(2); uint16(16)
        data.append(contentsOf: "data".utf8)
        uint32(UInt32(pcm.count))
        data.append(pcm)
        return data
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw failure(message) }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "ASRMigrationProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
#endif
