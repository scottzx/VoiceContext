import Foundation

/// Stable, versioned identity for the one global speaker pass that follows all
/// minute-level transcription jobs. Re-running the same job is safe because
/// every output is atomically replaced at a deterministic path.
nonisolated struct SpeakerFinalizationJob: Hashable, Sendable {
    static let currentPipelineVersion = 5

    let recordingID: UUID
    let pipelineVersion: Int

    init(recordingID: UUID, pipelineVersion: Int = currentPipelineVersion) {
        self.recordingID = recordingID
        self.pipelineVersion = pipelineVersion
    }
}

nonisolated struct TranscriptionStageMetrics: Codable, Equatable, Sendable {
    let recordingID: UUID
    let batchID: UUID
    let audioDurationMilliseconds: Double
    let vadMilliseconds: Double
    let asrLoadMilliseconds: Double
    let asrInferenceMilliseconds: Double
    let embeddingMilliseconds: Double
    let commitMilliseconds: Double
    let thermalState: String
    let completedAt: Date
}

nonisolated struct SpeakerFinalizationMetrics: Codable, Equatable, Sendable {
    let recordingID: UUID
    let pipelineVersion: Int
    let diarizationEngineID: String
    let observationCount: Int
    let speakerCount: Int
    /// Number of meeting-wide fallback passes started by this finalization.
    /// It is always zero or one; persisted observations make retries zero.
    let offlineSpeakerPassCount: Int?
    let offlineSpeakerPassMilliseconds: Double?
    let acousticStrategy: String?
    let sherpaWindowCount: Int?
    let sparseEmbeddingCount: Int?
    let sparseEmbeddingMilliseconds: Double?
    let candidateSegmentCount: Int?
    let audioDecodeMilliseconds: Double?
    let unknownSegmentCount: Int?
    let multipleSegmentCount: Int?
    let weakMatchedSegmentCount: Int?
    let observationLoadMilliseconds: Double
    let reclusterMilliseconds: Double
    let bindingMilliseconds: Double
    let transcriptCommitMilliseconds: Double
    let publicPublishMilliseconds: Double
    let totalMilliseconds: Double
    let completedAt: Date
}

