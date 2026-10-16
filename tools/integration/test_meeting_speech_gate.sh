#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
MEETING_SPEECH_CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/meeting-speech.XXXXXX")
trap 'rm -rf "$MEETING_SPEECH_CHECK_DIR"' EXIT
# Compile actual chat gates with in-memory state on the Mac.
# No audio playback, iOS runtime or Simulator is involved.
python3 - "$MEETING_SPEECH_CHECK_DIR" <<'PY'
from pathlib import Path
import sys

def block(source, marker):
    start = source.index(marker)
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        if source[end] == '{': depth += 1
        if source[end] == '}': depth -= 1
        end += 1
    return source[start:end]

source = Path('Vendor/Phone/src/ios/Agent/Chat/AIChatViewModel.swift').read_text()
getter = block(source, '    private var canSpeakNow: Bool {')
lite_getter = block(source, '    var liteModeActive: Bool {')
persistence = Path('Vendor/Phone/src/ios/Agent/Chat/AIChatViewModel+Persistence.swift').read_text()
load = block(persistence, '    func loadSession() async {')
restore = block(load, '            if row.source == "meeting_assistant" {')
Path(sys.argv[1], 'SpeechGate.swift').write_text(
    'extension AIChatViewModel {\n' + getter + '\n' + lite_getter
    + '\n    var testCanSpeakNow: Bool { canSpeakNow }\n}\n'
    + 'extension AIChatViewModel {\n'
    + '    func testRestoreSessionSource(from row: StoredSession) {\n' + restore + '\n    }\n}\n'
)
PY
xcrun swiftc -default-isolation MainActor \
    "$MEETING_SPEECH_CHECK_DIR/SpeechGate.swift" \
    tools/integration/test_meeting_speech_gate.swift \
    -o "$MEETING_SPEECH_CHECK_DIR/check"
"$MEETING_SPEECH_CHECK_DIR/check"
