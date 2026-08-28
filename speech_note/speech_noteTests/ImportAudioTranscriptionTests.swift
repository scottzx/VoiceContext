import Foundation
import CoreVideo
import Testing
@preconcurrency import AVFoundation
@testable import speech_note

struct ImportAudioTranscriptionTests {
    @Test func processingRangePlannerSplitsLongAudioIntoRecoverableRanges() {
        let samples81s = Int64(16_000) * 81
        let ranges = ProcessingRangePlanner.plan(totalSamples: samples81s)
        #expect(ranges.count == 2)
        #expect(ranges[0].sequence == 0)
        #expect(ranges[0].startSample == 0)
        #expect(ranges[0].endSample == 960_000)
        #expect(ranges[1].sequence == 1)
        #expect(ranges[1].startSample == 960_000)
        #expect(ranges[1].endSample == samples81s)

        let shortSamples = Int64(16_000) * 20
        let short = ProcessingRangePlanner.plan(totalSamples: shortSamples)
        #expect(short.count == 1)
        #expect(short[0].endSample - short[0].startSample == shortSamples)

        let fiveMinuteSamples = Int64(16_000) * 300
        let fiveMinutes = ProcessingRangePlanner.plan(totalSamples: fiveMinuteSamples)
        #expect(fiveMinutes.count == 5)
        #expect(fiveMinutes.last?.endSample == fiveMinuteSamples)
        #expect(ProcessingRangePlanner.plan(totalSamples: 0).isEmpty)
    }

    @Test func importCopyKeepsOriginalAndCreatesPrivateAsset() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let original = root.appendingPathComponent("meeting-source.m4a")
        try writeFixtureAudio(to: original, durationSeconds: 1.5)
        let originalData = try Data(contentsOf: original)

        let destination = root.appendingPathComponent("ImportedAudio/rec/source.m4a")
        let importer = ImportAudioImporter()
        let copied = try importer.copyPrivately(from: original, to: destination)

