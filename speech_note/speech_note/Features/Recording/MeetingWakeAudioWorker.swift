import Foundation
import SherpaOnnxC

/// Consumes the recorder's PCM without owning a microphone or audio session.
/// Native inference and command buffering are confined to one serial queue.
nonisolated final class MeetingWakeAudioWorker: @unchecked Sendable {
    struct Wake: Sendable {
        let generationID: UUID
        let startSample: Int64
        let endSample: Int64
    }

    struct Command: Sendable {
        let generationID: UUID
        let samples: [Float]
        let startSample: Int64
        let endSample: Int64
    }

    private struct Activation: Sendable {
        let generationID: UUID
        let afterSample: Int64
        let finishOnSilence: Bool
        let onReady: @Sendable () -> Void
        let onWake: @Sendable (Wake) -> Void
        let onCommand: @Sendable (Command) -> Void
        let onTimeout: @Sendable () -> Void
        let onError: @Sendable (String, Bool) -> Void
    }

    private let queue = DispatchQueue(label: "Yima.MeetingWakeAudio", qos: .userInitiated)
    private let lock = NSLock()
    private let maximumPendingSamples = 16_000
    private var activeGenerationID: UUID?
    private var pendingSamples = 0
    private var droppedThroughSample: Int64 = 0

    // Only accessed on queue.
    private var runtime: Runtime?
    private var activation: Activation?
    private var collector = MeetingWakeCommandCapture()
    private var frameSamples: [Float] = []
    private var frameStartSample: Int64 = 0
    private var audioStartSample: Int64 = 0
    private var expectedNextSample: Int64?
    private var hasWake = false

    func activate(
        generationID: UUID,
        afterSample: Int64,
        requiresWakeWord: Bool = true,
        finishOnSilence: Bool = false,
        onReady: @escaping @Sendable () -> Void,
        onWake: @escaping @Sendable (Wake) -> Void,
        onCommand: @escaping @Sendable (Command) -> Void,
        onTimeout: @escaping @Sendable () -> Void,
        onError: @escaping @Sendable (String, Bool) -> Void
    ) {
        let activation = Activation(
            generationID: generationID, afterSample: afterSample, finishOnSilence: finishOnSilence,
            onReady: onReady, onWake: onWake, onCommand: onCommand,
            onTimeout: onTimeout, onError: onError
        )
        lock.withLock {
            activeGenerationID = generationID
            pendingSamples = 0
            droppedThroughSample = afterSample
            // Schedule setup before the first PCM packet can acquire lock.
            queue.async { [weak self] in
                guard let self, isCurrent(generationID) else { return }
                do {
                    if runtime == nil { runtime = try Runtime() }
                    try resetCapture()
                    self.activation = activation
                    if !requiresWakeWord {
                        collector.beginCommand(at: afterSample, finishOnSilence: finishOnSilence)
                        hasWake = true
                    }
                    if isCurrent(generationID) { activation.onReady() }
                } catch {
                    guard finish(generationID) else { return }
                    self.activation = nil
                    activation.onError(error.localizedDescription, true)
                }
            }
        }
    }

    func deactivate() {
        lock.withLock {
            activeGenerationID = nil
            pendingSamples = 0
            queue.async { [weak self] in
                guard let self else { return }
                activation = nil
                collector.reset()
                frameSamples.removeAll(keepingCapacity: true)
                expectedNextSample = nil
                hasWake = false
            }
        }
    }

    /// Bounded and nonblocking apart from the small state lock. Overload only
    /// discards assistant input; the recorder still writes every audio packet.
    func enqueue(samples: [Float], startSample: Int64) {
        guard !samples.isEmpty else { return }
        let generationID = lock.withLock { () -> UUID? in
            guard let generationID = activeGenerationID else { return nil }
            guard pendingSamples + samples.count <= maximumPendingSamples else {
                droppedThroughSample = max(droppedThroughSample, startSample + Int64(samples.count))
                return nil
            }
            pendingSamples += samples.count
            return generationID
        }
        guard let generationID else { return }
        queue.async { [weak self] in
            guard let self else { return }
            defer {
                lock.withLock {
                    if self.activeGenerationID == generationID {
                        self.pendingSamples = max(0, self.pendingSamples - samples.count)
                    }
                }
            }
            consume(samples, startingAt: startSample, generationID: generationID)
        }
    }

    private func consume(_ input: [Float], startingAt inputStart: Int64, generationID: UUID) {
        guard let activation, activation.generationID == generationID,
              let runtime, isCurrent(generationID) else { return }
        let boundary = lock.withLock { droppedThroughSample }
        let start = max(inputStart, max(activation.afterSample, boundary))
        let skip = Int(start - inputStart)
        guard skip < input.count else { return }
        let samples = skip == 0 ? input : Array(input.dropFirst(skip))

        if let expectedNextSample, start != expectedNextSample {
            do {
                try resetCapture()
                if isCurrent(generationID) {
                    activation.onError("唤醒音频处理暂时落后，请再叫一次小蓝同学。", false)
                }
            } catch {
                fail(error, activation: activation)
                return
            }
        }
        if expectedNextSample == nil { audioStartSample = start }
        expectedNextSample = start + Int64(samples.count)
        if frameSamples.isEmpty { frameStartSample = start }
        frameSamples.append(contentsOf: samples)

        while frameSamples.count >= 512, isCurrent(generationID) {
            let frame = Array(frameSamples.prefix(512))
            frameSamples.removeFirst(512)
            let start = frameStartSample
            let end = start + 512
            frameStartSample = end
            let isSpeech = runtime.detectSpeech(frame)
            if let event = collector.append(samples: frame, startingAt: start, isSpeech: isSpeech) {
                switch event {
                case .command(let command):
                    guard finish(generationID) else { return }
                    activation.onCommand(Command(
                        generationID: generationID, samples: command.samples,
                        startSample: command.startSample, endSample: command.endSample
                    ))
                    return
                case .timedOut:
                    hasWake = false
                    if isCurrent(generationID) { activation.onTimeout() }
                    do { try runtime.resetKeywordStream() } catch {
                        fail(error, activation: activation)
                        return
                    }
                case .tooLong, .discontinuity:
                    hasWake = false
                    if isCurrent(generationID) {
                        activation.onError("这次指令没有完整收好，请再叫一次小蓝同学。", false)
                    }
                    do { try runtime.resetKeywordStream() } catch {
                        fail(error, activation: activation)
                        return
                    }
                }
            }
            guard !hasWake else { continue }
            if let duration = runtime.keywordDuration(frame), isCurrent(generationID) {
                // Sherpa can reset token timestamps internally during long
                // silence. Use their span, not an assumed absolute origin.
                // Keep the whole phrase for ASR so this estimate never trims
                // an instruction spoken immediately after the wake word.
                let wakeEnd = max(activation.afterSample, end - 2_560)
                let wakeStart = max(audioStartSample, max(end - 48_000, wakeEnd - duration - 3_200))
                if collector.wake(startSample: wakeStart, endSample: wakeEnd,
                                  finishOnSilence: activation.finishOnSilence) {
                    hasWake = true
                    activation.onWake(Wake(
                        generationID: generationID,
                        startSample: wakeStart, endSample: wakeEnd
                    ))
                }
            }
        }
    }

    private func resetCapture() throws {
        collector.reset()
        frameSamples.removeAll(keepingCapacity: true)
        expectedNextSample = nil
        hasWake = false
        try runtime?.reset()
    }

    private func isCurrent(_ generationID: UUID) -> Bool {
        lock.withLock { activeGenerationID == generationID }
    }

    @discardableResult private func finish(_ generationID: UUID) -> Bool {
        lock.withLock {
            guard activeGenerationID == generationID else { return false }
            activeGenerationID = nil
            pendingSamples = 0
            return true
        }
    }

    private func fail(_ error: Error, activation: Activation) {
        guard finish(activation.generationID) else { return }
        self.activation = nil
        activation.onError(error.localizedDescription, true)
    }

    private final class Runtime {
        private var spotter: OpaquePointer?
        private var stream: OpaquePointer?
        private var vad: OpaquePointer?

        private enum LoadError: LocalizedError {
            case keywordModel, vadModel
            var errorDescription: String? {
                switch self {
                case .keywordModel: "无法加载预装唤醒词模型。"
                case .vadModel: "无法加载语音活动检测模型，请先完成语音转文字模型准备。"
                }
            }
        }

        init() throws {
            let root = try MeetingWakeModelResources.requiredResourceRoot()
            let vadURL = try TranscriptionModelStore.modelURL(id: "silero-vad")
            var config = SherpaOnnxKeywordSpotterConfig()
            config.feat_config.sample_rate = 16_000
            config.feat_config.feature_dim = 80
            config.model_config.num_threads = 1
            config.max_active_paths = 4
            config.num_trailing_blanks = 1
            config.keywords_score = 1.0
            config.keywords_threshold = 0.25
            spotter = root.appendingPathComponent("encoder.onnx").path.withCString { encoder in
                root.appendingPathComponent("decoder.onnx").path.withCString { decoder in
                    root.appendingPathComponent("joiner.onnx").path.withCString { joiner in
                        root.appendingPathComponent("tokens.txt").path.withCString { tokens in
                            root.appendingPathComponent("keywords.txt").path.withCString { keywords in
                                "cpu".withCString { provider in
                                    config.model_config.transducer.encoder = encoder
                                    config.model_config.transducer.decoder = decoder
                                    config.model_config.transducer.joiner = joiner
                                    config.model_config.tokens = tokens
                                    config.model_config.provider = provider
                                    config.keywords_file = keywords
                                    return SherpaOnnxCreateKeywordSpotter(&config)
                                }
                            }
                        }
                    }
                }
            }
            guard spotter != nil else { throw LoadError.keywordModel }
            var vadConfig = SherpaOnnxVadModelConfig()
            vadConfig.silero_vad.threshold = 0.5
            vadConfig.silero_vad.min_silence_duration = 0.2
            vadConfig.silero_vad.min_speech_duration = 0.1
            vadConfig.silero_vad.max_speech_duration = 20
            vadConfig.silero_vad.window_size = 512
            vadConfig.sample_rate = 16_000
            vadConfig.num_threads = 1
            vad = vadURL.path.withCString { model in
                "cpu".withCString { provider in
                    vadConfig.silero_vad.model = model
                    vadConfig.provider = provider
                    return SherpaOnnxCreateVoiceActivityDetector(&vadConfig, 30)
                }
            }
            guard vad != nil else {
                if let spotter { SherpaOnnxDestroyKeywordSpotter(spotter) }
                spotter = nil
                throw LoadError.vadModel
            }
        }

        deinit {
            if let stream { SherpaOnnxDestroyOnlineStream(stream) }
            if let spotter { SherpaOnnxDestroyKeywordSpotter(spotter) }
            if let vad { SherpaOnnxDestroyVoiceActivityDetector(vad) }
        }

        func reset() throws {
            try resetKeywordStream()
            if let vad { SherpaOnnxVoiceActivityDetectorReset(vad) }
        }

        func resetKeywordStream() throws {
            if let stream { SherpaOnnxDestroyOnlineStream(stream) }
            stream = nil
            if let spotter { stream = SherpaOnnxCreateKeywordStream(spotter) }
            guard stream != nil else { throw LoadError.keywordModel }
        }

        func detectSpeech(_ samples: [Float]) -> Bool {
            guard let vad else { return false }
            samples.withUnsafeBufferPointer {
                SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, $0.baseAddress, Int32($0.count))
            }
            let detected = SherpaOnnxVoiceActivityDetectorDetected(vad) != 0
            SherpaOnnxVoiceActivityDetectorClear(vad)
            return detected
        }

        func keywordDuration(_ samples: [Float]) -> Int64? {
            guard let spotter, let stream else { return nil }
            samples.withUnsafeBufferPointer {
                SherpaOnnxOnlineStreamAcceptWaveform(stream, 16_000, $0.baseAddress, Int32($0.count))
            }
            while SherpaOnnxIsKeywordStreamReady(spotter, stream) != 0 {
                SherpaOnnxDecodeKeywordStream(spotter, stream)
                guard let result = SherpaOnnxGetKeywordResult(spotter, stream) else { continue }
                defer { SherpaOnnxDestroyKeywordResult(result) }
                guard let keyword = result.pointee.keyword, keyword.pointee != 0 else { continue }
                let count = Int(result.pointee.count)
                guard count > 0, let timestamps = result.pointee.timestamps else { return 16_000 }
                let duration = Double(timestamps[count - 1] - timestamps[0])
                return Int64(max(0.2, min(3.0, duration)) * 16_000)
            }
            return nil
        }
    }
}
