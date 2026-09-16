import Foundation
import os
import notify

@MainActor
protocol RecordingLiveActivityCommandHandling: AnyObject {
    func handleLiveActivityCommand(_ command: RecordingLiveActivityCommand) async
}

/// Receives lock-screen Live Activity commands from in-process intents and
/// from the widget Darwin fallback.
@MainActor
final class RecordingLiveActivityCommandCenter {
    static let shared = RecordingLiveActivityCommandCenter()
    private static let log = Logger(
        subsystem: "YiJie.speech_note",
        category: "LiveActivityIntent"
    )

    weak var handler: RecordingLiveActivityCommandHandling? {
        didSet {
            guard handler != nil, let queued = pendingCommand else { return }
            pendingCommand = nil
            Task { await perform(queued) }
        }
    }
    private var pendingCommand: RecordingLiveActivityCommand?
    private var didStartObserving = false
    private var notifyTokens: [Int32] = []

    private init() {}

    func startObserving() {
        guard !didStartObserving else { return }
        didStartObserving = true
        for command in RecordingLiveActivityCommand.allCases {
            var token: Int32 = 0
            let name = command.rawValue
            let status = name.withCString { cName in
                notify_register_dispatch(cName, &token, .main) { _ in
                    let matched = command
                    Task { @MainActor in
                        await RecordingLiveActivityCommandCenter.shared.perform(matched)
                    }
                }
            }
            if status == NOTIFY_STATUS_OK {
                notifyTokens.append(token)
            } else {
                Self.log.error("notify_register_dispatch failed for \(name, privacy: .public): \(status)")
            }
        }
    }

    func perform(_ command: RecordingLiveActivityCommand) async {
        Self.log.notice("Live Activity command \(command.rawValue, privacy: .public)")
        guard let handler else {
            Self.log.error("No live-activity command handler; queueing \(command.rawValue, privacy: .public)")
            pendingCommand = command
            return
        }
        await handler.handleLiveActivityCommand(command)
    }
}
