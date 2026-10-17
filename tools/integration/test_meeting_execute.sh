#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
MEETING_EXECUTE_CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/meeting-execute.XXXXXX")
trap 'rm -rf "$MEETING_EXECUTE_CHECK_DIR"' EXIT
# Host-only integration: execute() and answer_user are product code. Combine
# is the Mac framework; fake services record delivery without playing audio.
sed -n '1,/\/\/ MARK: - Agent Messages/p' \
    Vendor/Phone/src/ios/Providers/AgentProvider.swift > "$MEETING_EXECUTE_CHECK_DIR/AgentToolTypes.swift"
python3 - "$MEETING_EXECUTE_CHECK_DIR" <<'PY'
from pathlib import Path
import sys
source = Path('Integration/App/MeetingAssistantController.swift').read_text()
methods = []
for name in ['execute', 'session', 'systemPrompt', 'prompt', 'recordingTime']:
    start = source.index('    private func ' + name + '(')
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        if source[end] == '{': depth += 1
        if source[end] == '}': depth -= 1
        end += 1
    methods.append(source[start:end])
Path(sys.argv[1], 'Execute.swift').write_text('''import Foundation
import Combine
extension MeetingAssistantController {
''' + '\n'.join(methods) + '''
    func runForCheck(_ request: MeetingAssistantBridge.Request) async {
        activeRequestID = request.id
        bridge.activate(request.id)
        await execute(request)
    }
}
''')
PY
xcrun swiftc -default-isolation MainActor \
    "$MEETING_EXECUTE_CHECK_DIR/AgentToolTypes.swift" \
    Vendor/Phone/src/ios/AgentKit/AgentRuntimePolicy.swift \
    Integration/App/MeetingAnswerUserTool.swift \
    Integration/App/MeetingTranscriptContext.swift \
    "$MEETING_EXECUTE_CHECK_DIR/Execute.swift" \
    tools/integration/test_meeting_execute.swift \
    -o "$MEETING_EXECUTE_CHECK_DIR/check"
"$MEETING_EXECUTE_CHECK_DIR/check"
