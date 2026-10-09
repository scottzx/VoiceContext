import Combine
import Foundation

nonisolated private let modelDownloadCancelledKey = "transcriptionModelsDownloadCancelled"

nonisolated struct ModelDownloadResumeRecord: Codable {
    let data: Data
    let allowCellular: Bool?

    func data(forCellularChoice choice: Bool) -> Data? {
        allowCellular == choice ? data : nil
    }
}

@MainActor
@objc(YimaTranscriptionModelDownloads)
public final class TranscriptionModelDownloadService: NSObject, ObservableObject {
    nonisolated public enum State: String, Sendable {
        case notDownloaded, waiting, downloading, verifying, ready, failed
    }

    @objc public static let shared = TranscriptionModelDownloadService()
    @Published public private(set) var state: State = .notDownloaded
    @Published public private(set) var downloadedBytes: Int64 = 0
    @Published public private(set) var totalBytes: Int64 = 294_462_733
    @Published public private(set) var errorMessage: String?
    private var cancelled = UserDefaults.standard.bool(forKey: modelDownloadCancelledKey)
    private var backgroundCompletion: (() -> Void)?
    private lazy var worker = ModelDownloadWorker { [weak self] snapshot in
        DispatchQueue.main.async { [weak self] in self?.apply(snapshot) }
    } finishedEvents: { [weak self] in
        DispatchQueue.main.async { [weak self] in
            let completion = self?.backgroundCompletion
            self?.backgroundCompletion = nil
            completion?()
        }
    }

    private override init() { super.init() }

    public var isReady: Bool { state == .ready && TranscriptionModelStore.isReady }
    public var progress: Double { totalBytes > 0 ? min(1, Double(downloadedBytes) / Double(totalBytes)) : 0 }

    /// Called only by an explicit download / retry action in the UI.
    public func startDownload(allowCellular: Bool = false) {
        cancelled = false
        UserDefaults.standard.set(false, forKey: modelDownloadCancelledKey)
        errorMessage = nil
        state = .verifying
        worker.start(allowCellular: allowCellular)
    }

    public func cancelDownload() {
        cancelled = true
        UserDefaults.standard.set(true, forKey: modelDownloadCancelledKey)
        errorMessage = nil
        state = .notDownloaded
        worker.cancel()
    }

    /// Reconnects existing system tasks and verifies local/staged files.
    /// This never creates a download task.
    public func restore() { worker.restore() }

    @objc public func handleBackgroundEvents(identifier: String, completionHandler: @escaping () -> Void) -> Bool {
        guard identifier == ModelDownloadWorker.sessionIdentifier else { return false }
        backgroundCompletion = completionHandler
        worker.restore()
        return true
    }

    private func apply(_ snapshot: ModelDownloadWorker.Snapshot) {
        let becameReady = state != .ready && snapshot.state == .ready && !cancelled
        state = cancelled ? .notDownloaded : snapshot.state
        downloadedBytes = snapshot.downloadedBytes
        totalBytes = snapshot.totalBytes
        errorMessage = cancelled ? nil : snapshot.error
        if becameReady {
            NotificationCenter.default.post(name: .transcriptionModelsDidBecomeReady, object: self)
        }
    }
}

