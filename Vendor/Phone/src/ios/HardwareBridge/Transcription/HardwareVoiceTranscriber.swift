import TranscribeNative
import Foundation

/// Single-utterance SenseVoice transcription through the shared TranscribeKit package.
/// Hardware buttons delimit utterances; meeting VAD and speaker processing remain
/// in the recording module. Both paths use TranscribeNative's Model/Session API.
actor HardwareVoiceTranscriber {
    /// Shared across every caller (hardware bridge + composer voice input) so the
    /// 241MB model loads once, not once per feature.
    static let shared = HardwareVoiceTranscriber()

    enum TranscriberError: LocalizedError {
        case modelResourceMissing
        case openFailed(String)
        case runFailed(String)
        case emptyTranscript

        var errorDescription: String? {
            switch self {
            case .modelResourceMissing: return "找不到 SenseVoiceSmall-Q8_0.gguf"
            case .openFailed(let message): return "模型加载失败：\(message)"
            case .runFailed(let message): return "转写失败：\(message)"
            case .emptyTranscript: return "转写结果为空"
            }
        }
    }

    private var session: Session?

    /// SenseVoice is a fast single-utterance recognizer rather than a stateful
    /// streaming decoder. Keep transport chunks small, but coalesce them into
    /// bounded inference windows so long device recordings never require one
    /// unbounded model call. At 16 kHz PCM16 mono, 30 seconds is 960,000 bytes.
    static let defaultSegmentSeconds = 30

    /// Converts raw little-endian PCM16 mono 16kHz bytes (as streamed by the
    /// device over L2CAP) to text.
    func transcribe(pcm16: Data) async throws -> String {
        let samples = Self.floatSamples(fromLittleEndianPCM16: pcm16)
        guard !samples.isEmpty else { throw TranscriberError.emptyTranscript }

        let session = try openSessionIfNeeded()

        let text: String
        do {
            text = try Self.run(session: session, samples: samples)
        } catch {
            throw TranscriberError.runFailed(String(describing: error))
        }
        guard !text.isEmpty else { throw TranscriberError.emptyTranscript }
        return text
    }

    /// Transcribes an arbitrary-length device recording as ordered, bounded
    /// SenseVoice calls. The shared actor keeps one model session warm and also
    /// guarantees that segment results cannot complete out of order.
    func transcribeSegmented(
        pcm16: Data,
        segmentSeconds: Int = defaultSegmentSeconds
    ) async throws -> String {
        let segments = Self.pcmSegments(pcm16, seconds: segmentSeconds)
        guard !segments.isEmpty else { throw TranscriberError.emptyTranscript }

        var transcripts: [String] = []
        transcripts.reserveCapacity(segments.count)
        for segment in segments {
            do {
                transcripts.append(try await transcribe(pcm16: segment))
            } catch TranscriberError.emptyTranscript {
                // A silent/noisy window should not discard valid text from the
                // rest of a long recording.
                continue
            }
        }

        let merged = Self.mergeTranscriptSegments(transcripts)
        guard !merged.isEmpty else { throw TranscriberError.emptyTranscript }
        return merged
    }

    /// Splits only on complete Int16 samples. This helper is intentionally
    /// model-independent so it can be covered with tiny deterministic tests.
    nonisolated static func pcmSegments(_ pcm16: Data, seconds: Int) -> [Data] {
        guard seconds > 0, !pcm16.isEmpty else { return [] }
        let bytesPerWindow = 16_000 * MemoryLayout<Int16>.size * seconds
        guard bytesPerWindow > 0 else { return [] }

        var result: [Data] = []
        result.reserveCapacity((pcm16.count + bytesPerWindow - 1) / bytesPerWindow)
        var offset = 0
        while offset < pcm16.count {
            var end = min(offset + bytesPerWindow, pcm16.count)
            if end < pcm16.count && !end.isMultiple(of: MemoryLayout<Int16>.size) {
                end -= end % MemoryLayout<Int16>.size
            }
            guard end > offset else { break }
            result.append(pcm16.subdata(in: offset..<end))
            offset = end
        }
        return result
    }

    nonisolated static func mergeTranscriptSegments(_ segments: [String]) -> String {
        var merged = ""
        for raw in segments {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let previous = merged.last, let next = text.first,
               previous.isASCII, next.isASCII,
               previous.isLetter || previous.isNumber,
               next.isLetter || next.isNumber {
                merged.append(" ")
            }
            merged.append(text)
        }
        return merged
    }

    private func openSessionIfNeeded() throws -> Session {
        if let session { return session }
        guard let modelURL = Bundle.main.url(forResource: "SenseVoiceSmall-Q8_0", withExtension: "gguf") else {
            throw TranscriberError.modelResourceMissing
        }
        do {
            let model = try Model(path: modelURL.path, options: ModelOptions(backend: .metal))
            let newSession = try model.session()
            session = newSession
            return newSession
        } catch {
            throw TranscriberError.openFailed(String(describing: error))
        }
    }

    // Use the synchronous overload within this actor's serialized inference call.
    nonisolated private static func run(session: Session, samples: [Float]) throws -> String {
        try session.run(samples, options: RunOptions(itn: .on, language: nil)).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func floatSamples(fromLittleEndianPCM16 data: Data) -> [Float] {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return [] }
        var samples = [Float]()
        samples.reserveCapacity(sampleCount)
        data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
            for index in 0..<sampleCount {
                let offset = index * MemoryLayout<Int16>.size
                let low = UInt16(rawBuffer[offset])
                let high = UInt16(rawBuffer[offset + 1])
                let raw = Int16(bitPattern: low | (high << 8))
                samples.append(Float(raw) / 32768.0)
            }
        }
        return samples
    }

}