/// Private per-target metrics. Files are intentionally sharded so metrics do
/// not introduce the same whole-meeting rewrite cost removed from observations.
nonisolated enum TranscriptionStageMetricsStore {
    private static let directoryName = "ProcessingMetrics"

    static func transcriptionURL(rootURL: URL, recordingID: UUID, batchID: UUID) -> URL {
        rootURL
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(recordingID.uuidString.uppercased(), isDirectory: true)
            .appendingPathComponent("Transcription", isDirectory: true)
            .appendingPathComponent("\(batchID.uuidString.uppercased()).json", isDirectory: false)
    }

    static func speakerFinalizationURL(rootURL: URL, job: SpeakerFinalizationJob) -> URL {
        rootURL
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(job.recordingID.uuidString.uppercased(), isDirectory: true)
            .appendingPathComponent("speaker-finalization-v\(job.pipelineVersion).json", isDirectory: false)
    }

    static func save(_ metrics: TranscriptionStageMetrics, rootURL: URL) throws {
        try write(
            metrics,
            to: transcriptionURL(
                rootURL: rootURL,
                recordingID: metrics.recordingID,
                batchID: metrics.batchID
            )
        )
    }

    static func save(_ metrics: SpeakerFinalizationMetrics, rootURL: URL) throws {
        try write(
            metrics,
            to: speakerFinalizationURL(
                rootURL: rootURL,
                job: SpeakerFinalizationJob(
                    recordingID: metrics.recordingID,
                    pipelineVersion: metrics.pipelineVersion
                )
            )
        )
    }

    static func loadTranscription(
        rootURL: URL,
        recordingID: UUID,
        batchID: UUID
    ) throws -> TranscriptionStageMetrics {
        try JSONDecoder().decode(
            TranscriptionStageMetrics.self,
            from: Data(contentsOf: transcriptionURL(
                rootURL: rootURL,
                recordingID: recordingID,
                batchID: batchID
            ))
        )
    }

    static func loadSpeakerFinalization(
        rootURL: URL,
        job: SpeakerFinalizationJob
    ) throws -> SpeakerFinalizationMetrics {
        try JSONDecoder().decode(
            SpeakerFinalizationMetrics.self,
            from: Data(contentsOf: speakerFinalizationURL(rootURL: rootURL, job: job))
        )
    }

    static func removeSpeakerFinalization(rootURL: URL, recordingID: UUID) {
        let directory = rootURL
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(recordingID.uuidString.uppercased(), isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for url in urls where url.lastPathComponent.hasPrefix("speaker-finalization-v") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

/// Coalesces duplicate completion callbacks and performs the expensive global
/// clustering/binding/publication pass once after ASR is durable.
actor SpeakerFinalizationCoordinator {
    private var inFlight: [SpeakerFinalizationJob: Task<SpeakerFinalizationMetrics, Error>] = [:]

    enum FinalizationError: LocalizedError {
        case previouslyFailed(String?)
        case invalidated

        var errorDescription: String? {
            switch self {
            case let .previouslyFailed(message):
                message ?? "说话人整理失败，等待用户重试。"
            case .invalidated:
                "说话人整理已被新的转写任务取代。"
            }
        }
    }

    func invalidate(recordingID: UUID) {
        let job = SpeakerFinalizationJob(recordingID: recordingID)
        inFlight[job]?.cancel()
        inFlight[job] = nil
    }

    /// Creates the durable finalization fact before doing work, so completion
    /// reconciliation never mistakes "ASR done" for "all processing done".
    func runPersisted(
        recordingID: UUID,
        repository: RecordingRepository,
        transcriptStore: TranscriptDocumentStore,
        publisher: PublicDocumentPublisher
    ) async throws -> SpeakerFinalizationMetrics {
        let durable = try await ensureDurableJob(
            recordingID: recordingID,
            repository: repository
        )
        if durable.state == .completed,
           let metrics = try? TranscriptionStageMetricsStore.loadSpeakerFinalization(
               rootURL: repository.rootURL,
               job: SpeakerFinalizationJob(recordingID: recordingID)
           ) {
            return metrics
        }
        if durable.state == .failed {
            throw FinalizationError.previouslyFailed(durable.lastError)
        }

        let job = SpeakerFinalizationJob(recordingID: recordingID)
        if durable.state == .running, inFlight[job] != nil {
            return try await run(
                job: job,
                execution: durable,
                repository: repository,
                transcriptStore: transcriptStore,
                publisher: publisher
            )
        }
        if durable.state == .running || durable.state == .completed {
            var orphaned = durable
            orphaned.state = .pending
            orphaned.lastError = durable.state == .running
                ? "recoveredAfterTermination"
                : "missingFinalizationMetrics"
            orphaned.executionToken = nil
            orphaned.startedAt = nil
            orphaned.terminationReason = orphaned.lastError
            orphaned.updatedAt = Date()
            try await repository.upsertJob(orphaned, at: orphaned.updatedAt)
        }
        guard let running = try await repository.claimSpeakerFinalization(
            jobID: durable.id,
            recordingID: recordingID,
            pipelineVersion: job.pipelineVersion,
            at: Date()
        ) else { throw FinalizationError.invalidated }

        do {
            let metrics = try await run(
                job: job,
                execution: running,
                repository: repository,
                transcriptStore: transcriptStore,
                publisher: publisher
            )
            guard let token = running.executionToken,
                  try await repository.finishSpeakerFinalization(
                      jobID: running.id,
                      recordingID: recordingID,
                      executionToken: token,
                      state: .completed,
                      at: Date()
                  ) != nil else { throw FinalizationError.invalidated }
            return metrics
        } catch {
            if let token = running.executionToken {
                _ = try? await repository.finishSpeakerFinalization(
                    jobID: running.id,
                    recordingID: recordingID,
                    executionToken: token,
                    state: error is CancellationError ? .pending : .failed,
                    lastError: error.localizedDescription,
                    terminationReason: error is CancellationError ? "cancelled" : "finalizerFailed",
                    at: Date()
                )
            }
            throw error
        }
    }

    func run(
        job: SpeakerFinalizationJob,
        execution: RecordingJob,
        repository: RecordingRepository,
        transcriptStore: TranscriptDocumentStore,
        publisher: PublicDocumentPublisher
    ) async throws -> SpeakerFinalizationMetrics {
        if let existing = inFlight[job] {
            return try await existing.value
        }

        let task = Task {
            try await Self.perform(
                job: job,
                execution: execution,
                repository: repository,
                transcriptStore: transcriptStore,
                publisher: publisher
            )
        }
        inFlight[job] = task
        do {
            let metrics = try await task.value
            inFlight[job] = nil
            return metrics
        } catch {
            inFlight[job] = nil
            throw error
        }
    }

    func ensureDurableJob(
        recordingID: UUID,
        repository: RecordingRepository
    ) async throws -> RecordingJob {
        if var existing = try await repository.jobs(recordingID: recordingID)
            .first(where: { $0.kind == .speakerFinalization }) {
            if existing.pipelineVersion < SpeakerFinalizationJob.currentPipelineVersion {
                existing.state = .pending
                existing.lastError = nil
                existing.pipelineVersion = SpeakerFinalizationJob.currentPipelineVersion
                existing.executionToken = nil
                existing.startedAt = nil
                existing.terminationReason = "upgradedSpeakerPipeline"
                existing.updatedAt = Date()
                try await repository.upsertJob(existing, at: existing.updatedAt)
                SpeakerObservationStore.remove(
                    rootURL: repository.rootURL,
                    recordingID: recordingID
                )
                TranscriptionStageMetricsStore.removeSpeakerFinalization(
                    rootURL: repository.rootURL,
                    recordingID: recordingID
                )
            }
            return existing
        }
        let now = Date()
        let pending = RecordingJob(
            recordingID: recordingID,
            kind: .speakerFinalization,
            state: .pending,
            attemptCount: 0,
            lastError: nil,
            pipelineVersion: SpeakerFinalizationJob.currentPipelineVersion,
            createdAt: now,
            updatedAt: now
        )
        try await repository.upsertJob(pending, at: now)
        return pending
    }

    private static func perform(
        job: SpeakerFinalizationJob,
        execution: RecordingJob,
        repository: RecordingRepository,
        transcriptStore: TranscriptDocumentStore,
        publisher: PublicDocumentPublisher
    ) async throws -> SpeakerFinalizationMetrics {
        try Task.checkCancellation()
        let totalStartedAt = Date()
        let document = try await transcriptStore.document(recordingID: job.recordingID)
        let segments = document?.segments ?? []
        let loadStartedAt = Date()
        var observations = SpeakerObservationStore.load(
            rootURL: repository.rootURL,
            recordingID: job.recordingID
        )
        let observationLoadMilliseconds = elapsedMilliseconds(since: loadStartedAt)
        var audioDecodeMilliseconds: Double = 0
        var sparseEmbeddingMilliseconds: Double = 0
        if observations.isEmpty, !segments.isEmpty {
            let decodeStartedAt = Date()
            let segmentAudio = try await segmentAudio(
                segments: segments,
                recordingID: job.recordingID,
                repository: repository
            )
            audioDecodeMilliseconds = elapsedMilliseconds(since: decodeStartedAt)
            let anchors = SegmentSpeakerAnchorPlanner.anchors(for: segmentAudio)
            let embeddingStartedAt = Date()
            let embeddings = await CAMPlusShortWindowEmbedder.embedConcurrently(
                windows: anchors.map(\.window),
                modelURL: try speakerEmbeddingModelURL(),
                maximumParallelism: 4
            )
            sparseEmbeddingMilliseconds = elapsedMilliseconds(since: embeddingStartedAt)
            observations = zip(anchors, embeddings).map { anchor, embedding in
                OfflineSpeakerObservation(
                    startSample: anchor.window.startSample,
                    endSample: anchor.window.endSample,
                    embedding: embedding,
                    exclusionReasons: anchor.window.exclusionReasons,
                    onlineTemporaryLabel: anchor.segmentID.uuidString.lowercased()
                )
            }
            SpeakerObservationStore.save(
                observations,
                rootURL: repository.rootURL,
                recordingID: job.recordingID
            )
        }

        let reclusterStartedAt = Date()
        let sentenceGate = SegmentSpeakerSentenceGate.evaluate(
            segmentIDs: segments.map(\.id),
            observations: observations,
            mergeSimilarityThreshold: 0.65
        )
        let clustered = OfflineSpeakerReclustering.recluster(
            sentenceGate.representatives,
            mergeSimilarityThreshold: 0.65,
            shortJumpMaxWindows: 0
        )
        let validatedAttributions = SegmentSpeakerSentenceGate.validatingUnknowns(
            sentenceGate,
            observations: observations,
            representativeLabels: clustered.labels,
            mergeSimilarityThreshold: 0.65
        )
        let finalCleanup = SegmentSpeakerSentenceGate.matchingSingleAnchorUnknowns(
            attributions: validatedAttributions,
            observations: observations,
            representatives: sentenceGate.representatives,
            representativeLabels: clustered.labels
        )
        let assignment = SegmentSpeakerAssignmentResolver.resolve(
            segments: segments.map {
                SegmentSpeakerAssignmentResolver.Segment(
                    id: $0.id,
                    startSample: $0.startSample,
                    endSample: $0.endSample
                )
            },
            attributions: finalCleanup.attributions,
            representativeSegmentIDs: sentenceGate.representatives.map {
                $0.onlineTemporaryLabel.flatMap(UUID.init(uuidString:))
            },
            representativeLabels: clustered.labels,
            supplementalLabels: finalCleanup.supplementalLabels
        )
        let recluster = OfflineSpeakerReclustering.Result(
            speakers: assignment.speakers,
            turns: assignment.turns,
            labels: clustered.labels
        )
        let reclusterMilliseconds = elapsedMilliseconds(since: reclusterStartedAt)

        let bindingStartedAt = Date()
        if !recluster.speakers.isEmpty {
            let archiveURL = try VoiceprintArchiveStorage.defaultURL()
            let archive = try VoiceprintArchiveStorage.load(from: archiveURL)
            let bindings = SpeakerIdentityConfirmation.makeBindings(
                speakers: recluster.speakers,
                labels: recluster.labels,
                observations: sentenceGate.representatives,
                archive: archive
            )
            try MeetingSpeakerBindingStore.save(
                bindings,
                rootURL: repository.rootURL,
                recordingID: job.recordingID
            )
        }
        let bindingMilliseconds = elapsedMilliseconds(since: bindingStartedAt)

        guard let executionToken = execution.executionToken,
              try await repository.validateSpeakerFinalization(
                  jobID: execution.id,
                  recordingID: job.recordingID,
                  executionToken: executionToken,
                  pipelineVersion: execution.pipelineVersion
              ) else { throw FinalizationError.invalidated }
        try Task.checkCancellation()
        let commitStartedAt = Date()
        let completed = try await completedDocument(
            recordingID: job.recordingID,
            recluster: recluster,
            repository: repository,
            transcriptStore: transcriptStore
        )
        try await transcriptStore.write(completed)
        let transcriptCommitMilliseconds = elapsedMilliseconds(since: commitStartedAt)

        let publishStartedAt = Date()
        let recordings = try await repository.recordings()
        var dayDocuments: [TranscriptDocumentV1] = []
        for recording in recordings where PublicDocumentLayout.isSameLocalDay(
            recording.startedAt,
            completed.startedAt,
            timezoneIdentifier: completed.timezone
        ) {
            if let peer = try await transcriptStore.document(recordingID: recording.id) {
                dayDocuments.append(peer)
            }
        }
        _ = try await publisher.publish(document: completed, dayDocuments: dayDocuments)
        let publicPublishMilliseconds = elapsedMilliseconds(since: publishStartedAt)

        let metrics = SpeakerFinalizationMetrics(
            recordingID: job.recordingID,
            pipelineVersion: job.pipelineVersion,
            diarizationEngineID: "cam-plus-vad-segment-five-point-gate-weak-match-v5",
            observationCount: observations.count,
            speakerCount: recluster.speakers.count,
            offlineSpeakerPassCount: 0,
            offlineSpeakerPassMilliseconds: 0,
            acousticStrategy: "vad-segment-five-point-single-only-cam-plus-weak-cleanup",
            sherpaWindowCount: 0,
            sparseEmbeddingCount: observations.filter(\.isEligibleForWeakMatching).count,
            sparseEmbeddingMilliseconds: sparseEmbeddingMilliseconds,
            candidateSegmentCount: segments.count,
            audioDecodeMilliseconds: audioDecodeMilliseconds,
            unknownSegmentCount: assignment.unknownSegmentCount,
            multipleSegmentCount: assignment.multipleSegmentCount,
            weakMatchedSegmentCount: finalCleanup.supplementalLabels.count,
            observationLoadMilliseconds: observationLoadMilliseconds,
            reclusterMilliseconds: reclusterMilliseconds,
            bindingMilliseconds: bindingMilliseconds,
            transcriptCommitMilliseconds: transcriptCommitMilliseconds,
            publicPublishMilliseconds: publicPublishMilliseconds,
            totalMilliseconds: elapsedMilliseconds(since: totalStartedAt),
            completedAt: Date()
        )
        try TranscriptionStageMetricsStore.save(metrics, rootURL: repository.rootURL)
        return metrics
    }

    private static func completedDocument(
        recordingID: UUID,
        recluster: OfflineSpeakerReclustering.Result,
        repository: RecordingRepository,
        transcriptStore: TranscriptDocumentStore
    ) async throws -> TranscriptDocumentV1 {
        if let document = try await transcriptStore.document(recordingID: recordingID) {
            return document.updatingState(.complete).applyingOfflineRecluster(
                speakers: recluster.speakers,
                speakerTurns: recluster.turns
            )
        }

        guard let recording = try await repository.recording(id: recordingID) else {
            throw SenseVoiceInferenceService.InferenceError.runtime("找不到待最终化的录音")
        }
        if let asset = try await repository.importedAudioAsset(recordingID: recordingID) {
            return TranscriptDocumentV1(
                recording: recording,
                audioAvailableOnThisDevice: asset.audioRemovedAt == nil,
                segmentDrafts: [],
                language: "",
                state: .complete,
                speakers: recluster.speakers
            )
        }
        let chunks = try await repository.chunks(recordingID: recordingID)
        return TranscriptDocumentV1(
            recording: recording,
            chunks: chunks,
            segmentDrafts: [],
            language: "",
            state: .complete,
            speakers: recluster.speakers
        )
    }

    private static func speakerEmbeddingModelURL() throws -> URL {
        let resourceRoot = try OfflineSpeakerReclusterPass.bundledResourceRoot()
        let url = resourceRoot.appendingPathComponent(
            "3dspeaker_speech_eres2net_base_200k_sv_zh-cn_16k-common.onnx",
            isDirectory: false
        )
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw OfflineSpeakerReclusterPass.PassError.missingResource(url.lastPathComponent)
        }
        return url
    }

    /// Decodes each underlying audio source once per bounded source window and
    /// distributes only the existing VAD segment ranges into segment buffers.
    /// Transcript text is never read here.
    private static func segmentAudio(
        segments: [TranscriptDocumentV1.Segment],
        recordingID: UUID,
        repository: RecordingRepository
    ) async throws -> [SegmentSpeakerAudio] {
        var samplesBySegmentID: [UUID: [Float]] = [:]

        if var asset = try await repository.importedAudioAsset(recordingID: recordingID),
           asset.audioRemovedAt == nil {
            var url = repository.rootURL.appendingPathComponent(asset.relativePath)
            if !asset.isStandardized,
               !ImportAudioStandardizer.supportsRandomAccess(at: url) {
                asset = try ImportAudioStandardizer.replaceWithStandardized(
                    asset: asset,
                    rootURL: repository.rootURL
                )
                try await repository.updateImportedAudioAsset(asset, at: Date())
                url = repository.rootURL.appendingPathComponent(asset.relativePath)
            }

            let importedRanges = sourceRanges(
                segments: segments,
                kind: .importedAsset,
                sourceID: asset.id
            )
            for window in SpeakerDiarizationWindowing.ranges(totalSamples: asset.totalSamples)
            where importedRanges.contains(where: {
                $0.range.startSample < window.endSample && window.startSample < $0.range.endSample
            }) {
                try Task.checkCancellation()
                let decoded = try ImportAudioRangeDecoder.samples(
                    from: url,
                    startSample: window.startSample,
                    endSample: window.endSample
                )
                appendIntersections(
                    sourceRanges: importedRanges,
                    decodedSamples: decoded,
                    decodedStartSample: window.startSample,
                    decodedEndSample: window.endSample,
                    samplesBySegmentID: &samplesBySegmentID
                )
            }
        } else {
            let chunks = try await repository.chunks(recordingID: recordingID)
                .filter { $0.state == .closed && $0.audioRemovedAt == nil }
                .sorted { $0.startSample < $1.startSample }
            for chunk in chunks {
                let ranges = sourceRanges(
                    segments: segments,
                    kind: .audioChunk,
                    sourceID: chunk.id
                )
                guard !ranges.isEmpty else { continue }
                try Task.checkCancellation()
                let decoded = try ImportAudioRangeDecoder.samples(
                    from: repository.rootURL.appendingPathComponent(chunk.relativePath),
                    startSample: 0,
                    endSample: chunk.endSample - chunk.startSample
                )
                appendIntersections(
                    sourceRanges: ranges,
                    decodedSamples: decoded,
                    decodedStartSample: chunk.startSample,
                    decodedEndSample: chunk.endSample,
                    samplesBySegmentID: &samplesBySegmentID
                )
            }
        }

        return segments.map { segment in
            SegmentSpeakerAudio(
                segmentID: segment.id,
                startSample: segment.startSample,
                endSample: segment.endSample,
                samples: samplesBySegmentID[segment.id] ?? []
            )
        }
    }

    private struct SegmentSourceRange {
        let segmentID: UUID
        let range: TranscriptDocumentV1.SourceRange
    }

    private static func sourceRanges(
        segments: [TranscriptDocumentV1.Segment],
        kind: TranscriptDocumentV1.SourceRange.Kind,
        sourceID: UUID
    ) -> [SegmentSourceRange] {
        segments.flatMap { segment in
            segment.sourceRanges.compactMap { range in
                guard range.sourceKind == kind, range.sourceID == sourceID else { return nil }
                return SegmentSourceRange(segmentID: segment.id, range: range)
            }
        }.sorted {
            if $0.range.startSample != $1.range.startSample {
                return $0.range.startSample < $1.range.startSample
            }
            return $0.range.endSample < $1.range.endSample
        }
    }

    private static func appendIntersections(
        sourceRanges: [SegmentSourceRange],
        decodedSamples: [Float],
        decodedStartSample: Int64,
        decodedEndSample: Int64,
        samplesBySegmentID: inout [UUID: [Float]]
    ) {
        for item in sourceRanges {
            let lower = max(item.range.startSample, decodedStartSample)
            let upper = min(item.range.endSample, decodedEndSample)
            guard upper > lower else { continue }
            let localLower = Int(lower - decodedStartSample)
            let localUpper = min(Int(upper - decodedStartSample), decodedSamples.count)
            guard localUpper > localLower else { continue }
            samplesBySegmentID[item.segmentID, default: []]
                .append(contentsOf: decodedSamples[localLower..<localUpper])
        }
    }

    private static func elapsedMilliseconds(since start: Date) -> Double {
        Date().timeIntervalSince(start) * 1_000
    }
}
