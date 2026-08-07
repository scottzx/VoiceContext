import Foundation

/// Persists and serializes local transcription work. It never starts Metal
/// inference in the background: unfinished work remains pending until the app
/// is foregrounded again, including after process recovery.
actor ForegroundTranscriptionScheduler {
    struct Outcome: Sendable, Equatable {
        enum State: Sendable, Equatable {
            case completed
            case failed(message: String)
        }

        let recordingID: UUID
        let state: State
    }

    typealias Executor = @Sendable (UUID) async throws -> Void
    typealias OutcomeHandler = @Sendable (Outcome) async -> Void

    private let repository: RecordingRepository
    private let execute: Executor
    private let now: @Sendable () -> Date
    private var acceptsForegroundWork = true
    private var drainTask: Task<Void, Never>?
    private var restartAfterCurrentDrain = false
    private var outcomeHandlers: [UUID: OutcomeHandler] = [:]

    init(
        repository: RecordingRepository,
        now: @escaping @Sendable () -> Date = Date.init,
        execute: @escaping Executor
    ) {
        self.repository = repository
        self.now = now
        self.execute = execute
    }

    /// Adds a durable transcription job. The caller supplies the presentation
    /// callback because the scheduler deliberately has no UI dependency.
    func enqueue(
        recordingID: UUID,
        onOutcome: @escaping OutcomeHandler
    ) async throws {
        let jobs = try await repository.jobs(recordingID: recordingID)
        if let existing = jobs.last(where: { $0.kind == .transcription }) {
            outcomeHandlers[existing.id] = onOutcome
            guard existing.state != .completed else { return }
            if existing.state == .failed {
                try await retry(job: existing)
            }
        } else {
            let date = now()
            let job = RecordingJob(
                id: UUID(),
                recordingID: recordingID,
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
        onOutcome: @escaping OutcomeHandler
    ) async throws {
        let jobs = try await repository.jobs(recordingID: recordingID)
        guard let job = jobs.last(where: { $0.kind == .transcription }) else {
            return try await enqueue(recordingID: recordingID, onOutcome: onOutcome)
        }
        outcomeHandlers[job.id] = onOutcome
        try await retry(job: job)
        startDrainingIfPossible()
    }

    /// A running Metal job is interrupted, rather than failed, when the app
    /// backgrounds. Its pending record retains the retryable work item.
    func enteredBackground() {
        acceptsForegroundWork = false
        drainTask?.cancel()
    }

    func enteredForeground() {
        acceptsForegroundWork = true
        if drainTask != nil {
            restartAfterCurrentDrain = true
            return
        }
        startDrainingIfPossible()
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
                job.updatedAt = now()
                try await repository.upsertJob(job, at: job.updatedAt)
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

    private func retry(job: RecordingJob) async throws {
        var pending = job
        pending.state = .pending
        pending.lastError = nil
        pending.updatedAt = now()
        try await repository.upsertJob(pending, at: pending.updatedAt)
    }

    private func startDrainingIfPossible() {
        guard acceptsForegroundWork, drainTask == nil else { return }
        drainTask = Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        defer {
            drainTask = nil
            let shouldRestart = restartAfterCurrentDrain
            restartAfterCurrentDrain = false
            if acceptsForegroundWork, shouldRestart {
                startDrainingIfPossible()
            }
        }

        while acceptsForegroundWork, !Task.isCancelled {
            guard var job = try? await repository.jobs(
                kind: .transcription,
                states: [.pending]
            ).first else { return }

            job.state = .running
            job.attemptCount += 1
            job.lastError = nil
            job.updatedAt = now()
            do {
                try await repository.upsertJob(job, at: job.updatedAt)
                try await execute(job.recordingID)
            } catch {
                if Task.isCancelled || !acceptsForegroundWork {
                    job.state = .pending
                    job.lastError = "deferredUntilForeground"
                    job.updatedAt = now()
                    _ = try? await repository.upsertJob(job, at: job.updatedAt)
                    return
                }

                job.state = .failed
                job.lastError = error.localizedDescription
                job.updatedAt = now()
                _ = try? await repository.upsertJob(job, at: job.updatedAt)
                if let handler = outcomeHandlers.removeValue(forKey: job.id) {
                    await handler(.init(
                        recordingID: job.recordingID,
                        state: .failed(message: error.localizedDescription)
                    ))
                }
                continue
            }

            job.state = .completed
            job.lastError = nil
            job.updatedAt = now()
            do {
                try await repository.upsertJob(job, at: job.updatedAt)
            } catch {
                // The executor may have succeeded, but completion is not
                // durable. Leave the job pending for a truthful retry.
                job.state = .pending
                job.lastError = error.localizedDescription
                _ = try? await repository.upsertJob(job, at: now())
                return
            }
            if let handler = outcomeHandlers.removeValue(forKey: job.id) {
                await handler(.init(recordingID: job.recordingID, state: .completed))
            }
        }
    }
}
