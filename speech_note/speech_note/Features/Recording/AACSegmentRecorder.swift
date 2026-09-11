@preconcurrency import AVFoundation
import Foundation

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

        var errorDescription: String? {
            switch self {
            case .microphonePermissionDenied: "未获得麦克风权限。"
            case .noInputFormat: "当前音频路由没有可用输入格式。"
            case .audioConverterInitializationFailed: "无法将麦克风输入转换为 16 kHz 录音。"
            case .notRecording: "录音尚未开始。"
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
        }

        let kind: Kind
        let occurredAt: Date
        let sampleIndex: Int64
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
    private let session = AVAudioSession.sharedInstance()
    private let writerQueue = DispatchQueue(label: "VoiceContext.AACSegmentWriter", qos: .userInitiated)
    private let statusLock = NSLock()
    private var activeFile: AVAudioFile?
    private var activeID: UUID?
    private var activeURL: URL?
    private var activeStartedAt: Date?
    private var activeStartSample: Int64 = 0
    private var audioConverter: AVAudioConverter?
    private var recordingFormat: AVAudioFormat?
    private var directory: URL?
    private var pendingPacketCount = 0
    private var tapInstalled = false
    private var lastClosedSegment: Segment?
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?

    private let maximumPendingPackets = 256

    deinit {
        interruptionObserver.map(NotificationCenter.default.removeObserver)
        routeChangeObserver.map(NotificationCenter.default.removeObserver)
    }

    var currentSample: Int64 {
        statusLock.withLock { masterSampleCursor }
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
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)

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
            statusLock.withLock { masterSampleCursor = initialSampleOffset }
            pendingPacketCount = 0
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
        statusLock.withLock { tapInstalled = true }
        observeAudioSession()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            statusLock.withLock { tapInstalled = false }
            _ = writerQueue.sync { closeSegment(at: Date()) }
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
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

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
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
        try session.setActive(false, options: .notifyOthersOnDeactivation)
        return segment
    }

    func cancel() {
        let wasRecording = statusLock.withLock { () -> Bool in
            guard tapInstalled else { return false }
            tapInstalled = false
            return true
        }
        guard wasRecording else { return }

        engine.inputNode.removeTap(onBus: 0)
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
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    func pause() throws {
        guard statusLock.withLock({ tapInstalled }) else { throw RecorderError.notRecording }
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
        try session.setActive(true)
        try engine.start()
    }

    private func bufferFromAudioCallback(_ buffer: AVAudioPCMBuffer) {
        guard let packet = copy(buffer) else {
            emit(.writeFailed)
            return
        }
        let accepted = statusLock.withLock { () -> Bool in
            guard pendingPacketCount < maximumPendingPackets else { return false }
            pendingPacketCount += 1
            return true
        }
        guard accepted else {
            emit(.writerBackpressure)
            return
        }

        writerQueue.async { [weak self] in
            defer { self?.statusLock.withLock { self?.pendingPacketCount -= 1 } }
            self?.consume(packet)
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

            if let metrics = AudioInputMetrics.from(samples: samples.withUnsafeBufferPointer { $0 }) {
                onMeteringUpdate?(metrics)
            }

            let metrics = AudioInputMetrics.from(samples: samples)
            let isCurrentVoiced = metrics.rmsDecibels >= silenceThresholdDB

            let bufferStartSample = statusLock.withLock { masterSampleCursor }
            let bufferEndSample = bufferStartSample + Int64(frameCount)
            statusLock.withLock { masterSampleCursor = bufferEndSample }

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
            emit(.writeFailed)
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

    private func closeSegment(at endedAt: Date) -> Segment? {
        guard
            let id = activeID,
            let url = activeURL,
            let startedAt = activeStartedAt
        else { return nil }
        activeFile = nil
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
    }

    private func handleInterruption(_ notification: Notification) {
        guard
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }
        switch type {
        case .began:
            emit(.interruptionBegan)
        case .ended:
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
            if shouldResume, statusLock.withLock({ tapInstalled }) {
                try? session.setActive(true)
                try? engine.start()
            }
            emit(.interruptionEnded(shouldResume: shouldResume))
        @unknown default:
            break
        }
    }

    private func emit(_ kind: CaptureEvent.Kind) {
        onCaptureEvent?(CaptureEvent(
            kind: kind,
            occurredAt: Date(),
            sampleIndex: currentSample
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
