import AVFoundation
import Foundation

@main
struct TranscriptProtectionChecks {
    static func main() async throws {
        if CommandLine.arguments.contains("--legacy-only") {
            try await TranscriptLegacyCompatibilityChecks.run()
            return
        }
        try protectsEditsAndStableIDs()
        try protectsEmptyAndUnrelatedSources()
        try protectsPartialResults()
        try protectsImportedSiblingRanges()
        try await protectsEditsFromLateASR()
        try await protectsUserSaveAfterASR()
        try await preflightsAudioAndKeepsUnavailableAttemptsVisible()
        try await registersEntireReadableQueueBeforeDraining()
        try await finalizationUsesLatestAndPreservesLegitimateEmptyCreation()
        try await TranscriptLegacyCompatibilityChecks.run()
        print("Transcript protection host checks passed (10 groups, including legacy compatibility).")
    }

    static let startedAt = Date(timeIntervalSince1970: 1_788_000_000)

    static func recording() -> Recording {
        Recording(startedAt: startedAt, endedAt: startedAt.addingTimeInterval(3),
                  speakerProcessingEnabled: false, state: .complete)
    }

    static func chunk(_ recording: Recording, _ index: Int, path: String? = nil) -> AudioChunk {
        AudioChunk(recordingID: recording.id, relativePath: path ?? "\(index).wav",
                   startSample: Int64(index * 16_000), endSample: Int64((index + 1) * 16_000),
                   startedAt: startedAt.addingTimeInterval(Double(index)),
                   endedAt: startedAt.addingTimeInterval(Double(index + 1)))
    }

    static func protectsEditsAndStableIDs() throws {
        let recording = recording()
        let chunk = chunk(recording, 0)
        var original = TranscriptDocumentV1(recording: recording, chunks: [chunk],
                                            segmentTexts: [(chunk.id, "初稿")])
        let old = original.segments[0]
        let importedID = UUID()
        original.segments[0] = .init(id: importedID, sequence: old.sequence, startedAt: old.startedAt,
                                    offsetMilliseconds: old.offsetMilliseconds, text: old.text,
                                    startSample: old.startSample, endSample: old.endSample,
                                    sourceRanges: old.sourceRanges, speechSpanIDs: old.speechSpanIDs)
        let edited = original.applyingUserEdits(title: "校对标题", tags: ["周会"],
                                                segmentTexts: [importedID: "人工校对"])
        let draft = TranscriptDocumentV1.SegmentDraft(text: "迟到识别", chunk: chunk)
        for result in [edited.appending(recording: recording, chunks: [chunk], draft: draft),
                       edited.appending(recording: recording, chunks: [chunk], drafts: [draft, draft],
                                        replacingSourceIDs: [chunk.id])] {
            precondition(result == edited, "Protected text must not acquire a duplicate ASR segment")
            precondition(result.segments[0].id == importedID)
            precondition(result.segments[0].editedAt == edited.segments[0].editedAt)
        }
        let prepared = edited.preparingForRetranscription()
        precondition(prepared.segments == edited.segments && prepared.tags == edited.tags)
        let replaced = original.appending(recording: recording, chunks: [chunk], draft: draft)
        precondition(replaced.segments[0].id == importedID, "Exactly mapped legacy IDs must remain stable")
        let point = TranscriptDocumentV1.SegmentDraft(
            text: "旧版零长度段", startSample: 0, endSample: 0,
            sourceRanges: [.init(sourceID: chunk.id, startSample: 0, endSample: 0)]
        )
        let legacy = TranscriptDocumentV1(recording: recording, chunks: [chunk], segmentDrafts: [point])
        precondition(legacy.appending(recording: recording, chunks: [chunk], draft: draft).segments.count == 1)
        let editedPoint = legacy.applyingUserEdits(title: nil, tags: [], segmentTexts: [legacy.segments[0].id: "零长度人工段"])
        precondition(editedPoint.appending(recording: recording, chunks: [chunk], draft: draft) == editedPoint)
    }

