import Foundation

// UIKit/audio boundaries only. The capture predicate, execution policy,
// expiration handler, suspension wait and interruption guards are production.
struct HostLogger {
    func info(_ text: String) {}
    func warning(_ text: String) {}
}
let logger = HostLogger()
struct UIBackgroundTaskIdentifier: Equatable {
    let rawValue: Int
    static let invalid = Self(rawValue: -1)
}
@MainActor final class NotificationCenter {
    private final class Token: NSObject {}
    static let `default` = NotificationCenter()
    private var callbacks: [ObjectIdentifier: (Notification) -> Void] = [:]
    func addObserver(forName: Notification.Name, object: Any?, queue: OperationQueue?,
                     using callback: @escaping (Notification) -> Void) -> NSObjectProtocol {
        let token = Token()
        callbacks[ObjectIdentifier(token)] = callback
        return token
    }
    func removeObserver(_ token: NSObjectProtocol) { callbacks.removeValue(forKey: ObjectIdentifier(token)) }
    func post(name: Notification.Name, object: Any?) {
        for callback in Array(callbacks.values) { callback(Notification(name: name, object: object)) }
    }
}
@MainActor final class UIApplication {
    enum State { case active, inactive, background }
    static let shared = UIApplication()
    static let willEnterForegroundNotification = Notification.Name("HostWillEnterForeground")
    var applicationState: State = .background
    var backgroundTimeRemaining: Double = 20
    var nextID = 0
    var handlers: [Int: () -> Void] = [:]
    var ended: [Int] = []
    func beginBackgroundTask(withName: String, expirationHandler: @escaping () -> Void) -> UIBackgroundTaskIdentifier {
        nextID += 1
        handlers[nextID] = expirationHandler
        return .init(rawValue: nextID)
    }
    func endBackgroundTask(_ id: UIBackgroundTaskIdentifier) {
        handlers.removeValue(forKey: id.rawValue)
        ended.append(id.rawValue)
    }
    func expire(_ id: UIBackgroundTaskIdentifier) { handlers[id.rawValue]?() }
}
@MainActor final class HostVoiceInput { var isRunning = false }
@MainActor final class XiaolanVoiceController {
    static let shared = XiaolanVoiceController()
    var isEnabled = false
    var isPaused = false
    var input: HostVoiceInput? = HostVoiceInput()
}
@MainActor final class BackgroundKeepAliveManager {
    static let shared = BackgroundKeepAliveManager()
    var enhancedBackgroundEnabled = false
    var backgroundSpeakEnabled = false
    var silentAudioIsPlaying = false
}
@MainActor final class BackgroundInterruptionTracker {
    static let shared = BackgroundInterruptionTracker()
    var wasInterrupted = false
    var interruptionCount = 0
    var remindInterval = 1
    var showBanner = false
}
@MainActor final class SessionActivityTracker {
    static let shared = SessionActivityTracker()
    var activeSessions: Set<String> = []
}
final class HostToolBlock {
    enum Kind { case browserTool, shellTool }
    enum Status { case streaming, running, finished }
    var kind: Kind = .browserTool
    var toolStatus: Status = .running
    var toolStartTime: Date? = Date(timeIntervalSinceNow: -120)
    var wasBackgroundSuspended = false
}
struct HostMessage {
    enum Role { case user, assistant }
    var role: Role = .assistant
    var blocks: [HostToolBlock]
}
@MainActor final class AIChatViewModel {
    static var liveBackgroundTaskCount = 0
    static let bgHintBrowserThreshold: Double = 30
    static func noteBackgroundTaskBegan() { liveBackgroundTaskCount += 1 }
    static func noteBackgroundTaskEnded() { liveBackgroundTaskCount -= 1 }
    static func diagTimestamp(_ date: Date) -> String { "host" }
    static func diagAppStateName() -> String { "host" }
    var sessionId: String? = "voice-background-host"
    var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    var backgroundSuspended = false
    var foregroundContinuation: CheckedContinuation<Void, Never>?
    var foregroundObserver: NSObjectProtocol?
    var bgHintBackgroundEntryDate: Date? = Date()
    var messages = [HostMessage(blocks: [HostToolBlock()])]
    var stopCount = 0
    func startBackgroundStatusTimer() {}
    func stopCurrentCommand() { stopCount += 1 }
    func endBackgroundProcessing() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            Self.noteBackgroundTaskEnded()
            backgroundTaskID = .invalid
        }
    }
}

