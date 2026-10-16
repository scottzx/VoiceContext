#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
MEETING_ANSWER_CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/meeting-answer.XXXXXX")
trap 'rm -rf "$MEETING_ANSWER_CHECK_DIR"' EXIT
# Host-only checks of the real tool, registration gate and dispatch case.
sed -n '1,/\/\/ MARK: - Agent Messages/p' \
    Vendor/Phone/src/ios/Providers/AgentProvider.swift > "$MEETING_ANSWER_CHECK_DIR/AgentToolTypes.swift"
python3 - "$MEETING_ANSWER_CHECK_DIR" <<'PY'
from pathlib import Path
import sys
out = Path(sys.argv[1])
definitions = Path('Vendor/Phone/src/ios/Agent/Chat/AIChatViewModel+ToolDefinitions.swift').read_text()
start = definitions.index('    var meetingReplyToolDefinitions:')
end = definitions.index('\n    /// The tool set', start)
dispatch = Path('Vendor/Phone/src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift').read_text()
start_case = dispatch.index('        case "answer_user":')
end_case = dispatch.index('        case "yima_items":', start_case)
(out / 'MeetingAnswerWiring.swift').write_text('''import Foundation
extension AIChatViewModel {
''' + definitions[start:end] + '''
    func dispatchAnswer(_ toolArgs: [String: Any]) async -> (output: String, success: Bool) {
        let msgIdx = 0, blockIdx = 0
        var toolOutput = "", toolSuccess = false
        switch "answer_user" {
''' + dispatch[start_case:end_case] + '''
        default: break
        }
        return (toolOutput, toolSuccess)
    }
}
''')
PY
xcrun swiftc -default-isolation MainActor -D VOICE_AGENT_FUSION \
    "$MEETING_ANSWER_CHECK_DIR/AgentToolTypes.swift" \
    Integration/App/MeetingAnswerUserTool.swift \
    Vendor/Phone/src/ios/AgentKit/SubagentTools.swift \
    "$MEETING_ANSWER_CHECK_DIR/MeetingAnswerWiring.swift" \
    tools/integration/test_meeting_answer_user.swift \
    -o "$MEETING_ANSWER_CHECK_DIR/check"
"$MEETING_ANSWER_CHECK_DIR/check"
