@preconcurrency import AVFoundation
import Foundation
import OSLog

nonisolated final class AACSegmentRecorder: @unchecked Sendable {
    nonisolated static let targetSampleRate: Double = 16_000
    nonisolated static let defaultSegmentLengthSamples: Int64 = 960_000
    nonisolated static var defaultSegmentDuration: TimeInterval {
        TimeInterval(defaultSegmentLengthSamples) / targetSampleRate
    }

    nonisolated enum RecorderError: LocalizedError {
        case microphonePermissionDenied
        case noInputFormat
        case audioConverterInitializationFailed
        case notRecording
        case bufferCopyFailed
        case writerBackpressure

        var errorDescription: String? {
            switch self {
            case .microphonePermissionDenied: "未获得麦克风权限。"
            case .noInputFormat: "当前音频路由没有可用输入格式。"
            case .audioConverterInitializationFailed: "无法将麦克风输入转换为 16 kHz 录音。"
            case .notRecording: "录音尚未开始。"
            case .bufferCopyFailed: "无法复制麦克风音频缓冲区。"
            case .writerBackpressure: "录音写入队列已满，当前音频缓冲区未能写入。"
            }
        }
    }

    nonisolated struct Segment: Sendable, Equatable, Identifiable {
        let id: UUID
        let url: URL
        let startSample: Int64
        let endSample: Int64
        let startedAt: Date
        let endedAt: Date

        var sampleCount: Int64 { endSample - startSample }
    }

    nonisolated struct CaptureEvent: Sendable, Equatable {
        nonisolated enum Kind: Sendable, Equatable {
            case interruptionBegan
            case interruptionEnded(shouldResume: Bool)
            case routeChanged
            case writerBackpressure
            case writeFailed
            case engineConfigurationChanged
        }

        nonisolated struct Diagnostic: Sendable, Equatable {
            let operation: String
            let domain: String
            let code: Int
            let message: String

            init(operation: String, error: Error) {
                let error = error as NSError
                self.operation = operation
                domain = error.domain
                code = error.code
                message = error.localizedDescription
            }

            var description: String {
                "operation=\(operation) domain=\(domain) code=\(code) message=\(message)"
            }
        }

        let kind: Kind
        let occurredAt: Date
        let sampleIndex: Int64
        let diagnostic: Diagnostic?

        init(kind: Kind, occurredAt: Date, sampleIndex: Int64, diagnostic: Diagnostic? = nil) {
            self.kind = kind
            self.occurredAt = occurredAt
            self.sampleIndex = sampleIndex
            self.diagnostic = diagnostic
        }
    }

    var onSegmentClosed: (@Sendable (Segment) -> Void)?
    var onCaptureEvent: (@Sendable (CaptureEvent) -> Void)?
    var onMeteringUpdate: (@Sendable (AudioInputMetrics) -> Void)?

    var silenceThresholdDB: Float = -45.0
    private let preRollCapacitySamples = 6_400
    private let hangoverCapacitySamples: Int64 = 19_200
    private var preRollBuffer: [Float] = []
    private var isVoiced = false
    private var remainingHangoverSamples: Int64 = 0
    private var masterSampleCursor: Int64 = 0
    private var segmentLengthSamples: Int64 = AACSegmentRecorder.defaultSegmentLengthSamples
    private var activeSegmentEndSample: Int64 = 0

    private let engine = AVAudioEngine()
    private let audioOwner = UUID()
    private let session = AVAudioSession.sharedInstance()
    private let writerQueue = DispatchQueue(label: "VoiceContext.AACSegmentWriter", qos: .userInitiated)
    private let statusLock = NSLock()
    private let logger = Logger(subsystem: "com.yima.recording", category: "AACCapture")
    private var assistantPCMHandler: (@Sendable ([Float], Int64) -> Void)?
    private var meteringUpdatesEnabled = true
    private var activeFile: AVAudioFile?
    private var activeID: UUID?
    private var activeURL: URL?
    private var activeStartedAt: Date?
    private var activeStartSample: Int64 = 0
    private var audioConverter: AVAudioConverter?
    private var recordingFormat: AVAudioFormat?
    private var directory: URL?
    private var pendingPacketCount = 0
    private var pendingAssistantSampleEstimate: Double = 0
    private var assistantPacketReserveSamples: Double = 0
    private var assistantConverterReserveSamples: Double = 0
    private var tapInstalled = false
    private var inputTapInstalled = false
    private var isCapturePaused = false
    private var isSystemInterrupted = false
    private var isRebuildingInput = false
    private var lastClosedSegment: Segment?
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var configurationChangeObserver: NSObjectProtocol?

    private let maximumPendingPackets = 256

    deinit {
        interruptionObserver.map(NotificationCenter.default.removeObserver)
        routeChangeObserver.map(NotificationCenter.default.removeObserver)
        configurationChangeObserver.map(NotificationCenter.default.removeObserver)
    }

    var currentSample: Int64 {
        statusLock.withLock { masterSampleCursor }
    }

    /// Receives the existing 16 kHz mono stream on the writer queue. The
    /// handler must only enqueue work; inference must not delay recording.
    func setAssistantPCMHandler(_ handler: (@Sendable ([Float], Int64) -> Void)?) {
        statusLock.withLock { assistantPCMHandler = handler }
    }

    func setMeteringUpdatesEnabled(_ enabled: Bool) {
        statusLock.withLock { meteringUpdatesEnabled = enabled }
    }

    /// Conservative input boundary for assistant enable/speech windows. Unlike
    /// currentSample, this includes packets waiting on the writer and a buffer
    /// plus converter priming reserve, without waiting for disk writes.
    var assistantSampleBoundary: Int64 {
        statusLock.withLock {
            masterSampleCursor + Int64(ceil(
                pendingAssistantSampleEstimate
                    + assistantPacketReserveSamples
                    + assistantConverterReserveSamples
            ))
        }
    }

    func start(
        in directory: URL,
        segmentDuration: TimeInterval = AACSegmentRecorder.defaultSegmentDuration,
        initialSampleOffset: Int64 = 0
    ) async throws {
        guard !statusLock.withLock({ tapInstalled }) else { return }
        let permission = AVAudioApplication.shared.recordPermission
        if permission != .granted {
            let granted = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            }
            guard granted else { throw RecorderError.microphonePermissionDenied }
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        statusLock.withLock {
            isCapturePaused = false
            isSystemInterrupted = false
        }
        try activateCaptureSession()
        var started = false
        defer { if !started { releaseCaptureSession() } }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.noInputFormat
        }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AACSegmentRecorder.targetSampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw RecorderError.audioConverterInitializationFailed
        }

        try writerQueue.sync {
            self.directory = directory
            let segmentLen = max(1, Int64(segmentDuration * targetFormat.sampleRate))
            segmentLengthSamples = segmentLen
            audioConverter = converter
            recordingFormat = targetFormat
            statusLock.withLock {
                masterSampleCursor = initialSampleOffset
                pendingPacketCount = 0
                pendingAssistantSampleEstimate = 0
                let ratio = targetFormat.sampleRate / inputFormat.sampleRate
                assistantPacketReserveSamples = 1_024 * ratio
                assistantConverterReserveSamples = (
                    Double(converter.primeInfo.leadingFrames)
                        + Double(converter.primeInfo.trailingFrames)
                ) * ratio + 32
            }
            lastClosedSegment = nil
            preRollBuffer = []
            isVoiced = false
            remainingHangoverSamples = 0
            activeFile = nil
            activeID = nil
            activeURL = nil
            activeStartedAt = nil
            activeStartSample = initialSampleOffset
            activeSegmentEndSample = initialSampleOffset
        }

        input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            self?.bufferFromAudioCallback(buffer)
        }
        statusLock.withLock {
            tapInstalled = true
            inputTapInstalled = true
        }
        observeAudioSession()
        do {
            try engine.start()
            started = true
        } catch {
            input.removeTap(onBus: 0)
            statusLock.withLock {
                tapInstalled = false
                inputTapInstalled = false
            }
            _ = writerQueue.sync { closeSegment(at: Date()) }
            releaseCaptureSession()
            throw error
        }
    }

    func stop() throws -> Segment {
        let wasRecording = statusLock.withLock { () -> Bool in
            guard tapInstalled else { return false }
            tapInstalled = false
            return true
        }
        guard wasRecording else { throw RecorderError.notRecording }

        removeInputTapIfNeeded()
        engine.stop()
        defer { releaseCaptureSession() }
        let segment = try writerQueue.sync {
            let closed = closeSegment(at: Date()) ?? lastClosedSegment
            if let closed {
                audioConverter = nil
                recordingFormat = nil
                return closed
            }
            let fallback = try createFallbackSilentSegment(at: Date())
            audioConverter = nil
            recordingFormat = nil
            return fallback
        }
        return segment
    }

    func cancel() {
        let wasRecording = statusLock.withLock { () -> Bool in
            guard tapInstalled else { return false }
            tapInstalled = false
            return true
        }
        guard wasRecording else { return }

        removeInputTapIfNeeded()
        engine.stop()
        writerQueue.sync {
            activeFile = nil
            activeID = nil
            activeURL = nil
            activeStartedAt = nil
            lastClosedSegment = nil
            audioConverter = nil
            recordingFormat = nil
            isVoiced = false
            remainingHangoverSamples = 0
            preRollBuffer.removeAll()
        }
        releaseCaptureSession()
    }

    func pause() throws {
        guard statusLock.withLock({ tapInstalled }) else { throw RecorderError.notRecording }
        statusLock.withLock { isCapturePaused = true }
        engine.pause()
        writerQueue.sync {
            _ = closeSegment(at: Date())
            isVoiced = false
            remainingHangoverSamples = 0
            preRollBuffer.removeAll()
        }
    }

    func resume() throws {
        guard statusLock.withLock({ tapInstalled }) else { throw RecorderError.notRecording }
        do {
            try activateCaptureSession()
            if !engine.isRunning {
                try rebuildInputAfterEngineStopped()
                try engine.start()
            }
            statusLock.withLock {
                isCapturePaused = false
                isSystemInterrupted = false
            }
        } catch {
            let diagnostic = CaptureEvent.Diagnostic(operation: "resume", error: error)
            logger.error("[RecordingCapture] \(diagnostic.description, privacy: .public)")
            throw error
        }
    }

    private func removeInputTapIfNeeded() {
        let shouldRemove = statusLock.withLock {
            let installed = inputTapInstalled
            inputTapInstalled = false
            return installed
        }
        if shouldRemove { engine.inputNode.removeTap(onBus: 0) }
    }

    /// A stopped engine may have a new hardware format after a route change.
    /// Keep the sample cursor and closed files; replace only the input pipeline.
    private func rebuildInputAfterEngineStopped() throws {
        statusLock.withLock { isRebuildingInput = true }
        defer { statusLock.withLock { isRebuildingInput = false } }
        engine.stop()
        removeInputTapIfNeeded()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.noInputFormat
        }
        try writerQueue.sync {
            _ = closeSegment(at: Date())
            guard let recordingFormat,
                  let converter = AVAudioConverter(from: inputFormat, to: recordingFormat) else {
                throw RecorderError.audioConverterInitializationFailed
            }
            audioConverter = converter
            preRollBuffer.removeAll()
            isVoiced = false
            remainingHangoverSamples = 0
            statusLock.withLock {
                let ratio = recordingFormat.sampleRate / inputFormat.sampleRate
                assistantPacketReserveSamples = 1_024 * ratio
                assistantConverterReserveSamples = (
                    Double(converter.primeInfo.leadingFrames) + Double(converter.primeInfo.trailingFrames)
                ) * ratio + 32
            }
        }
        input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            self?.bufferFromAudioCallback(buffer)
        }
        statusLock.withLock { inputTapInstalled = true }
    }

    /// Restore the `.record` category after other audio. Engine start is owned
    /// by the session coordinator so UI only shows 正在录音 after resume succeeds.
    func restoreCaptureSessionIfOwned() {
        guard statusLock.withLock({ tapInstalled && !isCapturePaused && !isSystemInterrupted }) else { return }
        do {
            try activateCaptureSession()
        } catch {
            let diagnostic = CaptureEvent.Diagnostic(operation: "restoreCaptureSession", error: error)
            logger.error("[RecordingCapture] \(diagnostic.description, privacy: .public)")
        }
    }

    private func bufferFromAudioCallback(_ buffer: AVAudioPCMBuffer) {
        guard let packet = copy(buffer) else {
            emit(.writeFailed, operation: "copyInputBuffer", error: RecorderError.bufferCopyFailed)
            return
        }
        let assistantSampleEstimate = Double(packet.frameLength)
            * Self.targetSampleRate / packet.format.sampleRate
        let accepted = statusLock.withLock { () -> Bool in
            guard pendingPacketCount < maximumPendingPackets else { return false }
            pendingPacketCount += 1
            pendingAssistantSampleEstimate += assistantSampleEstimate
            assistantPacketReserveSamples = max(assistantPacketReserveSamples, assistantSampleEstimate)
            return true
        }
        guard accepted else {
            emit(.writerBackpressure, operation: "enqueueInputBuffer", error: RecorderError.writerBackpressure)
            return
        }

        writerQueue.async { [weak self] in
            guard let self else { return }
            defer {
                statusLock.withLock {
                    self.pendingPacketCount -= 1
                    self.pendingAssistantSampleEstimate = max(
                        0, self.pendingAssistantSampleEstimate - assistantSampleEstimate
                    )
                }
            }
            consume(packet)
        }
    }

    private func consume(_ inputBuffer: AVAudioPCMBuffer) {
        guard statusLock.withLock({ tapInstalled }) else { return }
        do {
            guard let converted = try convertForRecording(inputBuffer), converted.frameLength > 0 else {
                return
            }
            guard let channelData = converted.floatChannelData?[0] else { return }
            let frameCount = Int(converted.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))

            if statusLock.withLock({ meteringUpdatesEnabled }),
               let metrics = AudioInputMetrics.from(samples: samples.withUnsafeBufferPointer { $0 }) {
                onMeteringUpdate?(metrics)
            }

            let metrics = AudioInputMetrics.from(samples: samples)
            let isCurrentVoiced = metrics.rmsDecibels >= silenceThresholdDB

            let bufferStartSample = statusLock.withLock { masterSampleCursor }
            let bufferEndSample = bufferStartSample + Int64(frameCount)
            let assistantHandler = statusLock.withLock {
                masterSampleCursor = bufferEndSample
                return assistantPCMHandler
            }
            assistantHandler?(samples, bufferStartSample)

            if isCurrentVoiced {
                if !isVoiced {
                    isVoiced = true
                    if !preRollBuffer.isEmpty {
                        let preRollCount = Int64(preRollBuffer.count)
                        let preRollStart = bufferStartSample - preRollCount
                        if let preRollAudioBuffer = buffer(from: preRollBuffer) {
                            try writeSlices(preRollAudioBuffer, absoluteStartSample: preRollStart)
                        }
                        preRollBuffer.removeAll()
                    }
                }
                remainingHangoverSamples = hangoverCapacitySamples
                try writeSlices(converted, absoluteStartSample: bufferStartSample)
            } else if isVoiced {
                remainingHangoverSamples -= Int64(frameCount)
                if remainingHangoverSamples > 0 {
                    try writeSlices(converted, absoluteStartSample: bufferStartSample)
                } else {
                    remainingHangoverSamples = 0
                    isVoiced = false
                    _ = closeSegment(at: Date())
                    preRollBuffer = samples
                    if preRollBuffer.count > preRollCapacitySamples {
                        preRollBuffer.removeFirst(preRollBuffer.count - preRollCapacitySamples)
                    }
                }
            } else {
                preRollBuffer.append(contentsOf: samples)
                if preRollBuffer.count > preRollCapacitySamples {
                    preRollBuffer.removeFirst(preRollBuffer.count - preRollCapacitySamples)
                }
            }
        } catch {
            emit(.writeFailed, operation: "convertOrWriteAudio", error: error)
        }
    }

    private func writeSlices(_ buffer: AVAudioPCMBuffer, absoluteStartSample: Int64) throws {
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        var currentStart = absoluteStartSample
        var offset = 0
        var remaining = count

        while remaining > 0 {
            let nextBoundary = ((currentStart / segmentLengthSamples) + 1) * segmentLengthSamples
            let available = Int(min(Int64(remaining), nextBoundary - currentStart))
            let sliceEnd = currentStart + Int64(available)
            let crossesBoundary = (sliceEnd == nextBoundary)

            if activeFile == nil {
                try openNextSegment(startedAt: Date(), startingSample: currentStart)
            }

            let slice = try sliceBuffer(
                buffer,
                sourceOffset: offset,
                frameCount: available
            )
            try activeFile?.write(from: slice)
            activeSegmentEndSample = sliceEnd

            if crossesBoundary {
                _ = closeSegment(at: Date())
            }

            offset += available
            currentStart = sliceEnd
            remaining -= available
        }
    }

    private func buffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard let recordingFormat, !samples.isEmpty else { return nil }
        guard let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: recordingFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return nil }
        pcmBuffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = pcmBuffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { ptr in
                if let base = ptr.baseAddress {
                    channel.update(from: base, count: samples.count)
                }
            }
        }
        return pcmBuffer
    }

    private func createFallbackSilentSegment(at endedAt: Date) throws -> Segment {
        let start = statusLock.withLock { masterSampleCursor }
        try openNextSegment(startedAt: endedAt, startingSample: start)
        let silenceCount = 1_600
        let silenceSamples = Array(repeating: Float(0), count: silenceCount)
        if let silenceBuffer = buffer(from: silenceSamples) {
            try activeFile?.write(from: silenceBuffer)
            activeSegmentEndSample = start + Int64(silenceCount)
        }
        guard let segment = closeSegment(at: endedAt) else {
            throw RecorderError.notRecording
        }
        return segment
    }

    private func convertForRecording(_ inputBuffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
        guard let audioConverter, let recordingFormat else {
            throw RecorderError.audioConverterInitializationFailed
        }
        let ratio = recordingFormat.sampleRate / inputBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * ratio)) + 32
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: recordingFormat, frameCapacity: capacity) else {
            throw RecorderError.audioConverterInitializationFailed
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = audioConverter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            guard !suppliedInput else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }
        if let conversionError { throw conversionError }
        switch status {
        case .haveData, .inputRanDry:
            return outputBuffer
        case .endOfStream:
            return outputBuffer.frameLength > 0 ? outputBuffer : nil
        case .error:
            throw RecorderError.audioConverterInitializationFailed
        @unknown default:
            throw RecorderError.audioConverterInitializationFailed
        }
    }

    private func openNextSegment(startedAt: Date, startingSample: Int64) throws {
        guard let directory, let recordingFormat else {
            throw RecorderError.audioConverterInitializationFailed
        }
        let timeDir = AACChunkBoundaryPlanner.timeDirectory(
            for: startingSample,
            sampleRate: AACSegmentRecorder.targetSampleRate
        )
        let segmentDir = directory.appendingPathComponent(timeDir, isDirectory: true)
        try FileManager.default.createDirectory(at: segmentDir, withIntermediateDirectories: true)
        let id = UUID()
        let url = segmentDir.appendingPathComponent("audio-\(id.uuidString.lowercased()).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: AACSegmentRecorder.targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        activeFile = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: recordingFormat.commonFormat,
            interleaved: recordingFormat.isInterleaved
        )
        activeID = id
        activeURL = url
        activeStartedAt = startedAt
        activeStartSample = startingSample
        activeSegmentEndSample = startingSample
    }

    private func releaseCaptureSession() {
        if let handlers = RecordingAudioBridge.handlers {
            handlers.release(audioOwner)
        } else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func activateCaptureSession() throws {
        if let handlers = RecordingAudioBridge.handlers {
            try handlers.capture(audioOwner)
            return
        }
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
    }

    private func closeSegment(at endedAt: Date) -> Segment? {
        guard
            let id = activeID,
            let url = activeURL,
            let startedAt = activeStartedAt
        else { return nil }
        // Drop AVAudioFile on this writer queue so the moov atom is written
        // before persistence/transcription see the path.
        do {
            let fileToClose = activeFile
            activeFile = nil
            withExtendedLifetime(fileToClose) {}
        }
        activeID = nil
        activeURL = nil
        activeStartedAt = nil
        let segment = Segment(
            id: id,
            url: url,
            startSample: activeStartSample,
            endSample: activeSegmentEndSample,
            startedAt: startedAt,
            endedAt: endedAt
        )
        lastClosedSegment = segment
        onSegmentClosed?(segment)
        return segment
    }

    private func observeAudioSession() {
        interruptionObserver.map(NotificationCenter.default.removeObserver)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }

        routeChangeObserver.map(NotificationCenter.default.removeObserver)
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            self?.emit(.routeChanged)
        }

        configurationChangeObserver.map(NotificationCenter.default.removeObserver)
        configurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self,
                  self.statusLock.withLock({ self.tapInstalled && !self.isCapturePaused && !self.isSystemInterrupted && !self.isRebuildingInput }),
                  !self.engine.isRunning else { return }
            self.logger.warning("[RecordingCapture] engine configuration changed; capture engine stopped")
            self.emit(.engineConfigurationChanged)
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard statusLock.withLock({ tapInstalled }) else { return }
        guard
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }
        switch type {
        case .began:
            statusLock.withLock { isSystemInterrupted = true }
            writerQueue.sync {
                _ = closeSegment(at: Date())
                isVoiced = false
                remainingHangoverSamples = 0
                preRollBuffer.removeAll()
            }
            emit(.interruptionBegan)
        case .ended:
            statusLock.withLock { isSystemInterrupted = false }
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
            logger.info("[RecordingCapture] interruption ended shouldResume=\(shouldResume) sample=\(self.currentSample)")
            emit(.interruptionEnded(shouldResume: shouldResume))
        @unknown default:
            break
        }
    }

    private func emit(_ kind: CaptureEvent.Kind, operation: String = "capture", error: Error? = nil) {
        let diagnostic = error.map { CaptureEvent.Diagnostic(operation: operation, error: $0) }
        if let diagnostic {
            logger.error("[RecordingCapture] \(diagnostic.description, privacy: .public)")
        }
        onCaptureEvent?(CaptureEvent(
            kind: kind,
            occurredAt: Date(),
            sampleIndex: currentSample,
            diagnostic: diagnostic
        ))
    }

    private func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let destination = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: source.frameLength
        ) else { return nil }
        destination.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }
        for index in sourceBuffers.indices {
            guard
                let sourceData = sourceBuffers[index].mData,
                let destinationData = destinationBuffers[index].mData
            else { return nil }
            let byteCount = Int(sourceBuffers[index].mDataByteSize)
            memcpy(destinationData, sourceData, byteCount)
            destinationBuffers[index].mDataByteSize = sourceBuffers[index].mDataByteSize
        }
        return destination
    }

    private func inputMetrics(_ buffer: AVAudioPCMBuffer) -> AudioInputMetrics? {
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        return AudioInputMetrics.from(
            samples: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        )
    }

    private func sliceBuffer(
        _ source: AVAudioPCMBuffer,
        sourceOffset: Int,
        frameCount: Int
    ) throws -> AVAudioPCMBuffer {
        guard
            let sourceChannel = source.floatChannelData?[0],
            let destination = AVAudioPCMBuffer(
                pcmFormat: source.format,
                frameCapacity: AVAudioFrameCount(frameCount)
            ),
            let destinationChannel = destination.floatChannelData?[0]
        else { throw RecorderError.audioConverterInitializationFailed }
        destination.frameLength = AVAudioFrameCount(frameCount)
        destinationChannel.update(
            from: sourceChannel.advanced(by: sourceOffset),
            count: frameCount
        )
        return destination
    }
}
