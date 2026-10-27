#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
RECORDING_RECOVERY_CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/recording-recovery.XXXXXX")
trap 'rm -rf "$RECORDING_RECOVERY_CHECK_DIR"' EXIT
# Execute the complete production coordinator on macOS with fake audio,
# ActivityKit/MediaPlayer and persistence boundaries. Never capture/play audio.
python3 - "$RECORDING_RECOVERY_CHECK_DIR" <<'PY'
from pathlib import Path
import sys

def declaration(source, marker):
    start = source.index(marker)
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        if source[end] == '{': depth += 1
        if source[end] == '}': depth -= 1
        end += 1
    return source[start:end]

output = Path(sys.argv[1])
recording = Path('speech_note/speech_note/Features/Recording')
domain = (recording / 'RecordingDomain.swift').read_text()
types = ['RecordingState', 'RecordingCaptureState', 'AudioChunkState', 'RecordingGapReason']
models = ['AudioChunk', 'RecordingGap', 'RecordingStateMachine']
output.joinpath('Domain.swift').write_text('import Foundation\n' + '\n'.join(
    declaration(domain, 'nonisolated enum ' + name + ':') for name in types
) + '\n' + '\n'.join(declaration(domain, 'nonisolated struct ' + name + ':') for name in models))
recorder = (recording / 'AACSegmentRecorder.swift').read_text()
output.joinpath('CaptureTypes.swift').write_text('import Foundation\nenum CaptureTypes {\n' +
    declaration(recorder, 'nonisolated struct Segment:') + '\n' +
    declaration(recorder, 'nonisolated struct CaptureEvent:') + '\n}\n')
output.joinpath('Coordinator.swift').write_text(
    (recording / 'RecordingSessionCoordinator.swift').read_text().replace('import MediaPlayer\n', '')
)
PY
xcrun swiftc -default-isolation MainActor -swift-version 5 \
    "$RECORDING_RECOVERY_CHECK_DIR/Domain.swift" \
    "$RECORDING_RECOVERY_CHECK_DIR/CaptureTypes.swift" \
    "$RECORDING_RECOVERY_CHECK_DIR/Coordinator.swift" \
    tools/integration/test_recording_capture_recovery.swift \
    -o "$RECORDING_RECOVERY_CHECK_DIR/check"
"$RECORDING_RECOVERY_CHECK_DIR/check"
xcrun swiftc -frontend -parse \
    speech_note/speech_note/Features/Recording/AACSegmentRecorder.swift \
    speech_note/speech_note/Features/Recording/RecordingSessionCoordinator.swift
