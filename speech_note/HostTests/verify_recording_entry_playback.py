#!/usr/bin/env python3
"""Check production entry methods and speech matching on macOS; never run iOS."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = root / "speech_note/Features"
model_source = (source / "Recording/RecordingCoreModel.swift").read_text()
session_source = (source / "Recording/RecordingSessionCoordinator.swift").read_text()


def declaration(marker, text=model_source):
    start = text.index(marker)
    opening = text.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]


with tempfile.TemporaryDirectory(prefix="yima-recording-entry-") as temporary:
    temporary = Path(temporary)
    wrapper = temporary / "ProductionEntryMethods.swift"
    wrapper.write_text("""import Foundation
import SwiftUI
// UI-only token stand-ins: playback/entry rules run on macOS without UIKit.
// The iPhoneOS build validates the real shared color tokens.
enum YimaDesign { enum Color {
    static let ink = SwiftUI.Color.primary
    static let muted = SwiftUI.Color.secondary
} }
@MainActor final class EntryModel {
    enum Presentation { case idle, recording, paused, interrupted, stopping, processing, failed }
    var presentation: Presentation = .idle
    var isStartingRecording = false
    var notice: String?
    var activeRecordingID: UUID?
    let coordinator = EntryCoordinator()
    func refresh() async { if activeRecordingID != nil { presentation = .recording } }
    func updateRecordingLocation(recordingID: UUID, locationName: String) async {}
""" + "\n".join(declaration(marker) for marker in (
        "var showsSessionChrome:", "func start(title:", "func append(recordingID:",
    )) + "\n}\n")
    session = temporary / "ProductionSessionMethods.swift"
    session.write_text("import Foundation\n@MainActor final class EntrySession {\n" + """
    enum CoordinatorError: Error { case sessionAlreadyActive, noActiveSession }
    enum State: Equatable { case idle, preparing, recording, failed(String) }
    let repository = EntryRepository()
    let capture = EntryCapture()
    let lowStorageGuard = LowStorageGuard()
    let now: () -> Date = Date.init
    var activeRecordingID: UUID?
    var stateMachine: RecordingStateMachine?
    var persistedSegmentIDs = Set<UUID>()
    var pendingSegments: [UUID: Int] = [:]
    var segmentPersistenceTask: Int?
    var segmentPersistenceOperationID: UUID?
    var segmentPersistenceFailureMessage: String?
    var stoppedCaptureEndedAt: Date?
    var userPausedCapture = false
    var captureState: State = .idle
    var presentationState: State = .idle
    func installCaptureCallbacks() {}
    func installRemoteStopCommand() {}
""" + "\n".join(declaration(marker, session_source) for marker in (
        "func start(isMeeting:", "func startAppend(recordingID:",
    )) + "\n}\n")
    binary = temporary / "checks"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5",
        "-module-cache-path", str(temporary / "module-cache"),
        str(source / "Recording/RecordingDetailPlaybackPresentation.swift"),
        str(wrapper), str(session),
        str(root / "HostTests/RecordingEntryPlaybackChecks.swift"),
        str(root / "HostTests/RecordingStartFailureChecks.swift"),
        "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