/// Delegate callbacks and filesystem work share a serial queue. Temporary
/// downloads are moved synchronously before their delegate callback returns.
nonisolated private final class ModelDownloadWorker: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct Snapshot: Sendable {
        let state: TranscriptionModelDownloadService.State
        let downloadedBytes: Int64
        let totalBytes: Int64
        let error: String?
    }

    static let sessionIdentifier = (Bundle.main.bundleIdentifier ?? "YiJie.speech-note") + ".transcription-models"
    private let queue = DispatchQueue(label: "Yima.TranscriptionModelDownloads")
    private let installation = TranscriptionModelStore.installation
    private let changed: @Sendable (Snapshot) -> Void
    private let finishedEvents: @Sendable () -> Void
    private let cancelLock = NSLock()
    private var stopRequested = UserDefaults.standard.bool(forKey: modelDownloadCancelledKey)
    private var taskArtifacts: [Int: String] = [:]
    private var received: [String: Int64] = [:]
    private var failure: String?
    private var restoring = false
    private var startAfterRestore: Bool?
    private var cancelling = false
    private var startAfterCancel: Bool?
    private var ignoredTasks = Set<Int>()
    private var eventsPending = false
    private var generation = 0
    private var cancellationSequence = 0
    private var storedSession: URLSession?

    private var session: URLSession {
        if let storedSession { return storedSession }
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        // Each task's URLRequest holds the user's Wi-Fi / cellular choice.
        config.allowsCellularAccess = true
        let delegates = OperationQueue()
        delegates.maxConcurrentOperationCount = 1
        delegates.underlyingQueue = queue
        let created = URLSession(configuration: config, delegate: self, delegateQueue: delegates)
        storedSession = created
        return created
    }

    init(changed: @escaping @Sendable (Snapshot) -> Void, finishedEvents: @escaping @Sendable () -> Void) {
        self.changed = changed
        self.finishedEvents = finishedEvents
    }

    private var stopped: Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return stopRequested
    }

    private func setStopped(_ value: Bool) {
        cancelLock.lock()
        stopRequested = value
        cancelLock.unlock()
    }

    func restore() { queue.async { self.restoreOnQueue() } }

    func start(allowCellular: Bool) {
        setStopped(false)
        queue.async {
            self.generation += 1
            self.failure = nil
            if self.cancelling {
                self.startAfterCancel = allowCellular
            } else {
                self.startAfterRestore = allowCellular
                self.restoreOnQueue()
            }
        }
    }

    func cancel() {
        setStopped(true)
        queue.async {
            self.generation += 1
            let generation = self.generation
            self.cancellationSequence += 1
            let cancellationSequence = self.cancellationSequence
            self.startAfterRestore = nil
            self.startAfterCancel = nil
            self.cancelling = true
            self.session.getAllTasks { tasks in
                self.queue.async {
                    // Only the latest cancel may clear mappings or restart.
                    // An earlier getAllTasks response can arrive afterwards.
                    guard cancellationSequence == self.cancellationSequence else { return }
                    for task in tasks {
                        guard let download = task as? URLSessionDownloadTask,
                              let artifact = self.artifact(for: task) else { continue }
                        self.ignoredTasks.insert(task.taskIdentifier)
                        download.cancel { data in
                            guard let data else { return }
                            self.queue.async {
                                guard self.stopped, generation == self.generation else { return }
                                self.saveResume(data, artifactID: artifact.id, task: task)
                            }
                        }
                    }
                    self.taskArtifacts.removeAll()
                    self.received.removeAll()
                    self.failure = nil
                    self.cancelling = false
                    if let allowCellular = self.startAfterCancel, !self.stopped {
                        self.startAfterCancel = nil
                        self.validateLocalFiles()
                        self.startMissing(allowCellular: allowCellular)
                    } else { self.emit() }
                    self.finishEventsIfPossible()
                }
            }
        }
    }

    private func restoreOnQueue() {
        guard !restoring else { return }
        restoring = true
        let generation = generation
        session.getAllTasks { tasks in
            self.queue.async {
                self.restoring = false
                guard generation == self.generation else {
                    // A user action superseded this task snapshot. Fetch a
                    // current one unless a cancellation is already doing so.
                    if !self.cancelling { self.restoreOnQueue() }
                    return
                }
                self.taskArtifacts.removeAll()
                self.received.removeAll()
                for task in tasks {
                    guard task.state == .running || task.state == .suspended else { continue }
                    guard !self.ignoredTasks.contains(task.taskIdentifier), let artifact = self.artifact(for: task) else {
                        task.cancel()
                        continue
                    }
                    if let choice = self.startAfterRestore, task.originalRequest?.allowsCellularAccess != choice {
                        self.ignoredTasks.insert(task.taskIdentifier)
                        task.cancel()
                        continue
                    }
                    self.taskArtifacts[task.taskIdentifier] = artifact.id
                    self.received[artifact.id] = max(0, task.countOfBytesReceived)
                    if task.state == .suspended, !self.stopped, !self.cancelling { task.resume() }
                }
                self.validateLocalFiles()
                if self.stopped, !tasks.isEmpty { self.cancel() }
                if let allowCellular = self.startAfterRestore, !self.stopped, !self.cancelling {
                    self.startAfterRestore = nil
                    self.startMissing(allowCellular: allowCellular)
                } else {
                    self.emit()
                }
                self.finishEventsIfPossible()
            }
        }
    }

    private func validateLocalFiles() {
        guard let installation else {
            failure = TranscriptionModelError.missingManifest.localizedDescription
            return
        }
        do { try installation.prepareDirectories() }
        catch { failure = downloadMessage(for: error); return }
        emit(state: .verifying)
        for artifact in installation.artifacts {
            if installation.isVerified(artifact) { continue }
            try? installation.validateInstalled(artifact)
            guard !installation.isVerified(artifact), !stopped else { continue }
            let staged = installation.staging.appendingPathComponent(artifact.relativePath)
            if FileManager.default.fileExists(atPath: staged.path) {
                do { try installation.publishStaged(artifact) }
                catch {
                    // A bad staged file must not strand verification forever.
                    try? FileManager.default.removeItem(at: staged)
                    failure = downloadMessage(for: error)
                }
            }
        }
    }

    private func startMissing(allowCellular: Bool) {
        guard let installation, !stopped, !cancelling else { emit(); return }
        do {
            try installation.prepareDirectories()
            let missing = installation.artifacts.filter { !installation.isVerified($0) }
            let newDownloads = missing.filter { !taskArtifacts.values.contains($0.id) }
            guard !newDownloads.isEmpty else { emit(); return }
            let remaining = newDownloads.reduce(Int64(0)) { $0 + ($1.sizeBytes ?? 0) }
            let values = try installation.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let available = values.volumeAvailableCapacityForImportantUsage, available < remaining + 32 * 1_024 * 1_024 {
                throw TranscriptionModelError.insufficientSpace
            }
            failure = nil
            for artifact in newDownloads {
                guard let url = artifact.downloadURL else { continue }
                let task: URLSessionDownloadTask
                let resume = resumeURL(id: artifact.id)
                // Resume data embeds its original request's network policy.
                // Reuse it only when the policy matches this explicit action.
                if let data = try? Data(contentsOf: resume),
                   let record = try? JSONDecoder().decode(ModelDownloadResumeRecord.self, from: data),
                   let resumeData = record.data(forCellularChoice: allowCellular) {
                    task = session.downloadTask(withResumeData: resumeData)
                } else {
                    var request = URLRequest(url: url)
                    request.allowsCellularAccess = allowCellular
                    request.allowsExpensiveNetworkAccess = allowCellular
                    task = session.downloadTask(with: request)
                }
                try? FileManager.default.removeItem(at: resume)
                task.taskDescription = artifact.id
                task.countOfBytesClientExpectsToReceive = artifact.sizeBytes ?? NSURLSessionTransferSizeUnknown
                taskArtifacts[task.taskIdentifier] = artifact.id
                received[artifact.id] = 0
                task.resume()
            }
            emit()
        } catch {
            failure = downloadMessage(for: error)
            emit()
        }
    }

    private func resumeURL(id: String) -> URL {
        let digest = installation?.artifacts.first(where: { $0.id == id })?.sha256 ?? "unknown"
        return (installation?.staging ?? FileManager.default.temporaryDirectory).appendingPathComponent(id + "." + digest + ".resume.json")
    }

    private func saveResume(_ data: Data, artifactID: String, task: URLSessionTask) {
        try? installation?.prepareDirectories()
        let record = ModelDownloadResumeRecord(data: data, allowCellular: task.originalRequest?.allowsCellularAccess)
        if let encoded = try? JSONEncoder().encode(record) {
            try? encoded.write(to: resumeURL(id: artifactID), options: .atomic)
        }
    }

    private func artifact(for task: URLSessionTask) -> ModelArtifact? {
        guard let id = taskArtifacts[task.taskIdentifier] ?? task.taskDescription else { return nil }
        return installation?.artifacts.first(where: { $0.id == id })
    }

    private func emit(state: TranscriptionModelDownloadService.State? = nil) {
        let artifacts = installation?.artifacts ?? []
        let total = artifacts.reduce(Int64(0)) { $0 + ($1.sizeBytes ?? 0) }
        let downloaded = artifacts.reduce(Int64(0)) { sum, artifact in
            let size = artifact.sizeBytes ?? 0
            return sum + (installation?.isVerified(artifact) == true ? size : min(size, received[artifact.id] ?? 0))
        }
        let next: TranscriptionModelDownloadService.State
        if stopped { next = .notDownloaded }
        else if let state { next = state }
        else if installation?.isReady == true { next = .ready }
        else if !taskArtifacts.isEmpty { next = received.values.contains(where: { $0 > 0 }) ? .downloading : .waiting }
        else if failure != nil { next = .failed }
        else { next = .notDownloaded }
        changed(Snapshot(state: next, downloadedBytes: downloaded, totalBytes: total, error: failure))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard !ignoredTasks.contains(downloadTask.taskIdentifier), !stopped,
              let artifact = artifact(for: downloadTask) else { return }
        taskArtifacts[downloadTask.taskIdentifier] = artifact.id
        received[artifact.id] = totalBytesWritten
        emit()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let installation, !ignoredTasks.contains(downloadTask.taskIdentifier),
              let artifact = artifact(for: downloadTask) else { return }
        taskArtifacts[downloadTask.taskIdentifier] = artifact.id
        do {
            try installation.prepareDirectories()
            guard let response = downloadTask.response as? HTTPURLResponse,
                  response.statusCode == 200 || response.statusCode == 206 else {
                throw TranscriptionModelError.httpStatus((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            let staged = installation.staging.appendingPathComponent(artifact.relativePath)
            if FileManager.default.fileExists(atPath: staged.path) { try FileManager.default.removeItem(at: staged) }
            try FileManager.default.moveItem(at: location, to: staged)
            if !stopped {
                emit(state: .verifying)
                try installation.publishStaged(artifact)
            }
        } catch {
            failure = downloadMessage(for: error)
            received[artifact.id] = 0
            let staged = installation.staging.appendingPathComponent(artifact.relativePath)
            try? FileManager.default.removeItem(at: staged)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if ignoredTasks.remove(task.taskIdentifier) != nil { return }
        guard let artifact = artifact(for: task) else { return }
        let id = artifact.id
        taskArtifacts.removeValue(forKey: task.taskIdentifier)
        if let error, !stopped {
            failure = downloadMessage(for: error)
            if let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                saveResume(resume, artifactID: id, task: task)
            }
            received[id] = 0
        }
        emit()
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // Delegate queue is serial: every preceding staging/hash operation has
        // finished before UIKit is allowed to suspend the app again.
        eventsPending = true
        finishEventsIfPossible()
    }

    private func finishEventsIfPossible() {
        guard eventsPending, !restoring, !cancelling else { return }
        eventsPending = false
        emit()
        finishedEvents()
    }

    private func downloadMessage(for error: Error) -> String {
        error is ModelIntegrityError ? L("模型文件不完整，请重新下载。") : error.localizedDescription
    }
}
