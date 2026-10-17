#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
XIAOLAN_GATE_CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/xiaolan-gate.XXXXXX")
trap 'rm -rf "$XIAOLAN_GATE_CHECK_DIR"' EXIT
# Run actual recording start/append/resume controls and the installed bridge on
# macOS; the repository and microphone boundaries count attempted side effects.
python3 - "$XIAOLAN_GATE_CHECK_DIR" <<'PY'
from pathlib import Path
import sys
source = Path('speech_note/speech_note/Features/Recording/RecordingCoreModel.swift').read_text()
def method(name):
    start = source.index('    func ' + name + '(')
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        if source[end] == '{': depth += 1
        if source[end] == '}': depth -= 1
        end += 1
    return source[start:end]
Path(sys.argv[1], 'Controls.swift').write_text('import Foundation\nextension RecordingCoreModel {\n' + '\n'.join(method(n) for n in ['start', 'append', 'pauseOrResume']) + '\n}\n')
PY
xcrun swiftc -default-isolation MainActor -swift-version 5 \
    speech_note/speech_note/Features/Recording/RecordingAudioBridge.swift \
    "$XIAOLAN_GATE_CHECK_DIR/Controls.swift" \
    tools/integration/test_xiaolan_recording_gate.swift \
    -o "$XIAOLAN_GATE_CHECK_DIR/check"
"$XIAOLAN_GATE_CHECK_DIR/check"
