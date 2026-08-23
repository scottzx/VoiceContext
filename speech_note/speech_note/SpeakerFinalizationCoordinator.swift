import Foundation

/// Stable, versioned identity for the one global speaker pass that follows all
/// minute-level transcription jobs. Re-running the same job is safe because
/// every output is atomically replaced at a deterministic path.
nonisolated struct SpeakerFinalizationJob: Hashable, Sendable {
    static let currentPipelineVersion = 1

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

        var errorDescription: String? {
            switch self {
            case let .previouslyFailed(message):
                message ?? "说话人整理失败，等待用户重试。"
            }
        }
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

        var running = durable
        if running.state == .pending {
            running.state = .running
            running.attemptCount += 1
            running.lastError = nil
            running.startedAt = Date()
            running.updatedAt = running.startedAt!
            try await repository.upsertJob(running, at: running.updatedAt)
        }

        do {
            let metrics = try await run(
                job: SpeakerFinalizationJob(recordingID: recordingID),
                repository: repository,
                transcriptStore: transcriptStore,
                publisher: publisher
            )
            var completed = running
            completed.state = .completed
            completed.lastError = nil
            completed.startedAt = nil
            completed.updatedAt = Date()
            try await repository.upsertJob(completed, at: completed.updatedAt)
            return metrics
        } catch {
            var failed = running
            failed.state = .failed
            failed.lastError = error.localizedDescription
            failed.startedAt = nil
            failed.updatedAt = Date()
            _ = try? await repository.upsertJob(failed, at: failed.updatedAt)
            throw error
        }
    }

    func run(
        job: SpeakerFinalizationJob,
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

    private func ensureDurableJob(
        recordingID: UUID,
        repository: RecordingRepository
    ) async throws -> RecordingJob {
        if let existing = try await repository.jobs(recordingID: recordingID)
            .first(where: { $0.kind == .speakerFinalization }) {
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
        repository: RecordingRepository,
        transcriptStore: TranscriptDocumentStore,
        publisher: PublicDocumentPublisher
    ) async throws -> SpeakerFinalizationMetrics {
        let totalStartedAt = Date()
        let loadStartedAt = Date()
        var observations = SpeakerObservationStore.load(
            rootURL: repository.rootURL,
            recordingID: job.recordingID
        )
        var fallbackResult: OfflineSpeakerReclustering.Result?
        if observations.isEmpty {
            let pass = try await offlineSpeakerPass(
                recordingID: job.recordingID,
                repository: repository
            )
            observations = pass.observations
            fallbackResult = pass.recluster
            SpeakerObservationStore.save(
                observations,
                rootURL: repository.rootURL,
                recordingID: job.recordingID
            )
        }
        let observationLoadMilliseconds = elapsedMilliseconds(since: loadStartedAt)

        let reclusterStartedAt = Date()
        let baseline = fallbackResult ?? OfflineSpeakerReclustering.recluster(observations)
        let diarization: SpeakerDiarizationOutput
        if let sherpa = SpeakerDiarizationEngineFactory.approvedSherpaEngine(),
           !baseline.speakers.isEmpty {
            do {
                diarization = try await windowedSherpaDiarization(
                    recordingID: job.recordingID,
                    baseline: baseline,
                    observations: observations,
                    engine: sherpa,
                    repository: repository
                )
            } catch {
                // A decode/model/runtime failure must never discard ASR. The
                // meeting-wide observation baseline remains deterministic.
                diarization = SpeakerDiarizationOutput(
                    engineID: "cam-plus-observation-clustering-v1-fallback",
                    result: baseline
                )
            }
        } else {
            diarization = SpeakerDiarizationOutput(
                engineID: "cam-plus-observation-clustering-v1",
                result: baseline
            )
        }
        let recluster = diarization.result
        let reclusterMilliseconds = elapsedMilliseconds(since: reclusterStartedAt)

        let bindingStartedAt = Date()
        if !recluster.speakers.isEmpty {
            let archiveURL = try VoiceprintArchiveStorage.defaultURL()
            let archive = try VoiceprintArchiveStorage.load(from: archiveURL)
            let bindings = SpeakerIdentityConfirmation.makeBindings(
                speakers: recluster.speakers,
                labels: recluster.labels,
                observations: observations,
                archive: archive
            )
            try MeetingSpeakerBindingStore.save(
                bindings,
                rootURL: repository.rootURL,
                recordingID: job.recordingID
            )
        }
        let bindingMilliseconds = elapsedMilliseconds(since: bindingStartedAt)

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
            diarizationEngineID: diarization.engineID,
            observationCount: observations.count,
            speakerCount: recluster.speakers.count,
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
            var completed = document.updatingState(.complete)
            if !recluster.speakers.isEmpty {
                completed = completed.applyingOfflineRecluster(
                    speakers: recluster.speakers,
                    speakerTurns: recluster.turns
                )
            }
            return completed
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

    /// Fallback for recordings created before incremental observations existed.
    /// It executes at most once in the finalization pass, never per minute.
    private static func offlineSpeakerPass(
        recordingID: UUID,
        repository: RecordingRepository
    ) async throws -> OfflineSpeakerReclusterPass.PassResult {
        let resourceRoot = try OfflineSpeakerReclusterPass.bundledResourceRoot()
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
            return try await OfflineSpeakerReclusterPass.runImportedAsset(
                url: url,
                totalSamples: asset.totalSamples,
                resourceRoot: resourceRoot
            )
        }

        let chunks = try await repository.chunks(recordingID: recordingID)
            .filter { $0.state == .closed && $0.audioRemovedAt == nil }
            .sorted { $0.startSample < $1.startSample }
        return try await OfflineSpeakerReclusterPass.run(
            chunkURLs: chunks.map {
                (
                    url: repository.rootURL.appendingPathComponent($0.relativePath),
                    startSample: $0.startSample
                )
            },
            resourceRoot: resourceRoot
        )
    }

    private static func windowedSherpaDiarization(
        recordingID: UUID,
        baseline: OfflineSpeakerReclustering.Result,
        observations: [OfflineSpeakerObservation],
        engine: SherpaOfflineSpeakerDiarizationEngine,
        repository: RecordingRepository
    ) async throws -> SpeakerDiarizationOutput {
        let session = try engine.makeSession()
        var windowResults: [OfflineSpeakerReclustering.Result] = []

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
            for range in SpeakerDiarizationWindowing.ranges(totalSamples: asset.totalSamples) {
                let samples = try ImportAudioRangeDecoder.samples(
                    from: url,
                    startSample: range.startSample,
                    endSample: range.endSample
                )
                let output = try await session.diarize(
                    SpeakerDiarizationInput(
                        startSample: range.startSample,
                        samples: samples,
                        observations: overlappingObservations(in: range, from: observations)
                    )
                )
                windowResults.append(output.result)
            }
        } else {
            let chunks = try await repository.chunks(recordingID: recordingID)
                .filter { $0.state == .closed && $0.audioRemovedAt == nil }
                .sorted { $0.startSample < $1.startSample }
            guard let finalSample = chunks.last?.endSample, finalSample > 0 else {
                throw SherpaOfflineSpeakerDiarizationEngine.EngineError.emptyAudio
            }
            for range in SpeakerDiarizationWindowing.ranges(totalSamples: finalSample) {
                guard let samples = try microphoneSamples(
                    range: range,
                    chunks: chunks,
                    rootURL: repository.rootURL
                ) else { continue }
                let output = try await session.diarize(
                    SpeakerDiarizationInput(
                        startSample: range.startSample,
                        samples: samples,
                        observations: overlappingObservations(in: range, from: observations)
                    )
                )
                windowResults.append(output.result)
            }
        }

        let aligned = SpeakerDiarizationWindowing.align(
            baseline: baseline,
            observations: observations,
            windowResults: windowResults
        )
        guard !aligned.turns.isEmpty else {
            throw SherpaOfflineSpeakerDiarizationEngine.EngineError.processingFailed
        }
        return SpeakerDiarizationOutput(
            engineID: "\(engine.id)-windowed-60s",
            result: aligned
        )
    }

    private static func overlappingObservations(
        in range: (startSample: Int64, endSample: Int64),
        from observations: [OfflineSpeakerObservation]
    ) -> [OfflineSpeakerObservation] {
        observations.filter {
            $0.startSample < range.endSample && range.startSample < $0.endSample
        }
    }

    /// Reconstructs only one absolute 60-second window from private chunk
    /// files. Gaps remain zero-filled and no complete meeting buffer exists.
    private static func microphoneSamples(
        range: (startSample: Int64, endSample: Int64),
        chunks: [AudioChunk],
        rootURL: URL
    ) throws -> [Float]? {
        let intersecting = chunks.filter {
            $0.startSample < range.endSample && range.startSample < $0.endSample
        }
        guard !intersecting.isEmpty else { return nil }

        var output = Array(
            repeating: Float.zero,
            count: Int(range.endSample - range.startSample)
        )
        for chunk in intersecting {
            let absoluteStart = max(range.startSample, chunk.startSample)
            let absoluteEnd = min(range.endSample, chunk.endSample)
            guard absoluteEnd > absoluteStart else { continue }
            let decoded = try ImportAudioRangeDecoder.samples(
                from: rootURL.appendingPathComponent(chunk.relativePath),
                startSample: absoluteStart - chunk.startSample,
                endSample: absoluteEnd - chunk.startSample
            )
            let destinationStart = Int(absoluteStart - range.startSample)
            let take = min(decoded.count, Int(absoluteEnd - absoluteStart))
            guard take > 0 else { continue }
            output.withUnsafeMutableBufferPointer { destination in
                decoded.withUnsafeBufferPointer { source in
                    guard let destinationBase = destination.baseAddress,
                          let sourceBase = source.baseAddress else { return }
                    destinationBase.advanced(by: destinationStart).update(
                        from: sourceBase,
                        count: take
                    )
                }
            }
        }
        return output
    }

    private static func elapsedMilliseconds(since start: Date) -> Double {
        Date().timeIntervalSince(start) * 1_000
    }
}
