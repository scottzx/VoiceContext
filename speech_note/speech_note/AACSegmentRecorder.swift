@preconcurrency import AVFoundation
import Foundation

nonisolated final class AACSegmentRecorder: @unchecked Sendable {
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
    private var segmentDurationSamples: Int64 = 5 * 60 * 16_000
    private var boundaryPlanner = AACChunkBoundaryPlanner(segmentLengthSamples: 5 * 60 * 16_000)
    private var writtenSamples: Int64 = 0
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
        statusLock.withLock { writtenSamples }
    }

    func start(in directory: URL, segmentDuration: TimeInterval = 5 * 60) async throws {
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
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw RecorderError.audioConverterInitializationFailed
        }

        try writerQueue.sync {
            self.directory = directory
            segmentDurationSamples = max(1, Int64(segmentDuration * targetFormat.sampleRate))
            boundaryPlanner = AACChunkBoundaryPlanner(segmentLengthSamples: segmentDurationSamples)
            audioConverter = converter
            recordingFormat = targetFormat
            writtenSamples = 0
            pendingPacketCount = 0
            lastClosedSegment = nil
            try openNextSegment(startedAt: Date())
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
            let segment = closeSegment(at: Date()) ?? lastClosedSegment
            guard let segment else { throw RecorderError.notRecording }
            audioConverter = nil
            recordingFormat = nil
            return segment
        }
        try session.setActive(false, options: .notifyOthersOnDeactivation)
        return segment
    }

    func pause() throws {
        guard statusLock.withLock({ tapInstalled }) else { throw RecorderError.notRecording }
        engine.pause()
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
        do {
            if let metrics = inputMetrics(inputBuffer) {
                onMeteringUpdate?(metrics)
            }
            guard let converted = try convertForRecording(inputBuffer), converted.frameLength > 0 else {
                return
            }
            for slice in boundaryPlanner.slices(for: Int64(converted.frameLength)) {
                if activeFile == nil {
                    try openNextSegment(startedAt: Date())
                }
                let buffer = try sliceBuffer(
                    converted,
                    sourceOffset: Int(slice.sourceOffset),
                    frameCount: Int(slice.frameCount)
                )
                try activeFile?.write(from: buffer)
                statusLock.withLock { writtenSamples = slice.endSample }
                if slice.closesSegment {
                    _ = closeSegment(at: Date())
                }
            }
        } catch {
            emit(.writeFailed)
        }
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

    private func openNextSegment(startedAt: Date) throws {
        guard let directory, let recordingFormat else {
            throw RecorderError.audioConverterInitializationFailed
        }
        let id = UUID()
        let url = directory.appendingPathComponent("audio-\(id.uuidString.lowercased()).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
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
        activeStartSample = currentSample
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
            endSample: currentSample,
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