        #expect(FileManager.default.fileExists(atPath: copied.path))
        #expect(try Data(contentsOf: original) == originalData)
        #expect(try Data(contentsOf: copied) == originalData)
        #expect(copied.path != original.path)
    }

    @Test func importCreatesRecordingRangesAndIdempotentJobs() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let source = root.appendingPathComponent("interview.m4a")
        try writeFixtureAudio(to: source, durationSeconds: 81)

        let repository = try RecordingRepository(rootURL: root)
        #expect(await repository.schemaVersion == 9)

        let importer = ImportAudioImporter()
        let imported = try importer.importAudio(from: source, into: root)
        #expect(imported.recording.origin == .importedAudio)
        #expect(imported.recording.sourceFilename == "interview.m4a")
        #expect(imported.ranges.count == 2)
        #expect(imported.asset.totalSamples == ProcessingRangePlanner.totalSamples(duration: imported.asset.durationSeconds))
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(imported.asset.relativePath).path
        ))
        // Still only one private media file under ImportedAudio.
        let mediaFiles = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("ImportedAudio/\(imported.recording.id.uuidString)"),
            includingPropertiesForKeys: nil
        )
        #expect(mediaFiles.count == 1)

        try await repository.commitImportedAudio(
            recording: imported.recording,
            asset: imported.asset,
            ranges: imported.ranges,
            at: imported.recording.startedAt
        )

        let scheduler = ForegroundTranscriptionScheduler(repository: repository) { _ in }
        for range in imported.ranges {
            try await scheduler.enqueue(
                recordingID: imported.recording.id,
                processingRangeID: range.id,
                onOutcome: { _ in }
            )
        }
        let jobsAfterFirst = try await repository.jobs(recordingID: imported.recording.id)
            .filter { $0.kind == .transcription }
        #expect(jobsAfterFirst.count == 2)
        #expect(jobsAfterFirst.allSatisfy { $0.processingRangeID != nil && $0.chunkID == nil })
        let createdJobIDs = jobsAfterFirst.map(\.id)

        // Idempotent re-enqueue must not create duplicate range jobs.
        for range in imported.ranges {
            try await scheduler.enqueue(
                recordingID: imported.recording.id,
                processingRangeID: range.id,
                onOutcome: { _ in }
            )
        }
        let jobsAfterSecond = try await repository.jobs(recordingID: imported.recording.id)
            .filter { $0.kind == .transcription }
        #expect(Set(jobsAfterSecond.map(\.id)) == Set(createdJobIDs))

        let storedAsset = try await repository.importedAudioAsset(recordingID: imported.recording.id)
        #expect(storedAsset?.id == imported.asset.id)
        let storedRanges = try await repository.processingRanges(recordingID: imported.recording.id)
        #expect(storedRanges.map(\.sequence) == [0, 1])
    }

    @Test func continuationChainWalksMultipleOpenSpeechHops() {
        let recordingID = UUID()
        let assetID = UUID()
        let now = Date()
        func range(
            sequence: Int,
            start: Int64,
            end: Int64,
            requiresContinuation: Bool
        ) -> ProcessingRange {
            ProcessingRange(
                id: UUID(),
                recordingID: recordingID,
                assetID: assetID,
                sequence: sequence,
                startSample: start,
                endSample: end,
                state: .pending,
                requiresContinuation: requiresContinuation,
                createdAt: now,
                updatedAt: now
            )
        }
        let ranges = [
            range(sequence: 0, start: 0, end: 960_000, requiresContinuation: true),
            range(sequence: 1, start: 960_000, end: 1_920_000, requiresContinuation: true),
            range(sequence: 2, start: 1_920_000, end: 2_880_000, requiresContinuation: true),
            range(sequence: 3, start: 2_880_000, end: 3_840_000, requiresContinuation: false),
        ]
        let leading = SampleWindowContinuation.leadingProcessingRanges(
            endingAt: ranges[3],
            among: ranges
        )
        #expect(leading.map(\.sequence) == [0, 1, 2])
        #expect(leading.first?.startSample == 0)

        let onlyImmediate = SampleWindowContinuation.leadingProcessingRanges(
            endingAt: ranges[1],
            among: ranges
        )
        #expect(onlyImmediate.map(\.sequence) == [0])

        let none = SampleWindowContinuation.leadingProcessingRanges(
            endingAt: ranges[0],
            among: ranges
        )
        #expect(none.isEmpty)
    }

    @Test func rangeDecoderReadsWindowWithoutRequiringWholeFileBufferAPI() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("window.m4a")
        try writeFixtureAudio(to: url, durationSeconds: 2.0)

        let samples = try ImportAudioRangeDecoder.samples(
            from: url,
            startSample: 8_000,
            endSample: 16_000
        )
        #expect(samples.count == 8_000)
    }

    @Test func forceStandardizeReplacesPrivateCopyWithSingleAsset() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let source = root.appendingPathComponent("raw-import.m4a")
        try writeFixtureAudio(to: source, durationSeconds: 2.0)

        let importer = ImportAudioImporter()
        let imported = try importer.importAudio(
            from: source,
            into: root,
            forceStandardize: true
        )
        #expect(imported.asset.isStandardized)
        #expect(imported.asset.relativePath.hasSuffix(ImportAudioStandardizer.standardizedFileName))
        let mediaDir = root.appendingPathComponent("ImportedAudio/\(imported.recording.id.uuidString)")
        let mediaFiles = try FileManager.default.contentsOfDirectory(
            at: mediaDir,
            includingPropertiesForKeys: nil
        )
        #expect(mediaFiles.count == 1)
        #expect(ImportAudioStandardizer.supportsRandomAccess(
            at: root.appendingPathComponent(imported.asset.relativePath)
        ))
        #expect(imported.asset.totalSamples > 0)
        #expect(imported.ranges.count == 1)
    }

    @Test func retentionPurgesExpiredImportedAssetButKeepsPinned() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = try RecordingRepository(rootURL: root)
        #expect(await repository.schemaVersion == 9)

        let now = Date(timeIntervalSince1970: 1_785_913_200)
        let expiredStart = now.addingTimeInterval(-8 * 24 * 60 * 60)

        let sourceExpired = root.appendingPathComponent("expired.m4a")
        let sourcePinned = root.appendingPathComponent("pinned.m4a")
        try writeFixtureAudio(to: sourceExpired, durationSeconds: 1.0)
        try writeFixtureAudio(to: sourcePinned, durationSeconds: 1.0)

        let importer = ImportAudioImporter()
        let expiredImport = try importer.importAudio(
            from: sourceExpired,
            into: root,
            now: expiredStart
        )
        var pinnedImport = try importer.importAudio(
            from: sourcePinned,
            into: root,
            now: expiredStart
        )
        pinnedImport = ImportAudioImporter.Result(
            recording: {
                var recording = pinnedImport.recording
                recording.retention.isPinned = true
                return recording
            }(),
            asset: pinnedImport.asset,
            ranges: pinnedImport.ranges
        )

        try await repository.commitImportedAudio(
            recording: expiredImport.recording,
            asset: expiredImport.asset,
            ranges: expiredImport.ranges,
            at: expiredStart
        )
        try await repository.commitImportedAudio(
            recording: pinnedImport.recording,
            asset: pinnedImport.asset,
            ranges: pinnedImport.ranges,
            at: expiredStart
        )

        let expiredURL = root.appendingPathComponent(expiredImport.asset.relativePath)
        let pinnedURL = root.appendingPathComponent(pinnedImport.asset.relativePath)
        #expect(FileManager.default.fileExists(atPath: expiredURL.path))
        #expect(FileManager.default.fileExists(atPath: pinnedURL.path))

        let result = try await repository.purgeExpiredAudio(at: now)
        #expect(result.removedImportedAssetIDs == [expiredImport.asset.id])
        #expect(!FileManager.default.fileExists(atPath: expiredURL.path))
        #expect(FileManager.default.fileExists(atPath: pinnedURL.path))
        let purged = try await repository.importedAudioAsset(recordingID: expiredImport.recording.id)
        #expect(purged?.audioRemovedAt != nil)
        let kept = try await repository.importedAudioAsset(recordingID: pinnedImport.recording.id)
        #expect(kept?.audioRemovedAt == nil)
    }

    @Test func offlineReclusterImportWindowsMatchProcessingRanges() {
        for seconds in [20, 81, 300] {
            let total = Int64(16_000) * Int64(seconds)
            let planned = ProcessingRangePlanner.plan(totalSamples: total)
            let windows = OfflineSpeakerReclusterPass.importWindows(totalSamples: total)
            #expect(windows.count == planned.count)
            #expect(windows.map(\.startSample) == planned.map(\.startSample))
            #expect(windows.map(\.endSample) == planned.map(\.endSample))
            #expect(windows.last?.endSample == total)
        }
        #expect(OfflineSpeakerReclusterPass.importWindows(totalSamples: 0).isEmpty)
    }

    @Test func standardizeHelperRewritesDecodablePrivateAsset() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.m4a")
        try writeFixtureAudio(to: source, durationSeconds: 1.2)
        let destination = root.appendingPathComponent("standardized.m4a")
        _ = try ImportAudioStandardizer.standardize(from: source, to: destination)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(ImportAudioStandardizer.supportsRandomAccess(at: destination))
        let samples = try ImportAudioRangeDecoder.samples(
            from: destination,
            startSample: 0,
            endSample: 8_000
        )
        #expect(samples.count == 8_000)
    }

    @Test func recordingOriginRoundTripsThroughJournal() throws {
        let startedAt = Date(timeIntervalSince1970: 1_785_913_200)
        let recording = Recording(
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(20),
            title: "导入会议",
            state: .processing,
            origin: .importedAudio,
            sourceFilename: "a.m4a",
            sourceUTType: "com.apple.m4a-audio"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        #expect(try decoder.decode(Recording.self, from: encoder.encode(recording)) == recording)

        let legacyMicrophone = Recording(startedAt: startedAt)
        let encoded = try encoder.encode(legacyMicrophone)
        var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        object.removeValue(forKey: "origin")
        object.removeValue(forKey: "sourceFilename")
        object.removeValue(forKey: "sourceUTType")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try decoder.decode(Recording.self, from: legacyData)
        #expect(decoded.origin == .microphone)
    }

    @Test func processingRangePlannerHandlesThirtyMinuteMediaWithoutCap() {
        let samples30min = Int64(16_000) * 30 * 60
        let ranges = ProcessingRangePlanner.plan(totalSamples: samples30min)
        #expect(ranges.count == 30)
        #expect(ranges.first?.startSample == 0)
        #expect(ranges.last?.endSample == samples30min)
        #expect(ranges.map(\.sequence) == Array(0..<30))
    }

    @Test func videoAudioExtractionFeedsImportPipelineWithoutHalfRecording() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let videoURL = root.appendingPathComponent("clip.mov")
        try await writeFixtureVideo(to: videoURL, durationSeconds: 2.0)

        let extracted = root.appendingPathComponent("extracted.m4a")
        var lastProgress = -1.0
        _ = try await ImportVideoAudioExtractor.extractAudioTrack(
            from: videoURL,
            to: extracted,
            progressHandler: { progress in
                lastProgress = progress
            }
        )
        #expect(FileManager.default.fileExists(atPath: extracted.path))
        #expect(lastProgress >= 0)

        let repository = try RecordingRepository(rootURL: root)
        let before = try await repository.recordings()
        #expect(before.isEmpty)

        let imported = try ImportAudioImporter().importAudio(
            from: extracted,
            into: root,
            sourceFilenameOverride: "clip.m4a",
            sourceUTTypeOverride: "public.mpeg-4-audio"
        )
        #expect(imported.recording.origin == .importedAudio)
        #expect(imported.recording.sourceFilename == "clip.m4a")
        #expect(imported.ranges.count == 1)
        #expect(imported.asset.durationSeconds > 1.0)

        try await repository.commitImportedAudio(
            recording: imported.recording,
            asset: imported.asset,
            ranges: imported.ranges,
            at: imported.recording.startedAt
        )
        let after = try await repository.recordings()
        #expect(after.count == 1)
        #expect(after[0].origin == .importedAudio)
    }

    @Test func videoWithoutAudioTrackFailsReadablyAndCreatesNoRecording() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let videoURL = root.appendingPathComponent("silent.mov")
        try await writeFixtureVideo(to: videoURL, durationSeconds: 1.0, includeAudio: false)

        let extracted = root.appendingPathComponent("should-not-exist.m4a")
        do {
            _ = try await ImportVideoAudioExtractor.extractAudioTrack(
                from: videoURL,
                to: extracted
            )
            Issue.record("expected no-audio-track failure")
        } catch let error as ImportVideoAudioExtractor.ExtractError {
            #expect(error == .noAudioTrack)
            #expect(error.errorDescription?.contains("音轨") == true)
        }
        #expect(!FileManager.default.fileExists(atPath: extracted.path))

        let repository = try RecordingRepository(rootURL: root)
        #expect(try await repository.recordings().isEmpty)
    }

    @Test func unsupportedImageExtensionFailsWithoutCreatingPrivateAsset() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("photo.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
        do {
            _ = try ImportAudioImporter().importAudio(from: image, into: root)
            Issue.record("expected unsupported format")
        } catch let error as ImportAudioImporter.ImportError {
            #expect(error == .unsupportedFormat)
        }
        let mediaRoot = root.appendingPathComponent("ImportedAudio")
        #expect(!FileManager.default.fileExists(atPath: mediaRoot.path))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportAudioTests-\(UUID().uuidString)", isDirectory: true)
    }


    /// Builds a short .mov for extractor tests. When `includeAudio` is true the
    /// movie contains a tone track; otherwise it is video-only.
    private func writeFixtureVideo(
        to url: URL,
        durationSeconds: TimeInterval,
        includeAudio: Bool = true
    ) async throws {
        let videoOnly = url.deletingLastPathComponent()
            .appendingPathComponent("video-only-\(UUID().uuidString).mov")
        try await writeVideoOnlyMovie(to: videoOnly, durationSeconds: durationSeconds)
        defer { try? FileManager.default.removeItem(at: videoOnly) }

        guard includeAudio else {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.copyItem(at: videoOnly, to: url)
            return
        }

        let audioURL = url.deletingLastPathComponent()
            .appendingPathComponent("tone-\(UUID().uuidString).m4a")
        try writeFixtureAudio(to: audioURL, durationSeconds: durationSeconds)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: videoOnly)
        let audioAsset = AVURLAsset(url: audioURL)
        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        guard let sourceVideo = videoTracks.first, let sourceAudio = audioTracks.first else {
            throw NSError(domain: "ImportVideoFixture", code: 1)
        }
        let videoDuration = try await videoAsset.load(.duration)
        let audioDuration = try await audioAsset.load(.duration)
        let duration = CMTimeMinimum(videoDuration, audioDuration)

        let compositionVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )!
        try compositionVideo.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration),
            of: sourceVideo,
            at: .zero
        )
        let compositionAudio = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )!
        try compositionAudio.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration),
            of: sourceAudio,
            at: .zero
        )

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        guard let session = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw NSError(domain: "ImportVideoFixture", code: 2)
        }
        session.outputURL = url
        session.outputFileType = .mov
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        guard session.status == .completed else {
            throw session.error ?? NSError(domain: "ImportVideoFixture", code: 3)
        }
    }

    private func writeVideoOnlyMovie(to url: URL, durationSeconds: TimeInterval) async throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 160,
            AVVideoHeightKey: 120,
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: 160,
                kCVPixelBufferHeightKey as String: 120,
            ]
        )
        guard writer.canAdd(videoInput) else {
            throw NSError(domain: "ImportVideoFixture", code: 4)
        }
        writer.add(videoInput)
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "ImportVideoFixture", code: 5)
        }
        writer.startSession(atSourceTime: .zero)

        var pixelBuffer: CVPixelBuffer?
        let createStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            160,
            120,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ] as CFDictionary,
            &pixelBuffer
        )
        guard createStatus == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw NSError(domain: "ImportVideoFixture", code: 6)
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 32, CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        let frameCount = max(1, Int((durationSeconds * 10).rounded(.up)))
        let frameDuration = CMTime(value: 1, timescale: 10)
        for index in 0..<frameCount {
            while !videoInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            let pts = CMTimeMultiply(frameDuration, multiplier: Int32(index))
            guard adaptor.append(buffer, withPresentationTime: pts) else {
                throw writer.error ?? NSError(domain: "ImportVideoFixture", code: 7)
            }
        }
        videoInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "ImportVideoFixture", code: 8)
        }
    }

    private func writeFixtureAudio(to url: URL, durationSeconds: TimeInterval) throws {
        let sampleRate = AACSegmentRecorder.targetSampleRate
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frameCapacity: AVAudioFrameCount = 4_096
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity)!
        var remaining = Int(durationSeconds * sampleRate)
        var phase = 0
        while remaining > 0 {
            let frames = min(remaining, Int(frameCapacity))
            buffer.frameLength = AVAudioFrameCount(frames)
            let channel = buffer.floatChannelData![0]
            for index in 0..<frames {
                let value = sin(Double(phase + index) * 2 * Double.pi * 440 / sampleRate)
                channel[index] = Float(value * 0.2)
            }
            try file.write(from: buffer)
            phase += frames
            remaining -= frames
        }
    }
}