    static func protectsEmptyAndUnrelatedSources() throws {
        let recording = recording()
        let chunks = [chunk(recording, 0), chunk(recording, 1)]
        let original = TranscriptDocumentV1(recording: recording, chunks: chunks,
                                            segmentTexts: [(chunks[0].id, "保留"), (chunks[1].id, "无关成功段")])
        precondition(original.appending(recording: recording, chunks: chunks,
                                       draft: .init(text: " \n", chunk: chunks[0]),
                                       replacingSourceIDs: [chunks[0].id]) == original)
        precondition(original.appending(recording: recording, chunks: chunks,
                                       drafts: [.init(text: "", chunk: chunks[0])],
                                       replacingSourceIDs: chunks.map(\.id)) == original)
        let retried = original.appending(recording: recording, chunks: chunks,
                                         drafts: [.init(text: "重试成功", chunk: chunks[0])],
                                         replacingSourceIDs: [chunks[0].id])
        precondition(retried.segments[1] == original.segments[1])
        precondition(retried.segments[0].id == original.segments[0].id)
        let duplicate = original.appending(recording: recording, chunks: chunks,
                                           drafts: [.init(text: "新文本", chunk: chunks[0]),
                                                    .init(text: "同一范围重复", chunk: chunks[0])],
                                           replacingSourceIDs: [chunks[0].id])
        precondition(Set(duplicate.segments.map(\.id)).count == duplicate.segments.count)
    }

    static func protectsPartialResults() throws {
        let recording = recording()
        let chunks = [chunk(recording, 0), chunk(recording, 1), chunk(recording, 2)]
        let original = TranscriptDocumentV1(recording: recording, chunks: chunks,
                                            segmentTexts: chunks.map { ($0.id, "旧稿 \($0.startSample)") })
        let edited = original.applyingUserEdits(title: "人工标题", tags: ["保留"],
                                                segmentTexts: [original.segments[2].id: "校对第三段"])
        let result = edited.appending(recording: recording, chunks: chunks, drafts: [
            .init(text: "第一段成功", chunk: chunks[0]), .init(text: "", chunk: chunks[1]),
            .init(text: "不得覆盖第三段", chunk: chunks[2]),
        ], replacingSourceIDs: chunks.map(\.id))
        precondition(result.segments[0].text == "第一段成功")
        precondition(result.segments[1] == edited.segments[1])
        precondition(result.segments[2] == edited.segments[2])
        precondition(result.title == edited.title && result.tags == edited.tags)
    }

    static func protectsImportedSiblingRanges() throws {
        let recording = recording()
        let sourceID = UUID()
        func draft(_ text: String, _ index: Int) -> TranscriptDocumentV1.SegmentDraft {
            .init(text: text, sourceRanges: [.init(sourceKind: .importedAsset, sourceID: sourceID,
                                                  startSample: Int64(index * 16_000),
                                                  endSample: Int64((index + 1) * 16_000))])
        }
        let original = TranscriptDocumentV1(recording: recording, audioAvailableOnThisDevice: true,
                                            segmentDrafts: [draft("前段", 0), draft("后段", 1)])
        let retried = original.appendingImported(recording: recording, audioAvailableOnThisDevice: true,
                                                 drafts: [draft("前段重试", 0)])
        precondition(retried.segments[1] == original.segments[1])
        precondition(retried.appendingImported(recording: recording, audioAvailableOnThisDevice: true,
                                              draft: draft(" \n", 0)) == retried)
        let edited = retried.applyingUserEdits(title: nil, tags: [],
                                              segmentTexts: [retried.segments[0].id: "人工导入校对"])
        precondition(edited.appendingImported(recording: recording, audioAvailableOnThisDevice: true,
                                              drafts: [draft("迟到导入识别", 0)]) == edited)
        let spanning = TranscriptDocumentV1(recording: recording, audioAvailableOnThisDevice: true,
                                             segmentDrafts: [.init(text: "跨来源范围旧稿", sourceRanges: [
                                                .init(sourceKind: .importedAsset, sourceID: sourceID,
                                                      startSample: 0, endSample: 960_000)
                                             ])])
        let narrower = TranscriptDocumentV1.SegmentDraft(text: "范围内新结果", sourceRanges: [
            .init(sourceKind: .importedAsset, sourceID: sourceID, startSample: 640_000, endSample: 800_000)
        ])
        precondition(spanning.appendingImported(recording: recording, audioAvailableOnThisDevice: true,
                                                 drafts: [narrower], replacingSampleRange: 480_000..<960_000) == spanning)
    }

