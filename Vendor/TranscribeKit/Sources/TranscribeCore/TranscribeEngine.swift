import Foundation
import TranscribeNative

public enum TranscribeEngineError: Error, LocalizedError {
    case notLoaded
    case modelNotFound(String)
    case inferenceFailed(String)
    case modelBusy

    public var errorDescription: String? {
        switch self {
        case .notLoaded: return "ASR 引擎尚未加载模型"
        case .modelNotFound(let name): return "未找到指定的模型文件: \(name)"
        case .inferenceFailed(let msg): return "ASR 推理异常: \(msg)"
        case .modelBusy: return "ASR 模型正忙（有并发请求占用）"
        }
    }
}

/// 单词/分段时间戳信息
public struct TimedSegment: Sendable, Equatable {
    public let text: String
    public let startMs: Int64
    public let endMs: Int64

    public init(text: String, startMs: Int64, endMs: Int64) {
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
    }
}

/// 转写结果
public struct TranscribeResult: Sendable {
    public let text: String
    public let rawText: String
    public let segments: [TimedSegment]
    public let durationMs: Int64

    public init(text: String, rawText: String, segments: [TimedSegment] = [], durationMs: Int64 = 0) {
        self.text = text
        self.rawText = rawText
        self.segments = segments
        self.durationMs = durationMs
    }
}

/// 转写推理选项
public struct TranscribeOptions: Sendable {
    public var language: String?
    public var itn: Bool
    public var nThreads: Int32?
    public var maxInitialTimestamp: Float?

    public init(
        language: String? = nil,
        itn: Bool = true,
        nThreads: Int32? = nil,
        maxInitialTimestamp: Float? = nil
    ) {
        self.language = language
        self.itn = itn
        self.nThreads = nThreads
        self.maxInitialTimestamp = maxInitialTimestamp
    }
}

/// 统一 ASR 引擎抽象协议
public protocol TranscribeEngine: AnyObject, Sendable {
    var isLoaded: Bool { get }
    var loadedModelPath: String? { get }
    var backendName: String { get }

    func load(modelURL: URL) throws
    func transcribe(pcm: [Float], options: TranscribeOptions) throws -> TranscribeResult
    func unload()
}

/// 统一基于 TranscribeNative (transcribe.cpp + ggml + Metal) 的 ASR 推理器
public final class StandardTranscriber: TranscribeEngine, @unchecked Sendable {
    public private(set) var loadedModelPath: String?
    public private(set) var backendName: String = ""
    public var isLoaded: Bool { loaded && session != nil }

    private var model: Model?
    private var session: Session?
    private var loaded = false
    private let lock = NSLock()

    public init() {}

    /// 加载指定 GGUF 模型文件（优先 Metal 硬件加速，自动回退 CPU）
    public func load(modelURL: URL) throws {
        lock.lock()
        defer { lock.unlock() }

        let path = modelURL.path
        if loaded, loadedModelPath == path, session != nil {
            return
        }

        // 释放旧模型资源
        session = nil
        model = nil
        loaded = false

        let loadedModel = try Model(path: path, options: ModelOptions(backend: .auto))
        let loadedSession = try loadedModel.session()

        self.model = loadedModel
        self.session = loadedSession
        self.loadedModelPath = path
        self.backendName = loadedModel.backend
        self.loaded = true
    }

    /// 自动从 ModelRegistry 寻址并加载模型
    public func loadModel(_ modelInfo: ASRModelInfo = ModelRegistry.senseVoice, appGroupID: String? = nil) throws {
        guard let url = ModelRegistry.resolveModelURL(for: modelInfo, appGroupID: appGroupID) else {
            throw TranscribeEngineError.modelNotFound(modelInfo.fileName)
        }
        try load(modelURL: url)
    }

    /// 执行 16kHz mono Float32 PCM 推理
    public func transcribe(pcm: [Float], options: TranscribeOptions = TranscribeOptions()) throws -> TranscribeResult {
        lock.lock()
        defer { lock.unlock() }

        guard let session = self.session else {
            throw TranscribeEngineError.notLoaded
        }

        guard !pcm.isEmpty else {
            return TranscribeResult(text: "", rawText: "")
        }

        let runOpts = RunOptions(
            itn: options.itn ? .on : .off,
            language: options.language
        )

        let transcript: Transcript
        do {
            transcript = try session.run(pcm, options: runOpts)
        } catch {
            throw TranscribeEngineError.inferenceFailed(error.localizedDescription)
        }

        let raw = transcript.text
        let clean = TextCleanup.clean(raw)

        // 解析分段时间戳（若模型输出）
        var timedSegments: [TimedSegment] = []
        for s in transcript.segments {
            timedSegments.append(TimedSegment(
                text: TextCleanup.clean(s.text),
                startMs: s.t0Ms,
                endMs: s.t1Ms
            ))
        }

        let durationMs = Int64(Double(pcm.count) / 16000.0 * 1000.0)
        return TranscribeResult(
            text: clean,
            rawText: raw,
            segments: timedSegments,
            durationMs: durationMs
        )
    }

    /// 卸载模型释放显存/内存（在 App 退至后台、内存受限或切换模型时调用）
    public func unload() {
        lock.lock()
        defer { lock.unlock() }

        session = nil
        model = nil
        loaded = false
        backendName = ""
        loadedModelPath = nil
    }
}