@main struct VoiceBackgroundExecutionTest {
    @MainActor static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }
    @MainActor static func reset() {
        let voice = XiaolanVoiceController.shared
        voice.isEnabled = false
        voice.isPaused = false
        voice.input?.isRunning = false
        let manager = BackgroundKeepAliveManager.shared
        manager.enhancedBackgroundEnabled = false
        manager.backgroundSpeakEnabled = false
        let tracker = BackgroundInterruptionTracker.shared
        tracker.wasInterrupted = false
        tracker.interruptionCount = 0
        tracker.showBanner = false
        UIApplication.shared.applicationState = .background
    }
    @MainActor static func assertExpiryContinues(_ label: String) async {
        let vm = AIChatViewModel()
        vm.beginBackgroundProcessing()
        let oldID = vm.backgroundTaskID
        UIApplication.shared.expire(oldID)
        expect(vm.backgroundTaskID != .invalid && vm.backgroundTaskID != oldID, "\(label): finite grant must re-arm")
        expect(UIApplication.shared.ended.contains(oldID.rawValue), "\(label): expiring grant must end")
        expect(!vm.backgroundSuspended && vm.stopCount == 0, "\(label): must not stop current command")
        expect(!vm.messages[0].blocks[0].wasBackgroundSuspended, "\(label): no false tool suspension hint")
        vm.backgroundSuspended = true
        await vm.waitIfBackgroundSuspended()
        expect(vm.foregroundContinuation == nil, "\(label): loop must not wait for foreground")
        vm.markLongBackgroundBrowserTasks()
        expect(!vm.messages[0].blocks[0].wasBackgroundSuspended, "\(label): no false long-browser hint")
        BackgroundInterruptionTracker.shared.recordInterruption()
        BackgroundInterruptionTracker.shared.checkOnForeground()
        expect(!BackgroundInterruptionTracker.shared.showBanner, "\(label): no false interruption banner")
        vm.endBackgroundProcessing()
    }
    @MainActor static func assertExpirySuspends(_ label: String) async {
        let vm = AIChatViewModel()
        vm.beginBackgroundProcessing()
        UIApplication.shared.expire(vm.backgroundTaskID)
        expect(vm.backgroundSuspended && vm.stopCount == 1, "\(label): preserve ordinary suspension")
        expect(vm.backgroundTaskID == .invalid, "\(label): expired finite grant must end")
        expect(vm.messages[0].blocks[0].wasBackgroundSuspended, "\(label): preserve actual interruption hint")
        BackgroundInterruptionTracker.shared.checkOnForeground()
        expect(BackgroundInterruptionTracker.shared.showBanner, "\(label): preserve ordinary banner")
        vm.messages[0].blocks[0].wasBackgroundSuspended = false
        vm.markLongBackgroundBrowserTasks()
        expect(vm.messages[0].blocks[0].wasBackgroundSuspended, "\(label): preserve long-browser hint")
        var finished = false
        let wait = Task { @MainActor in
            await vm.waitIfBackgroundSuspended()
            finished = true
        }
        for _ in 0..<20 where vm.foregroundContinuation == nil { await Task.yield() }
        expect(vm.foregroundContinuation != nil && !finished, "\(label): loop waits while backgrounded")
        UIApplication.shared.applicationState = .active
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        await wait.value
        expect(finished && !vm.backgroundSuspended && vm.backgroundTaskID != .invalid, "\(label): foreground resumes and re-arms")
        vm.endBackgroundProcessing()
    }
    @MainActor static func main() async {
        reset()
        let voice = XiaolanVoiceController.shared
        let manager = BackgroundKeepAliveManager.shared
        voice.isEnabled = true
        voice.input?.isRunning = true
        expect(voice.isCapturingVoice, "Actual enabled microphone is capturing")
        #if VOICE_AGENT_FUSION
        expect(manager.canContinueBackgroundExecution, "Fusion microphone supplies background execution")
        await assertExpiryContinues("active microphone")
        #else
        expect(!manager.canContinueBackgroundExecution, "Non-fusion retains old policy")
        await assertExpirySuspends("non-fusion microphone")
        #endif

        reset()
        voice.isEnabled = true
        voice.isPaused = true
        voice.input?.isRunning = true
        expect(!voice.isCapturingVoice && !manager.canContinueBackgroundExecution, "Paused reservation cannot supply execution")
        await assertExpirySuspends("paused reservation")

        reset()
        voice.isEnabled = true
        voice.input?.isRunning = false
        expect(!manager.canContinueBackgroundExecution, "Stopped capture cannot supply execution")
        await assertExpirySuspends("stopped capture")

        reset()
        voice.input?.isRunning = true
        expect(!voice.isCapturingVoice && !manager.canContinueBackgroundExecution, "Disabled voice ignores stale running input")
        await assertExpirySuspends("disabled voice")

        reset()
        manager.enhancedBackgroundEnabled = true
        expect(!manager.canContinueBackgroundExecution, "Enhanced switch alone remains ineffective")
        manager.backgroundSpeakEnabled = true
        expect(manager.canContinueBackgroundExecution, "Traditional effective keep-alive is preserved")
        await assertExpiryContinues("traditional keep-alive")
        expect(AIChatViewModel.liveBackgroundTaskCount == 0, "No leaked finite background grants")
        #if VOICE_AGENT_FUSION
        print("voice background execution (fusion): PASS")
        #else
        print("voice background execution (standalone): PASS")
        #endif
    }
}
