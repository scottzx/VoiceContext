#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
MEETING_CONTEXT_CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/meeting-context.XXXXXX")
trap 'rm -rf "$MEETING_CONTEXT_CHECK_DIR"' EXIT
python3 - "$MEETING_CONTEXT_CHECK_DIR" <<'PY'
from pathlib import Path
import sys
source = Path('Vendor/Phone/src/ios/Agent/Chat/ChatStore.swift').read_text()
start = source.index('    static func stripSystemReminders(')
opening = source.index('{', start)
depth, end = 1, opening + 1
while depth:
    if source[end] == '{': depth += 1
    if source[end] == '}': depth -= 1
    end += 1
Path(sys.argv[1], 'ContextDisplayCheck.swift').write_text('import Foundation\nenum ContextDisplayCheck {\n' + source[start:end] + '\n}\n')
PY
xcrun swiftc Integration/App/MeetingTranscriptContext.swift \
    "$MEETING_CONTEXT_CHECK_DIR/ContextDisplayCheck.swift" \
    tools/integration/test_meeting_transcript_context.swift \
    -o "$MEETING_CONTEXT_CHECK_DIR/check"
"$MEETING_CONTEXT_CHECK_DIR/check"
