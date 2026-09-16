import ActivityKit
import AppIntents
import Foundation
import os
#if WIDGET_EXTENSION
import notify
#endif

/// Darwin notify names shared with the app-side command center. Widget
/// `perform()` is only a fallback; `LiveActivityIntent` should run in-app.
enum RecordingLiveActivityCommand: String, CaseIterable, Sendable {
    case stop = "YiJie.speech_note.liveActivity.stop"
    case pause = "YiJie.speech_note.liveActivity.pause"
    case resume = "YiJie.speech_note.liveActivity.resume"
}

private enum RecordingLiveActivityIntentLog {
    static let logger = Logger(subsystem: "YiJie.speech_note", category: "LiveActivityIntent")
}

/// One type, compiled into both the app and the widget. Authentication must
/// be the `alwaysAllowed` *literal* on the intent type — the metadata extractor
/// ignores indirection, and a locked Live Activity button stays inert without
/// an explicit policy.
nonisolated struct StopRecordingLiveActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "停止录音"
    static var description: IntentDescription = IntentDescription("停止当前录音并保存")
    static var openAppWhenRun: Bool { false }
    static var isDiscoverable: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    init() {}

    func perform() async throws -> some IntentResult {
        await RecordingLiveActivityIntentAction.perform(.stop)
        return .result()
    }
}

nonisolated struct PauseRecordingLiveActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "暂停录音"
    static var description: IntentDescription = IntentDescription("暂停当前录音")
    static var openAppWhenRun: Bool { false }
    static var isDiscoverable: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    init() {}

    func perform() async throws -> some IntentResult {
        await RecordingLiveActivityIntentAction.perform(.pause)
        return .result()
    }
}

nonisolated struct ResumeRecordingLiveActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "继续录音"
    static var description: IntentDescription = IntentDescription("从中断或暂停处继续录音")
    static var openAppWhenRun: Bool { false }
    static var isDiscoverable: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    init() {}

    func perform() async throws -> some IntentResult {
        await RecordingLiveActivityIntentAction.perform(.resume)
        return .result()
    }
}

#if !WIDGET_EXTENSION
extension StopRecordingLiveActivityIntent: AudioRecordingIntent {}
extension PauseRecordingLiveActivityIntent: AudioRecordingIntent {}
extension ResumeRecordingLiveActivityIntent: AudioRecordingIntent {}
#endif

enum RecordingLiveActivityIntentAction {
    static func perform(_ command: RecordingLiveActivityCommand) async {
        RecordingLiveActivityIntentLog.logger.notice(
            "Live Activity intent \(command.rawValue, privacy: .public)"
        )
        #if WIDGET_EXTENSION
        command.rawValue.withCString { _ = notify_post($0) }
        await applyOptimisticContentState(for: command)
        #else
        await RecordingLiveActivityCommandCenter.shared.perform(command)
        #endif
    }

    #if WIDGET_EXTENSION
    private static func applyOptimisticContentState(for command: RecordingLiveActivityCommand) async {
        for activity in Activity<RecordingActivityAttributes>.activities {
            switch command {
            case .stop:
                await activity.end(nil, dismissalPolicy: .immediate)
            case .pause:
                let startedAt = activity.content.state.startedAt
                await activity.update(
                    .init(
                        state: .init(
                            isRecording: false,
                            isPaused: true,
                            startedAt: startedAt,
                            isInterrupted: false
                        ),
                        staleDate: nil
                    )
                )
            case .resume:
                let startedAt = activity.content.state.startedAt
                await activity.update(
                    .init(
                        state: .init(
                            isRecording: true,
                            isPaused: false,
                            startedAt: startedAt,
                            isInterrupted: false
                        ),
                        staleDate: nil
                    )
                )
            }
        }
    }
    #endif
}
