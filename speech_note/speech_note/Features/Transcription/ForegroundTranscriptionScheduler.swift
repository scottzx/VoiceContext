import Foundation

/// Persists and serializes local transcription work. Background inference is
/// admitted only while an iOS continued-processing grant is active; otherwise
/// unfinished work remains pending until the app is foregrounded again.
actor ForegroundTranscriptionScheduler {
    struct QueueSnapshot: Sendable, Equatable {
        let pending: Int
        let running: Int
        let completed: Int
        let failed: Int
        let total: Int
    }

    struct Outcome: Sendable, Equatable {
        enum State: Sendable, Equatable {
            case completed
            case failed(message: String)
        }

        let recordingID: UUID
        let chunkID: UUID?
        let processingRangeID: UUID?
        let state: State

        init(
            recordingID: UUID,
            chunkID: UUID? = nil,
            processingRangeID: UUID? = nil,
            state: State
        ) {
            self.recordingID = recordingID
            self.chunkID = chunkID
            self.processingRangeID = processingRangeID
            self.state = state
        }
    }

    typealias Executor = @Sendable (JobExecutionLease) async throws -> Void
    typealias OutcomeHandler = @Sendable (Outcome) async -> Void

    private let repository: RecordingRepository
    private let lifecycleGate: InferenceLifecycleGate
    private let admissionPolicy: TranscriptionAdmissionPolicy
    private let execute: Executor
    private let now: @Sendable () -> Date
    private var isInBackground = false
    private var continuedBackgroundExecutionAllowed = false
    private var recoveryBarrierActive = false
    private var drainTask: Task<Void, Never>?
    private var drainGeneration: UUID?
    private var outcomeHandlers: [UUID: OutcomeHandler] = [:]

    init(
        repository: RecordingRepository,
        lifecycleGate: InferenceLifecycleGate = InferenceLifecycleGate(),
        admissionPolicy: TranscriptionAdmissionPolicy = TranscriptionAdmissionPolicy(),
        now: @escaping @Sendable () -> Date = Date.init,
        execute: @escaping Executor
    ) {
        self.repository = repository
        self.lifecycleGate = lifecycleGate
        self.admissionPolicy = admissionPolicy
        self.now = now
        self.execute = execute
    }

    /// Adds a durable transcription job. The caller supplies the presentation
    /// callback because the scheduler deliberately has no UI dependency.
    ///
    /// The minute-level queue only creates chunk-scoped jobs. A nil `chunkID`
    /// names the pre-incremental whole-recording job format: the outcome
    /// handler attaches to an existing legacy job if one is present, but a new
    /// one is never created for a Recording that has a durable chunk queue.
    func enqueue(
        recordingID: UUID,
        chunkID: UUID? = nil,
        processingRangeID: UUID? = nil,
        onOutcome: @escaping OutcomeHandler
    ) async throws {
        precondition(chunkID == nil || processingRangeID == nil, "chunk and range jobs are mutually exclusive")
        let jobs = try await repository.jobs(recordingID: recordingID)
        if let processingRangeID {
            if let existing = jobs.last(where: {
                $0.kind == .transcription && $0.processingRangeID == processingRangeID
            }) {
                outcomeHandlers[existing.id] = onOutcome
                try await retry(job: existing)
            } else {
                let date = now()
                let job = RecordingJob(
                    id: UUID(),
                    recordingID: recordingID,
                    processingRangeID: processingRangeID,
                    kind: .transcription,
                    state: .pending,
                    attemptCount: 0,
                    lastError: nil,
                    createdAt: date,
                    updatedAt: date
                )
                outcomeHandlers[job.id] = onOutcome
                try await repository.upsertJob(job, at: date)
            }
            startDrainingIfPossible()
            return
        }
        guard let chunkID else {
            if let legacy = jobs.last(where: {
                $0.kind == .transcription && $0.chunkID == nil && $0.processingRangeID == nil
            }) {
                outcomeHandlers[legacy.id] = onOutcome
                try await retry(job: legacy)
                startDrainingIfPossible()
            }
            return
        }
        if let existing = jobs.last(where: { $0.kind == .transcription && $0.chunkID == chunkID }) {
            outcomeHandlers[existing.id] = onOutcome
            try await retry(job: existing)
        } else {
            let date = now()
            let job = RecordingJob(
                id: UUID(),
                recordingID: recordingID,
                chunkID: chunkID,
                kind: .transcription,
                state: .pending,
                attemptCount: 0,
                lastError: nil,
                createdAt: date,
                updatedAt: date
            )
            outcomeHandlers[job.id] = onOutcome
            try await repository.upsertJob(job, at: date)
        }
        startDrainingIfPossible()
    }

    /// Retries a failed job only after the caller has moved its Recording back
    /// from `failed` to `processing`.
    func retry(
        recordingID: UUID,
        chunkID: UUID? = nil,
        processingRangeID: UUID? = nil,
        onOutcome: @escaping OutcomeHandler
    ) async throws {
        let jobs = try await repository.jobs(recordingID: recordingID)
        let failedJobs = jobs.filter { job in
            guard job.kind == .transcription, job.state == .failed else { return false }
            if let processingRangeID {
                return job.processingRangeID == processingRangeID
            }
            if let chunkID {
                return job.chunkID == chunkID
            }
            return true
        }
        if failedJobs.isEmpty {
            if let processingRangeID {
                guard jobs.last(where: {
                    $0.kind == .transcription && $0.processingRangeID == processingRangeID
                }) == nil else { return }
                return try await enqueue(
                    recordingID: recordingID,
                    processingRangeID: processingRangeID,
                    onOutcome: onOutcome
                )
            }
            guard jobs.last(where: { $0.kind == .transcription && $0.chunkID == chunkID }) == nil else { return }
            return try await enqueue(recordingID: recordingID, chunkID: chunkID, onOutcome: onOutcome)
        }
        for job in failedJobs {
            outcomeHandlers[job.id] = onOutcome
            try await retry(job: job)
        }
        startDrainingIfPossible()
    }

    /// A running Metal job is interrupted, rather than failed, when the app
    /// backgrounds. Its pending record retains the retryable work item.
    func enteredBackground() async {
        isInBackground = true
        guard !continuedBackgroundExecutionAllowed else { return }
        await suspendCurrentDrain(reason: "deferredUntilForeground")
        await lifecycleGate.enteredBackground()
    }

    func enteredForeground() async {
        isInBackground = false
        await lifecycleGate.enteredForeground()
        startDrainingIfPossible()
    }

    /// iOS continued-processing integration may keep the same reliable queue
    /// running while backgrounded. Turning it off invalidates the current
    /// attempt before another execution can be admitted.
    func setContinuedBackgroundExecutionAllowed(_ allowed: Bool) async {
        continuedBackgroundExecutionAllowed = allowed
        if isInBackground, !allowed {
            await suspendCurrentDrain(reason: "deferredUntilForeground")
        } else {
            startDrainingIfPossible()
        }
    }

    func expireCurrentExecution(reason: String = "backgroundTaskExpired") async {
        continuedBackgroundExecutionAllowed = false
        await suspendCurrentDrain(reason: reason)
    }

    /// Re-evaluates admission after purchase unlock or thermal recovery without
    /// requiring a scene-phase transition.
    func requestDrain() {
        startDrainingIfPossible()
    }

    /// Closes admission before journal replay/backfill. The caller completes
    /// the barrier through `resumePendingJobs`, after observers are attached.
    func beginRecoveryBarrier() async throws {
        recoveryBarrierActive = true
        await suspendCurrentDrain(reason: "recoveredAfterTermination")
    }

    /// Restores pending work and turns crash-left `running` rows back into
    /// pending before submitting any new Metal command buffer.
    func resumePendingJobs(onOutcome: @escaping OutcomeHandler) async throws {
        let jobs = try await repository.jobs(
            kind: .transcription,
            states: [.pending, .running]
        )
        for var job in jobs {
            outcomeHandlers[job.id] = onOutcome
            if job.state == .running {
                job.state = .pending
                job.lastError = "recoveredAfterTermination"
                job.executionToken = nil
                job.terminationReason = "recoveredAfterTermination"
                job.updatedAt = now()
                try await repository.upsertJob(job, at: job.updatedAt)
            }
        }
        recoveryBarrierActive = false
        startDrainingIfPossible()
    }

    /// Stops all ongoing and pending transcription jobs immediately.
    func stopAll() async {
        await suspendCurrentDrain(reason: "userStopped")
        let jobs = (try? await repository.jobs(kind: .transcription, states: [.pending, .running])) ?? []
        let date = now()
        for var job in jobs {
            job.state = .failed
            job.lastError = "userStopped"
            job.executionToken = nil
            job.terminationReason = "userStopped"
            job.updatedAt = date
            try? await repository.upsertJob(job, at: date)
        }
    }

    /// Cancels one Recording's unfinished transcription work without
    /// interrupting the rest of the queue after the current drain restarts.
    func cancel(recordingID: UUID) async {
        await suspendCurrentDrain(reason: "userCancelled")
        let jobs = (try? await repository.jobs(recordingID: recordingID)) ?? []
        let date = now()
        for var job in jobs where
            job.kind == .transcription && (job.state == .pending || job.state == .running) {
            job.state = .cancelled
            job.lastError = nil
            job.executionToken = nil
            job.startedAt = nil
            job.terminationReason = "userCancelled"
            job.updatedAt = date
            try? await repository.upsertJob(job, at: date)
        }
        startDrainingIfPossible()
    }

    /// Invalidates any old ASR lease before a full-recording retry rewrites
    /// every durable job. Draining resumes after the caller reattaches all
    /// outcome handlers through `enqueue`.
    func prepareForRetranscription(recordingID: UUID) async {
        await suspendCurrentDrain(reason: "invalidatedByRetranscription")
        let jobs = (try? await repository.jobs(recordingID: recordingID)) ?? []
        for job in jobs where job.kind == .transcription {
            outcomeHandlers.removeValue(forKey: job.id)
        }
    }

    /// Resumes any jobs that were stopped by the user or are pending.
    func resumeAll(onOutcome: OutcomeHandler? = nil) async {
        let stoppedJobs = (try? await repository.jobs(kind: .transcription, states: [.failed])) ?? []
        let date = now()
        for var job in stoppedJobs {
            if job.lastError == "userStopped" {
                job.state = .pending
                job.lastError = nil
                job.updatedAt = date
                if let onOutcome {
                    outcomeHandlers[job.id] = onOutcome
                }
                try? await repository.upsertJob(job, at: date)
            }
        }
        startDrainingIfPossible()
    }

    /// Lets non-UI callers await the current queue drain. It is also useful to
    /// keep deterministic scheduler tests independent of arbitrary sleeps.
    func waitForIdle() async {
        while let drainTask {
            await drainTask.value
        }
    }

    func queueSnapshot() async -> QueueSnapshot {
        let jobs = (try? await repository.jobs(
            kind: .transcription,
            states: [.pending, .running, .completed, .failed]
        )) ?? []
        return QueueSnapshot(
            pending: jobs.filter { $0.state == .pending }.count,
            running: jobs.filter { $0.state == .running }.count,
            completed: jobs.filter { $0.state == .completed }.count,
            failed: jobs.filter { $0.state == .failed }.count,
            total: jobs.count
        )
    }

    /// Same-Recording checkpoints run in absolute chunk order even when job
    /// `createdAt` values were recovered out of order. Distinct Recordings keep
    /// FIFO by `createdAt` so an old backlog does not jump ahead of newer work
    /// beyond ordinary queue order — and never blocks capture.
    private func nextPendingJob() async throws -> RecordingJob? {
        let pending = try await repository.jobs(
            kind: .transcription,
            states: [.pending]
        )
        guard !pending.isEmpty else { return nil }

        var startSampleByChunk: [UUID: Int64] = [:]
        var startSampleByRange: [UUID: Int64] = [:]
        var loadedRecordings = Set<UUID>()
        for job in pending {
            guard loadedRecordings.insert(job.recordingID).inserted else { continue }
            let chunks = try await repository.chunks(recordingID: job.recordingID)
            for chunk in chunks {
                startSampleByChunk[chunk.id] = chunk.startSample
            }
            // Range lookup is best-effort: a microphone-only Recording has none,
            // and a transient read miss must not scramble chunk start-sample order.
            if let ranges = try? await repository.processingRanges(recordingID: job.recordingID) {
                for range in ranges {
                    startSampleByRange[range.id] = range.startSample
                }
            }
        }

        return pending.sorted { lhs, rhs in
            if lhs.recordingID == rhs.recordingID {
                let left = lhs.processingRangeID.flatMap { startSampleByRange[$0] }
                    ?? lhs.chunkID.flatMap { startSampleByChunk[$0] }
                    ?? Int64.max
                let right = rhs.processingRangeID.flatMap { startSampleByRange[$0] }
                    ?? rhs.chunkID.flatMap { startSampleByChunk[$0] }
                    ?? Int64.max
                if left != right { return left < right }
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }.first
    }

    private func retry(job: RecordingJob) async throws {

        var pending = job
        pending.state = .pending
        pending.lastError = nil
        pending.executionToken = nil
        pending.terminationReason = nil
        pending.updatedAt = now()
        try await repository.upsertJob(pending, at: pending.updatedAt)
    }

    private func startDrainingIfPossible() {
        guard canExecute, drainTask == nil else { return }
        let generation = UUID()
        drainGeneration = generation
        drainTask = Task { [weak self] in
            await self?.drain(generation: generation)
        }
    }

    private var canExecute: Bool {
        !recoveryBarrierActive && (!isInBackground || continuedBackgroundExecutionAllowed)
    }

    private func drain(generation: UUID) async {
        defer {
            if drainGeneration == generation {
                drainTask = nil
                drainGeneration = nil
            }
        }

        while canExecute, !Task.isCancelled, drainGeneration == generation {
            guard let job = try? await nextPendingJob() else { return }

            switch admissionPolicy.evaluate() {
            case .admit:
                break
            case let .deferInference(reason):
                var job = job
                job.lastError = reason
                job.updatedAt = now()
                _ = try? await repository.upsertJob(job, at: job.updatedAt)
                return
            case .lockedPendingPurchase:
                var job = job
                job.lastError = "lockedPendingPurchase"
                job.updatedAt = now()
                _ = try? await repository.upsertJob(job, at: job.updatedAt)
                return
            }

            let claimedAt = now()
            guard let lease = try? await repository.claimTranscriptionJob(
                id: job.id,
                at: claimedAt
            ) else { return }
            do {
                try await execute(lease)
            } catch let rejection as InferenceLifecycleGate.Rejection {
                let reason = rejection == .appIsBackgrounded
                    ? "deferredUntilForeground"
                    : "deferredUntilMetalAvailable"
                _ = try? await repository.finishExecutionLease(
                    lease,
                    state: .pending,
                    lastError: reason,
                    terminationReason: reason,
                    at: now()
                )
                // Background must stop Metal submission. A transient metalBusy
                // leaves the job pending and continues so another Recording's
                // work is not stranded behind a contended gate.
                if rejection == .appIsBackgrounded {
                    return
                }
                await Task.yield()
                continue
            } catch {
                if error is JobExecutionLeaseError {
                    return
                }
                if Task.isCancelled || !canExecute {
                    let reason = isInBackground ? "deferredUntilForeground" : "executionCancelled"
                    _ = try? await repository.finishExecutionLease(
                        lease,
                        state: .pending,
                        lastError: reason,
                        terminationReason: reason,
                        at: now()
                    )
                    return
                }

                let finished = try? await repository.finishExecutionLease(
                    lease,
                    state: .failed,
                    lastError: error.localizedDescription,
                    terminationReason: "executorFailed",
                    at: now()
                )
                if finished != nil, let handler = outcomeHandlers.removeValue(forKey: job.id) {
                    await handler(.init(
                        recordingID: job.recordingID,
                        chunkID: job.chunkID,
                        processingRangeID: job.processingRangeID,
                        state: .failed(message: error.localizedDescription)
                    ))
                }
                continue
            }

            guard (try? await repository.finishExecutionLease(
                lease,
                state: .completed,
                at: now()
            )) != nil else {
                // A replacement attempt owns the job; discard this late result.
                return
            }
            if let handler = outcomeHandlers.removeValue(forKey: job.id) {
                await handler(.init(
                    recordingID: job.recordingID,
                    chunkID: job.chunkID,
                    processingRangeID: job.processingRangeID,
                    state: .completed
                ))
            }
        }
    }

    private func suspendCurrentDrain(reason: String) async {
        let task = drainTask
        let generation = drainGeneration
        drainTask?.cancel()
        _ = try? await repository.invalidateRunningTranscriptionLeases(
            reason: reason,
            at: now()
        )
        await task?.value
        if drainGeneration == generation {
            drainTask = nil
            drainGeneration = nil
        }
    }
}
