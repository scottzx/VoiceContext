import BackgroundTasks
import Foundation
import Observation

/// User choice for iOS 26 continued processing. This is an app preference,
/// not a claim that iOS grants permanent background runtime.
nonisolated struct BackgroundTranscriptionPreferences {
    static let enabledKey = "transcription.continuedBackgroundProcessingEnabled"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.enabledKey) }
    }
}

/// A scheduler-independent progress value used by the BackgroundTasks bridge.
/// Keeping this value small makes the iOS 26 integration testable without
/// trying to manufacture system-owned `BGTask` instances.
nonisolated struct BackgroundTranscriptionQueueProgress: Equatable, Sendable {
    let pendingCount: Int
    let runningCount: Int
    let completedCount: Int
    let failedCount: Int

    init(
        pendingCount: Int,
        runningCount: Int,
        completedCount: Int,
        failedCount: Int
    ) {
        self.pendingCount = max(0, pendingCount)
        self.runningCount = max(0, runningCount)
        self.completedCount = max(0, completedCount)
        self.failedCount = max(0, failedCount)
    }

    var totalCount: Int {
        pendingCount + runningCount + completedCount + failedCount
    }

    var remainingCount: Int {
        pendingCount + runningCount
    }

    var completedUnitCount: Int64 {
        Int64(completedCount + failedCount)
    }

    var totalUnitCount: Int64 {
        Int64(max(1, totalCount))
    }

    var finishedSuccessfully: Bool {
        remainingCount == 0 && failedCount == 0
    }
}

/// Bridges the durable transcription queue to iOS 26's user-visible continued
/// processing task. It never owns transcription truth: expiration asks the
/// scheduler to invalidate its current lease and return the job to `pending`.
/// iOS 18–25 simply never enter this bridge and retain foreground-only inference.
@MainActor
@Observable
final class BackgroundTranscriptionContinuation {
    enum State: Equatable, Sendable {
        case unavailable
        case disabled
        case idle
        case foregroundFallback(reason: String)
        case submitted
        case running(progress: BackgroundTranscriptionQueueProgress)
        case expired
    }

    typealias BackgroundPermissionHandler = @Sendable (Bool) async -> Void
    typealias ExpirationHandler = @Sendable (String) async -> Void
    typealias ProgressProvider = @Sendable () async -> BackgroundTranscriptionQueueProgress

    nonisolated static let taskIdentifierPrefix = "YiJie.speech_note.transcription"

    private(set) var state: State

    private let preferences: BackgroundTranscriptionPreferences
    private let setBackgroundExecutionAllowed: BackgroundPermissionHandler
    private let expireCurrentExecution: ExpirationHandler
    private let progressProvider: ProgressProvider
    private var submittedTaskIdentifier: String?
    private var activeSystemTask: BGTask?
    private var monitorTask: Task<Void, Never>?
    private var taskTotalUnitCount: Int64 = 1
    private var taskCompletedUnitCount: Int64 = 0
    private var failureCountAtSubmission = 0

