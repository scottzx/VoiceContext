#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
XIAOLAN_EXCLUSION_CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/xiaolan-recording-exclusion.XXXXXX")
trap 'rm -rf "$XIAOLAN_EXCLUSION_CHECK_DIR"' EXIT
# Execute production ownership methods against silent host audio boundaries.
# No device, simulator, microphone, speaker, or recording is opened.
python3 - "$XIAOLAN_EXCLUSION_CHECK_DIR/Ownership.swift" <<'PY'
from pathlib import Path
import sys

def method(source, declaration):
    start = source.index(declaration)
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        if source[end] == '{': depth += 1
        if source[end] == '}': depth -= 1
        end += 1
    return source[start:end]

audio = Path('Vendor/Phone/src/ios/Providers/Voice/AudioSessionCoordinator.swift').read_text()
voice = Path('Integration/App/XiaolanVoiceController.swift').read_text()
declarations = [next(line for line in audio.splitlines() if token in line) for token in [
    'var isRecording: Bool', 'var isStoryPlaybackActive: Bool',
    'private(set) var isIndependentVoiceEnabled', 'private var recordingOwners',
]]
audio_methods = [method(audio, '    func ' + name + '(') for name in [
    'beginRecording', 'endRecording', 'reserveIndependentVoice', 'releaseIndependentVoice',
]]
voice_methods = [method(voice, '    ' + access + 'func ' + name + '(') for access, name in [
    ('', 'pause'), ('', 'disable'), ('private ', 'invalidate'),
]]
Path(sys.argv[1]).write_text('''import Foundation
@MainActor final class AudioSessionCoordinator {
    static let shared = AudioSessionCoordinator()
    enum Intent: Hashable { case recording, meetingAssistantTTS, xiaolanCapture, xiaolanTTS, storyPlayback }
    var active: Set<Intent> = []
    var hardwareBegins = 0
    static let recordingWillStart = Notification.Name("test.recordingWillStart")
    static let storyPlaybackPreempted = Notification.Name("test.storyPlaybackPreempted")
    static let replyTTSPreemptedNotification = Notification.Name("test.replyTTSPreempted")
    func beginAndWait(_ intent: Intent) -> Bool { hardwareBegins += 1; active.insert(intent); return true }
    func end(_ intent: Intent) { active.remove(intent) }
    func apply(reason: String) {}
''' + '\n'.join(declarations + audio_methods) + '''
}
@MainActor final class VoiceHost {
    var activationID: UUID?
    var isEnabled = true
    var isPaused = false
    var commandCaptureActive = false
    var captureAllowsNavigation = true
    var directAllowsNavigation: Bool?
    var sessionID: String? = "voice-session"
    var input: InputBoundary? = InputBoundary()
    var status = ""
    func interruptCurrentRequest() {}
''' + '\n'.join(voice_methods) + '\n}\n')

# Verify the actual recorder path still reaches the shared admission gate;
# the CoreModel delegates through its session coordinator and capture bridge.
core = Path('speech_note/speech_note/Features/Recording/RecordingCoreModel.swift').read_text()
core_start = method(core, '    func start(title:')
assert core_start.count('RecordingAudioBridge.recordingStartBlockReason') == 2
assert core_start.index('RecordingAudioBridge.recordingStartBlockReason') < core_start.index('MicrophoneAccess.requestPermissionIfNeeded')
assert core_start.rindex('RecordingAudioBridge.recordingStartBlockReason') > core_start.index('MicrophoneAccess.requestPermissionIfNeeded')
assert 'try await coordinator.start(' in core_start
session = Path('speech_note/speech_note/Features/Recording/RecordingSessionCoordinator.swift').read_text()
assert 'try await capture.start(' in method(session, '    func start(isMeeting:')
capture = Path('speech_note/speech_note/Features/Recording/AACSegmentRecorder.swift').read_text()
assert 'try activateCaptureSession()' in method(capture, '    func start(')
assert 'try handlers.capture(audioOwner)' in method(capture, '    private func activateCaptureSession(')
assert 'releaseCaptureSession()' not in method(capture, '    func pause('), 'Paused recording must retain its owner'
assert 'try activateCaptureSession()' in method(capture, '    func resume(')
fusion = Path('Integration/App/FusionAudio.swift').read_text()
assert 'capture: { owner in try onMain { try AudioSessionCoordinator.shared.beginRecording(owner: owner) } }' in fusion
assert 'AudioSessionCoordinator.shared.isIndependentVoiceEnabled ? "请先关闭语音模式，再开始录音。" : nil' in fusion
install = method(voice, '    func install(')
assert 'AVAudioSession.interruptionNotification' in install and 'InterruptionType.began' in install and 'self?.pause()' in install
print('PASS: real recording start/permission recheck/session coordinator/capture bridge reaches the unified voice exclusion; paused capture retains ownership')
PY
xcrun swiftc -default-isolation MainActor -swift-version 5 \
    "$XIAOLAN_EXCLUSION_CHECK_DIR/Ownership.swift" \
    tools/integration/test_xiaolan_recording_exclusion.swift \
    -o "$XIAOLAN_EXCLUSION_CHECK_DIR/check"
"$XIAOLAN_EXCLUSION_CHECK_DIR/check"
