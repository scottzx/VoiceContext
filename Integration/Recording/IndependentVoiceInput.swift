@preconcurrency import AVFoundation
import Foundation

/// A foreground-only microphone input. Only a bounded command lives in memory;
/// no Recording, audio file, transcript job or background capture is created.
@MainActor
public final class IndependentVoiceInput {
    public enum Event: Sendable {
        case ready, listening, transcribing
        case wakeOnly
        case command(String)
        case timeout
        case failure(String, fatal: Bool)
    }

    private let inferenceService: SenseVoiceInferenceService
    private let worker = MeetingWakeAudioWorker()
    private let microphone = IndependentMicrophone()
    private var generation: UUID?
    private var transcription: Task<Void, Never>?
    private var onEvent: (@MainActor (Event) -> Void)?

    init(inferenceService: SenseVoiceInferenceService) {
        self.inferenceService = inferenceService
    }

    public static var unavailableReason: String? {
        if !TranscriptionModelStore.isReady { return "请先在录音设置中下载并准备本地转写模型。" }
        if !MeetingWakeModelResources.isReady { return "预装唤醒模型缺失或损坏，请重新安装应用。" }
        return nil
    }

    public static func requestMicrophonePermission() async -> Bool {
        await MicrophoneAccess.requestPermissionIfNeeded() == .granted
    }

    /// The host owns AVAudioSession and must grant capture before calling start.
    public func start(direct: Bool = false, onEvent: @escaping @MainActor (Event) -> Void) throws {
        stop()
        if let reason = Self.unavailableReason { throw Self.error(reason) }
        let id = UUID()
        generation = id
        self.onEvent = onEvent
        worker.activate(
            generationID: id, afterSample: 0, requiresWakeWord: !direct, finishOnSilence: true,
            onReady: { [weak self] in
                Task { @MainActor [weak self] in self?.emit(direct ? .listening : .ready, generation: id) }
            },
            onWake: { [weak self] _ in
                Task { @MainActor [weak self] in self?.emit(.listening, generation: id) }
            },
            onCommand: { [weak self] command in
                Task { @MainActor [weak self] in self?.transcribe(command) }
            },
            onTimeout: { [weak self] in
                Task { @MainActor [weak self] in self?.emit(.timeout, generation: id) }
            },
            onError: { [weak self] text, fatal in
                Task { @MainActor [weak self] in self?.emit(.failure(text, fatal: fatal), generation: id) }
            }
        )
        do {
            try microphone.start(
                samples: { [worker] samples, start in worker.enqueue(samples: samples, startSample: start) },
                failure: { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.emit(.failure("语音输入暂时中断，请重新说一次。", fatal: true), generation: id)
                    }
                }
            )
        } catch {
            stop()
            throw error
        }
    }

    public func stop() {
        generation = nil
        onEvent = nil
        transcription?.cancel()
        transcription = nil
        worker.deactivate()
        microphone.stop()
    }

    private func emit(_ event: Event, generation id: UUID) {
        guard generation == id else { return }
        if case .failure(_, let fatal) = event, fatal {
            microphone.stop()
            worker.deactivate()
        }
        onEvent?(event)
    }

    private func transcribe(_ command: MeetingWakeAudioWorker.Command) {
        let id = command.generationID
        guard generation == id else { return }
        microphone.stop()
        worker.deactivate()
        onEvent?(.transcribing)
        transcription = Task { [weak self, inferenceService] in
            do {
                let result = try await inferenceService.transcribe(
                    samples: command.samples, startingAt: command.startSample, waitForMetal: true
                )
                try Task.checkCancellation()
                switch MeetingWakeCommandText.classifyIndependent(result.text) {
                case .wakeOnly:
                    self?.emit(.wakeOnly, generation: id)
                case .command(let text):
                    self?.emit(.command(text), generation: id)
                case .empty:
                    self?.emit(.failure("没有听清指令，请重新说一次。", fatal: false), generation: id)
                }
            } catch is CancellationError {
                // A closed or paused input never delivers a late command.
            } catch {
                self?.emit(.failure("指令识别失败，请重新说一次：\(error.localizedDescription)", fatal: false), generation: id)
            }
        }
    }

    private static func error(_ text: String) -> NSError {
        NSError(domain: "Yima.VoiceInput", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}

/// The real-time callback only copies PCM. Conversion and keyword inference use
/// serial workers, with a fixed queue bound so a slow device cannot grow memory.
nonisolated private final class IndependentMicrophone: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "Yima.IndependentVoicePCM", qos: .userInitiated)
    private let lock = NSLock()
    private var generation: UUID?
    private var pending = 0
    private var tapInstalled = false

    func start(samples: @escaping @Sendable ([Float], Int64) -> Void,
               failure: @escaping @Sendable () -> Void) throws {
        stop()
        let source = engine.inputNode.outputFormat(forBus: 0)
        guard source.sampleRate > 0, source.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: target) else {
            throw NSError(domain: "Yima.VoiceInput", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "当前无法使用麦克风，请检查音频输入。"])
        }
        let id = UUID()
        lock.withLock { generation = id; pending = 0 }
        let conversion = Conversion(converter: converter, target: target)
        engine.inputNode.installTap(onBus: 0, bufferSize: 1_024, format: source) { [weak self] buffer, _ in
            guard let self else { return }
            let accepted = lock.withLock { () -> Bool in
                guard self.generation == id else { return false }
                guard self.pending < 16 else { self.generation = nil; failure(); return false }
                self.pending += 1
                return true
            }
            guard accepted, let copy = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: buffer.frameLength) else { return }
            copy.frameLength = buffer.frameLength
            let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
            let output = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for index in input.indices {
                if let from = input[index].mData, let to = output[index].mData {
                    memcpy(to, from, Int(input[index].mDataByteSize))
                }
            }
            queue.async { [weak self] in
                guard let self else { return }
                defer { lock.withLock { if self.generation == id { self.pending = max(0, self.pending - 1) } } }
                guard lock.withLock({ self.generation == id }) else { return }
                do {
                    let pcm = try conversion.convert(copy)
                    let start = conversion.cursor
                    conversion.cursor += Int64(pcm.count)
                    guard lock.withLock({ self.generation == id }) else { return }
                    samples(pcm, start)
                } catch { failure() }
            }
        }
        tapInstalled = true
        do { try engine.start() } catch { stop(); throw error }
    }

    func stop() {
        lock.withLock { generation = nil; pending = 0 }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
    }

    private final class Conversion: @unchecked Sendable {
        let converter: AVAudioConverter
        let target: AVAudioFormat
        var cursor: Int64 = 0
        init(converter: AVAudioConverter, target: AVAudioFormat) {
            self.converter = converter
            self.target = target
        }
        func convert(_ input: AVAudioPCMBuffer) throws -> [Float] {
            let capacity = AVAudioFrameCount(Double(input.frameLength) * 16_000 / input.format.sampleRate + 512)
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }
            var provided = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                guard !provided else { state.pointee = .noDataNow; return nil }
                provided = true
                state.pointee = .haveData
                return input
            }
            if let error { throw error }
            guard status != .error, let channel = output.floatChannelData?[0] else {
                throw NSError(domain: "Yima.VoiceInput", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "麦克风音频转换失败。"])
            }
            return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        }
    }
}