    static func protectsEditsFromLateASR() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = recording()
        let chunk = chunk(recording, 0)
        let store = try TranscriptDocumentStore(rootURL: root)
        let initial = TranscriptDocumentV1(recording: recording, chunks: [chunk], segmentTexts: [(chunk.id, "旧稿")])
        try await store.write(initial)
        let gate = Gate()
        let delayedASR = Task {
            await gate.wait()
            return try await store.update(recordingID: recording.id) { latest in
                latest?.appending(recording: recording, chunks: [chunk],
                                   drafts: [.init(text: "晚到 ASR", chunk: chunk)], replacingSourceIDs: [chunk.id])
            }
        }
        let edited = initial.applyingUserEdits(title: "新标题", tags: ["新标签"],
                                               segmentTexts: [initial.segments[0].id: "保存的人工文字"])
        try await store.write(edited)
        let saved = try await store.document(recordingID: recording.id)
        await gate.open()
        let result = try await delayedASR.value
        precondition(result == saved)
        let loaded = try await store.document(recordingID: recording.id)
        precondition(loaded == saved)
        let markdown = try await store.markdown(recordingID: recording.id)
        precondition(markdown?.contains("保存的人工文字") == true)
        precondition(markdown?.contains("晚到 ASR") == false)
    }

    static func preflightsAudioAndKeepsUnavailableAttemptsVisible() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = recording()
        let valid = chunk(recording, 0, path: "valid.wav")
        let broken = chunk(recording, 1, path: "broken.wav")
        let missing = chunk(recording, 2, path: "missing.wav")
        try writeAudio(root.appendingPathComponent(valid.relativePath))
        try Data("exists but cannot decode".utf8).write(to: root.appendingPathComponent(broken.relativePath))
        let plan = TranscriptionRetryPreflight.evaluate(chunks: [valid, broken, missing], ranges: [],
                                                        asset: nil, rootURL: root)
        precondition(plan.chunks == [valid] && plan.unavailableSourceCount == 2)
        var expired = chunk(recording, 3, path: "valid.wav")
        expired.state = .audioRemoved
        expired.audioRemovedAt = startedAt
        let partialExpired = TranscriptionRetryPreflight.evaluate(chunks: [valid, expired], ranges: [], asset: nil, rootURL: root)
        precondition(partialExpired.chunks == [valid] && partialExpired.unavailableSourceCount == 1)
        precondition(!TranscriptionRetryPreflight.evaluate(chunks: [broken, missing], ranges: [],
                                                         asset: nil, rootURL: root).hasReadableAudio)
        let asset = ImportedAudioAsset(recordingID: recording.id, relativePath: "valid.wav", sourceFilename: "valid.wav",
                                       sourceUTType: "public.wav", durationSeconds: 1, totalSamples: 16_000, importedAt: startedAt)
        let ranges = [ProcessingRange(recordingID: recording.id, assetID: asset.id, sequence: 0,
                                      startSample: 0, endSample: 16_000, createdAt: startedAt),
                      ProcessingRange(recordingID: recording.id, assetID: asset.id, sequence: 1,
                                      startSample: 32_000, endSample: 48_000, createdAt: startedAt)]
        let importedPlan = TranscriptionRetryPreflight.evaluate(chunks: [], ranges: ranges, asset: asset, rootURL: root)
        precondition(importedPlan.ranges == [ranges[0]] && importedPlan.unavailableSourceCount == 1)
        var removed = asset
        removed.audioRemovedAt = startedAt
        precondition(!TranscriptionRetryPreflight.evaluate(chunks: [], ranges: ranges, asset: removed, rootURL: root).hasReadableAudio)
        for sampleRate in [16_000.0, 48_000.0] {
            let path = "truncated-\(Int(sampleRate)).wav"
            try writeAudio(root.appendingPathComponent(path), duration: 10, sampleRate: sampleRate)
            let truncated = ImportedAudioAsset(recordingID: recording.id, relativePath: path, sourceFilename: path,
                                               sourceUTType: "public.wav", durationSeconds: 60, totalSamples: 960_000,
                                               importedAt: startedAt)
            let truncatedRange = ProcessingRange(recordingID: recording.id, assetID: truncated.id, sequence: 0,
                                                 startSample: 0, endSample: 960_000, createdAt: startedAt)
            precondition(!TranscriptionRetryPreflight.evaluate(chunks: [], ranges: [truncatedRange],
                                                              asset: truncated, rootURL: root).hasReadableAudio)
            let truncatedChunk = AudioChunk(recordingID: recording.id, relativePath: path, startSample: 0,
                                            endSample: 960_000, startedAt: startedAt,
                                            endedAt: startedAt.addingTimeInterval(60))
            precondition(!TranscriptionRetryPreflight.evaluate(chunks: [truncatedChunk], ranges: [],
                                                              asset: nil, rootURL: root).hasReadableAudio)
        }

        let repository = try RecordingRepository(rootURL: root)
        try await repository.createRecording(recording, at: startedAt)
        for chunk in [valid, broken, missing] { try await repository.addChunk(chunk, at: startedAt) }
        let legacy = RecordingJob(recordingID: recording.id, kind: .transcription, state: .completed,
                                  attemptCount: 1, lastError: nil, createdAt: startedAt, updatedAt: startedAt)
        let validJob = RecordingJob(recordingID: recording.id, chunkID: valid.id, kind: .transcription, state: .completed,
                                    attemptCount: 1, lastError: nil, createdAt: startedAt, updatedAt: startedAt)
        try await repository.upsertJob(legacy, at: startedAt)
        try await repository.upsertJob(validJob, at: startedAt)
        try await repository.resetTranscriptionForRetranscription(recordingID: recording.id,
                                                                  readableChunkIDs: Set(plan.chunks.map(\.id)),
                                                                  readableRangeIDs: [], at: startedAt)
        let jobs = try await repository.jobs(recordingID: recording.id)
        precondition(jobs.first { $0.chunkID == valid.id }?.state == .pending)
        precondition(jobs.filter { $0.terminationReason == "retranscriptionAudioUnavailable" }.count == 2)
        precondition(jobs.filter { $0.state == .pending }.count == 1)
        let store = try TranscriptDocumentStore(rootURL: root)
        let old = TranscriptDocumentV1(recording: recording, chunks: [valid, broken],
                                       segmentTexts: [(valid.id, "成功旧稿"), (broken.id, "不可读范围旧稿")])
        try await store.write(old)
        try await repository.upsertJob(validJob, at: startedAt)
        let outcome = try await CompletionReconciler(repository: repository, transcriptStore: store)
            .reconcile(recordingID: recording.id)
        precondition(outcome == .needsAttention, "Unavailable retry must not heal into a completed retry")
        let preserved = try await store.document(recordingID: recording.id)
        precondition(preserved == old)
    }

    static func protectsUserSaveAfterASR() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = recording()
        let chunks = [chunk(recording, 0), chunk(recording, 1)]
        let store = try TranscriptDocumentStore(rootURL: root)
        let initial = TranscriptDocumentV1(recording: recording, chunks: chunks, segmentTexts: [(chunks[0].id, "待校对")])
        try await store.write(initial)
        let staleEditorRead = try await store.document(recordingID: recording.id)!
        let asr = try await store.update(recordingID: recording.id) {
            $0?.appending(recording: recording, chunks: chunks,
                          drafts: [.init(text: "编辑期间追加的新段", chunk: chunks[1])], replacingSourceIDs: [chunks[1].id])
        }!
        let result = try await store.update(recordingID: recording.id) {
            guard let latest = $0 else { return nil }
            try latest.requireEditableSegments([staleEditorRead.segments[0].id])
            return latest.applyingUserEdits(title: "用户保存的标题", tags: ["校对"],
                                           segmentTexts: [staleEditorRead.segments[0].id: "保存的校对"])
        }!
        precondition(result.revision == asr.revision + 1)
        precondition(result.segments.map(\.text) == ["保存的校对", "编辑期间追加的新段"])
        precondition(result.segments[1] == asr.segments[1])
        let resegmented = try await store.update(recordingID: recording.id) { latest in
            var latest = latest!
            latest.segments.removeFirst()
            return latest
        }!
        do {
            try await store.update(recordingID: recording.id) { latest in
                guard let latest else { return nil }
                try latest.requireEditableSegments([staleEditorRead.segments[0].id])
                return latest.applyingUserEdits(title: nil, tags: [],
                                               segmentTexts: [staleEditorRead.segments[0].id: "不能静默丢弃"])
            }
            preconditionFailure("Saving a missing source segment must report a conflict")
        } catch TranscriptDocumentV1.DocumentError.sourceUpdated {}
        let afterConflict = try await store.document(recordingID: recording.id)!
        precondition(afterConflict == resegmented)
    }

    static func registersEntireReadableQueueBeforeDraining() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = recording()
        let chunks = [chunk(recording, 0), chunk(recording, 1)]
        let repository = try RecordingRepository(rootURL: root)
        try await repository.createRecording(recording, at: startedAt)
        for chunk in chunks { try await repository.addChunk(chunk, at: startedAt) }
        try await repository.resetTranscriptionForRetranscription(recordingID: recording.id,
                                                                  readableChunkIDs: Set(chunks.map(\.id)),
                                                                  readableRangeIDs: [], at: startedAt)
        let pending = try await repository.jobs(recordingID: recording.id)
        precondition(pending.count == 2 && pending.allSatisfy { $0.state == .pending })
        let outcomes = Outcomes()
        let scheduler = ForegroundTranscriptionScheduler(repository: repository) { _ in
            let registered = try await repository.jobs(recordingID: recording.id)
            precondition(registered.count == 2, "Every source must exist before the first execution")
        }
        try await scheduler.resumePreparedRetranscription(recordingID: recording.id) { await outcomes.add($0) }
        await scheduler.waitForIdle()
        let delivered = await outcomes.values
        precondition(delivered.count == 2)
        let completed = try await repository.jobs(recordingID: recording.id)
        precondition(completed.allSatisfy { $0.state == .completed })
    }

    static func finalizationUsesLatestAndPreservesLegitimateEmptyCreation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = recording()
        let chunk = chunk(recording, 0)
        let repository = try RecordingRepository(rootURL: root)
        try await repository.createRecording(recording, at: startedAt)
        let store = try TranscriptDocumentStore(rootURL: root)
        let original = TranscriptDocumentV1(recording: recording, chunks: [chunk], segmentTexts: [(chunk.id, "原稿")])
        try await store.write(original)
        let edited = original.applyingUserEdits(title: "校对标题", tags: ["标签"],
                                               segmentTexts: [original.segments[0].id: "最终化期间的校对"])
        try await store.write(edited)
        let latest = try await store.document(recordingID: recording.id)!
        let recluster = OfflineSpeakerReclustering.Result(speakers: [], turns: [], labels: [])
        let result = try await SpeakerFinalizationCoordinator.completedDocument(
            recordingID: recording.id, recluster: recluster, allowCreatingEmptyDocument: false,
            repository: repository, transcriptStore: store
        )
        precondition(result.segments == latest.segments && result.tags == latest.tags && result.title == latest.title)
        try await store.delete(recordingID: recording.id)
        do {
            _ = try await SpeakerFinalizationCoordinator.completedDocument(
                recordingID: recording.id, recluster: recluster, allowCreatingEmptyDocument: false,
                repository: repository, transcriptStore: store
            )
            preconditionFailure("A deleted existing transcript must not be recreated from a stale pass")
        } catch SpeakerFinalizationCoordinator.FinalizationError.invalidated {}
        let absent = try await store.document(recordingID: recording.id)
        precondition(absent == nil)
        let empty = try await SpeakerFinalizationCoordinator.completedDocument(
            recordingID: recording.id, recluster: recluster, allowCreatingEmptyDocument: true,
            repository: repository, transcriptStore: store
        )
        precondition(empty.segments.isEmpty && empty.state == RecordingState.complete.rawValue)
        try await repository.deleteRecording(id: recording.id)
        do {
            _ = try await SpeakerFinalizationCoordinator.completedDocument(
                recordingID: recording.id, recluster: recluster, allowCreatingEmptyDocument: true,
                repository: repository, transcriptStore: store
            )
            preconditionFailure("A deleted Recording must invalidate finalization")
        } catch SpeakerFinalizationCoordinator.FinalizationError.invalidated {}
    }

    static func writeAudio(_ url: URL, duration: Double = 1, sampleRate: Double = 16_000) throws {
        let frames = AVAudioFrameCount(duration * sampleRate)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = Float(sin(Double(i) / 20) * 0.1) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}

private actor Gate {
    var isOpen = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private actor Outcomes {
    var values: [ForegroundTranscriptionScheduler.Outcome] = []
    func add(_ outcome: ForegroundTranscriptionScheduler.Outcome) { values.append(outcome) }
}
