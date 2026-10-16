#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
MEETING_PLAYBACK_CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/meeting-playback.XXXXXX")
trap 'rm -rf "$MEETING_PLAYBACK_CHECK_DIR"' EXIT
# Exercise the actual playback lifecycle on the Mac. The test substitutes only
# the provider, player, audio lease and bridge; no audio is played or captured.
python3 - "$MEETING_PLAYBACK_CHECK_DIR" <<'PY'
from pathlib import Path
import sys
source = Path('Integration/App/MeetingAssistantController.swift').read_text()
methods = []
for name in ('speak', 'stopSpeech', 'finishSpeech'):
    start = source.index(f'    private func {name}(')
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        if source[end] == '{': depth += 1
        if source[end] == '}': depth -= 1
        end += 1
    methods.append(source[start:end])
Path(sys.argv[1], 'Playback.swift').write_text('''import Foundation
extension MeetingAssistantController {
''' + '\n'.join(methods) + '''
    func speakForCheck(_ id: UUID) async {
        await speak("我已入会，有事叫小蓝同学", requestID: id)
    }
    func stopForCheck() { stopSpeech() }
}
''')
PY
xcrun swiftc -default-isolation MainActor -swift-version 5 \
    "$MEETING_PLAYBACK_CHECK_DIR/Playback.swift" \
    tools/integration/test_meeting_playback_gate.swift \
    -o "$MEETING_PLAYBACK_CHECK_DIR/check"
"$MEETING_PLAYBACK_CHECK_DIR/check"