    init(
        preferences: BackgroundTranscriptionPreferences = BackgroundTranscriptionPreferences(),
        setBackgroundExecutionAllowed: @escaping BackgroundPermissionHandler,
        expireCurrentExecution: @escaping ExpirationHandler,
        progressProvider: @escaping ProgressProvider
    ) {
        self.preferences = preferences
        self.setBackgroundExecutionAllowed = setBackgroundExecutionAllowed
        self.expireCurrentExecution = expireCurrentExecution
        self.progressProvider = progressProvider
        if #available(iOS 26.0, *) {
            state = preferences.isEnabled ? .idle : .disabled
        } else {
            state = .unavailable
        }
    }

    var isEnabled: Bool {
        preferences.isEnabled
    }

    var isExecutionRequested: Bool {
        switch state {
        case .submitted, .running:
            true
        default:
            false
        }
    }

    /// Synchronizes an `@AppStorage` setting change with an active system task.
    /// Turning the preference off never stops foreground transcription.
    func preferenceDidChange() async {
        guard #available(iOS 26.0, *) else {
            state = .unavailable
            return
        }
        if isEnabled {
            if activeSystemTask == nil { state = .idle }
        } else {
            await userStoppedAllTasks()
            state = .disabled
        }
    }

    /// Called only in direct response to an explicit action that starts or
    /// retries transcription (stop recording, import, or retry). Apple does
    /// not permit continued-processing requests for automatic maintenance.
    @discardableResult
    func beginUserInitiatedTask() async -> Bool {
        guard #available(iOS 26.0, *) else {
            state = .unavailable
            return false
        }
        guard preferences.isEnabled else {
            state = .disabled
            return false
        }
        let progress = await progressProvider()
        guard progress.remainingCount > 0 else {
            state = .idle
            return false
        }
        taskTotalUnitCount = Int64(max(1, progress.remainingCount))
        taskCompletedUnitCount = 0
        failureCountAtSubmission = progress.failedCount
        if activeSystemTask != nil || state == .submitted {
            return true
        }

        let taskIdentifier = "\(Self.taskIdentifierPrefix).\(UUID().uuidString)"
        guard BGTaskScheduler.supportedResources.contains(.gpu) else {
            state = .foregroundFallback(reason: "continuedTaskGPUUnavailable")
            return false
        }
        guard register(taskIdentifier: taskIdentifier) else {
            state = .foregroundFallback(reason: "continuedTaskRegistrationRejected")
            return false
        }

        let request = BGContinuedProcessingTaskRequest(
            identifier: taskIdentifier,
            title: "正在转写录音",
            subtitle: "本地处理，可返回应用查看进度"
        )
        // A queued request could start later without a fresh user action.
        // Immediate failure gives us an honest foreground-only fallback.
        request.strategy = .fail
        request.requiredResources = .gpu

        do {
            submittedTaskIdentifier = taskIdentifier
            try BGTaskScheduler.shared.submit(request)
            state = .submitted
            // Close the scene-transition race between successful submission
            // and delivery of the launch handler.
            await setBackgroundExecutionAllowed(true)
            return true
        } catch {
            submittedTaskIdentifier = nil
            state = .foregroundFallback(reason: Self.stableReason(for: error))
            return false
        }
    }

    /// Cancels system presentation after the user explicitly stops the queue.
    /// Durable jobs are transitioned by the scheduler, not by this bridge.
    func userStoppedAllTasks() async {
        guard let systemTask = activeSystemTask else {
            if #available(iOS 26.0, *), state == .submitted {
                if let submittedTaskIdentifier {
                    BGTaskScheduler.shared.cancel(
                        taskRequestWithIdentifier: submittedTaskIdentifier
                    )
                }
            }
            submittedTaskIdentifier = nil
            await setBackgroundExecutionAllowed(false)
            state = isEnabled ? .idle : .disabled
            return
        }
        monitorTask?.cancel()
        monitorTask = nil
        activeSystemTask = nil
        submittedTaskIdentifier = nil
        systemTask.expirationHandler = nil
        systemTask.setTaskCompleted(success: false)
        await setBackgroundExecutionAllowed(false)
        state = isEnabled ? .idle : .disabled
    }

    @available(iOS 26.0, *)
    private func register(taskIdentifier: String) -> Bool {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { [weak self] task in
            Task { @MainActor [weak self] in
                self?.accept(task: task)
            }
        }
    }

    @available(iOS 26.0, *)
    private func accept(task: BGTask) {
        guard let continuedTask = task as? BGContinuedProcessingTask else {
            submittedTaskIdentifier = nil
            task.setTaskCompleted(success: false)
            state = .foregroundFallback(reason: "unexpectedBackgroundTaskType")
            return
        }

        activeSystemTask = continuedTask
        continuedTask.progress.totalUnitCount = taskTotalUnitCount
        continuedTask.progress.completedUnitCount = 0
        continuedTask.expirationHandler = { [weak self, weak continuedTask] in
            Task { @MainActor [weak self, weak continuedTask] in
                guard let self, let continuedTask else { return }
                await self.expire(task: continuedTask)
            }
        }

        monitorTask?.cancel()
        monitorTask = Task { [weak self, weak continuedTask] in
            guard let self, let continuedTask else { return }
            await self.setBackgroundExecutionAllowed(true)
            while !Task.isCancelled {
                let progress = await self.progressProvider()
                guard self.activeSystemTask === continuedTask else { return }
                // Historical completed jobs do not belong to this system task.
                // Grow the denominator only if new work was explicitly added
                // while the same continued-processing task is active.
                let remaining = Int64(progress.remainingCount)
                let previouslyRemaining = self.taskTotalUnitCount - self.taskCompletedUnitCount
                if remaining > previouslyRemaining {
                    self.taskTotalUnitCount += remaining - previouslyRemaining
                }
                self.taskCompletedUnitCount = max(
                    self.taskCompletedUnitCount,
                    self.taskTotalUnitCount - remaining
                )
                continuedTask.progress.totalUnitCount = self.taskTotalUnitCount
                continuedTask.progress.completedUnitCount = self.taskCompletedUnitCount
                self.state = .running(progress: progress)

                if progress.remainingCount == 0 {
                    let succeeded = progress.failedCount == self.failureCountAtSubmission
                    await self.finish(task: continuedTask, success: succeeded)
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @available(iOS 26.0, *)
    private func expire(task: BGContinuedProcessingTask) async {
        guard activeSystemTask === task else { return }
        monitorTask?.cancel()
        monitorTask = nil
        // The scheduler invalidates the execution token before returning the
        // current job to pending, so a late inference result cannot commit.
        await expireCurrentExecution("backgroundTaskExpired")
        await setBackgroundExecutionAllowed(false)
        activeSystemTask = nil
        submittedTaskIdentifier = nil
        task.expirationHandler = nil
        task.setTaskCompleted(success: false)
        state = .expired
    }

    @available(iOS 26.0, *)
    private func finish(task: BGContinuedProcessingTask, success: Bool) async {
        guard activeSystemTask === task else { return }
        activeSystemTask = nil
        submittedTaskIdentifier = nil
        monitorTask = nil
        task.expirationHandler = nil
        task.setTaskCompleted(success: success)
        await setBackgroundExecutionAllowed(false)
        state = success ? .idle : .foregroundFallback(reason: "queueFinishedWithFailures")
    }

    private static func stableReason(for error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == BGTaskScheduler.errorDomain else {
            return "continuedTaskSubmissionFailed"
        }
        switch nsError.code {
        case BGTaskScheduler.Error.Code.unavailable.rawValue:
            return "continuedTaskUnavailable"
        case BGTaskScheduler.Error.Code.tooManyPendingTaskRequests.rawValue:
            return "continuedTaskQueueFull"
        case BGTaskScheduler.Error.Code.notPermitted.rawValue:
            return "continuedTaskNotPermitted"
        case BGTaskScheduler.Error.Code.immediateRunIneligible.rawValue:
            return "continuedTaskImmediateRunIneligible"
        default:
            return "continuedTaskSubmissionFailed"
        }
    }
}
