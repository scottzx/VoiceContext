@preconcurrency import AVFoundation
import Foundation

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure(description: message) }
}

@main struct RecordingDiskRecoveryChecks {
    @MainActor static func main() async {
        do {
            try await preservesIndexedMetadata()
            try await salvagesOnlyUnknownAudio()
            try await ordersUnknownFilesByCreationDate()
            try await leavesLifecycleToRecovery()
            try await leavesUnreadableFilesForDiagnostics()
            print("PASS: disk recovery preserves indexed timing, salvages readable tails, and is idempotent")
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }

    static func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recording-disk-recovery-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func audioURL(root: URL, recordingID: UUID, chunkID: UUID, minute: String = "00/00") -> URL {
        root.appendingPathComponent("Recordings/\(recordingID.uuidString.lowercased())/audio/\(minute)/audio-\(chunkID.uuidString.lowercased()).m4a")
    }

    static func writeAudio(_ url: URL, createdAt: Date, sampleRate: Double = 16_000) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate))!
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][frame] = 0 }
        do {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        try FileManager.default.setAttributes([.creationDate: createdAt, .modificationDate: createdAt.addingTimeInterval(1)], ofItemAtPath: url.path)
    }

    static func relativePath(_ url: URL, root: URL) -> String {
        String(url.path.dropFirst(root.path.count + 1))
    }

    static func preservesIndexedMetadata() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let start = Date(timeIntervalSince1970: 1_792_000_000)
        let recording = Recording(startedAt: start, state: .recording)
        try await repository.createRecording(recording, at: start)
        let firstID = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let firstURL = audioURL(root: root, recordingID: recording.id, chunkID: firstID)
        let secondURL = audioURL(root: root, recordingID: recording.id, chunkID: secondID)
        try writeAudio(firstURL, createdAt: start)
        try writeAudio(secondURL, createdAt: start.addingTimeInterval(30))
        let first = AudioChunk(id: firstID, recordingID: recording.id,
            relativePath: relativePath(firstURL, root: root), startSample: 9_600, endSample: 25_600,
            startedAt: start.addingTimeInterval(4), endedAt: start.addingTimeInterval(5),
            isPinned: true, requiresContinuation: true)
        let second = AudioChunk(id: secondID, recordingID: recording.id,
            relativePath: relativePath(secondURL, root: root), startSample: 480_000, endSample: 496_000,
            startedAt: start.addingTimeInterval(40), endedAt: start.addingTimeInterval(41),
            state: .audioRemoved, audioRemovedAt: start.addingTimeInterval(60))
        try await repository.addChunk(first, at: first.endedAt)
        try await repository.addChunk(second, at: second.endedAt)
        let events = await repository.appliedEventCount
        let restored = try await repository.reconcileChunksFromDisk(recordingID: recording.id)
        try check(restored.isEmpty, "Already indexed chunks must not be reported as recovered")
        let indexed = try await repository.chunks(recordingID: recording.id).sorted { $0.startSample < $1.startSample }
        try check(indexed == [first, second], "VAD gaps, sample order, wall clock, retention and continuation must survive reconciliation")
        try check(try await repository.recording(id: recording.id) == recording, "Disk scanning must not end or transition active capture")
        try check(await repository.appliedEventCount == events, "Scanning known chunks must append no journal events")
    }

    static func salvagesOnlyUnknownAudio() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let start = Date(timeIntervalSince1970: 1_792_000_000)
        let recording = Recording(startedAt: start, state: .recording)
        try await repository.createRecording(recording, at: start)
        // The latest durable chunk is absent on disk; its sample bounds still anchor recovery.
        let known = AudioChunk(recordingID: recording.id, relativePath: "retained-index-only.m4a",
            startSample: 1_000_000, endSample: 1_016_000,
            startedAt: start.addingTimeInterval(120), endedAt: start.addingTimeInterval(121), isPinned: true)
        try await repository.addChunk(known, at: known.endedAt)
        let tailID = UUID()
        let tailURL = audioURL(root: root, recordingID: recording.id, chunkID: tailID)
        try writeAudio(tailURL, createdAt: start.addingTimeInterval(500), sampleRate: 48_000)
        let fileDate = try tailURL.resourceValues(forKeys: [.creationDateKey]).creationDate!
        let audio = try AVAudioFile(forReading: tailURL)
        let frames = Int64((Double(audio.length) / audio.processingFormat.sampleRate * 16_000).rounded())
        let added = try await repository.reconcileChunksFromDisk(recordingID: recording.id)
        try check(added.count == 1 && added[0].id == tailID, "Recover only the unindexed readable tail")
        try check(added[0].startSample == known.endSample && added[0].endSample == known.endSample + frames,
            "Tail recovery must not overlap any durable sample range and must normalize decoded duration")
        try check(added[0].startedAt == fileDate, "Use the observed file date, not recording start plus guessed samples")
        try check(abs(added[0].endedAt.timeIntervalSince(fileDate) - Double(frames) / 16_000) < 0.001,
            "Recovered wall-clock duration must match readable media")
        let gaps = try await repository.gaps(recordingID: recording.id)
        try check(gaps.count == 1 && gaps[0].id == tailID && gaps[0].reason == .recoveredAfterTermination,
            "Approximate tail timing must carry a durable recovery marker")
        let beforeRepeat = try Data(contentsOf: root.appendingPathComponent("recording-journal.jsonl"))
        try check(try await repository.reconcileChunksFromDisk(recordingID: recording.id).isEmpty,
            "Repeated scanning must not recover the tail twice")
        try check(try Data(contentsOf: root.appendingPathComponent("recording-journal.jsonl")) == beforeRepeat,
            "Repeated reconciliation must not append duplicate chunks or recovery gaps")
        let all = try await repository.chunks(recordingID: recording.id)
        try check(all.first { $0.id == known.id } == known, "A missing media file must not rewrite its durable metadata")
    }

    static func ordersUnknownFilesByCreationDate() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let start = Date(timeIntervalSince1970: 1_792_000_000)
        let recording = Recording(startedAt: start, state: .paused)
        try await repository.createRecording(recording, at: start)
        let earlier = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        let later = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        try writeAudio(audioURL(root: root, recordingID: recording.id, chunkID: earlier), createdAt: start)
        try writeAudio(audioURL(root: root, recordingID: recording.id, chunkID: later), createdAt: start.addingTimeInterval(10))
        let added = try await repository.reconcileChunksFromDisk(recordingID: recording.id)
        try check(added.map(\.id) == [earlier, later], "Same-minute unknown audio must follow creation dates, not random UUID order")
        try check(try await repository.recording(id: recording.id) == recording, "Salvaging audio must preserve paused capture state")
    }

    static func leavesLifecycleToRecovery() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let start = Date(timeIntervalSince1970: 1_792_000_000)
        let recording = Recording(startedAt: start, state: .recording)
        try await repository.createRecording(recording, at: start)
        try writeAudio(audioURL(root: root, recordingID: recording.id, chunkID: UUID()), createdAt: start)
        _ = try await repository.reconcileAllRecordingsFromDisk()
        let recovery = try await repository.recoverUnfinished(at: start.addingTimeInterval(60))
        try check(recovery.interruptedRecordingIDs == [recording.id], "Disk reconciliation must leave unfinished capture discoverable")
        try check(try await repository.recording(id: recording.id)?.state == .interrupted,
            "The termination recovery state machine must own the interrupted transition")
        let beforeRepeat = await repository.appliedEventCount
        _ = try await repository.recoverUnfinished(at: start.addingTimeInterval(120))
        try check(await repository.appliedEventCount == beforeRepeat, "Repeated recovery must not add interruption events")
    }

    static func leavesUnreadableFilesForDiagnostics() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(rootURL: root)
        let recording = Recording(startedAt: Date(), state: .recording)
        try await repository.createRecording(recording, at: recording.startedAt)
        let url = audioURL(root: root, recordingID: recording.id, chunkID: UUID())
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data(repeating: 0x55, count: 4_000)
        try bytes.write(to: url)
        try check(try await repository.reconcileChunksFromDisk(recordingID: recording.id).isEmpty,
            "Unreadable AAC must not become a fabricated sample range based on compressed byte count")
        try check(try Data(contentsOf: url) == bytes, "Unreadable orphan media must remain available for diagnostics or later repair")
    }
}
