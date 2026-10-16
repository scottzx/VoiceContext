#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
MEETING_POLICY_CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/meeting-policy.XXXXXX")
trap 'rm -rf "$MEETING_POLICY_CHECK_DIR"' EXIT
sed -n '1,/\/\/ MARK: - Agent Messages/p' \
    Vendor/Phone/src/ios/Providers/AgentProvider.swift > "$MEETING_POLICY_CHECK_DIR/AgentToolTypes.swift"
python3 - "$MEETING_POLICY_CHECK_DIR" <<'PY'
from pathlib import Path
import sys
out = Path(sys.argv[1])
def extract(source, declaration):
    start = source.index(declaration)
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        if source[end] == '{': depth += 1
        if source[end] == '}': depth -= 1
        end += 1
    return source[start:end]
vm = Path('Vendor/Phone/src/ios/Agent/Chat/AIChatViewModel.swift').read_text()
dispatch = Path('Vendor/Phone/src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift').read_text()
(out / 'PolicyWiring.swift').write_text('import Foundation\nextension AIChatViewModel {\n' +
    extract(vm, '    var effectiveToolPolicy:') + '\n' +
    extract(vm, '    var liteModeActive:') + '\n' +
    extract(vm, '    private var baseSystemPrompt:') + '\n' +
    extract(dispatch, '    func executeSingleToolUse(') + '\n' +
    '    func promptForCheck() -> String { baseSystemPrompt }\n}\n')
PY
xcrun swiftc -default-isolation MainActor -D VOICE_AGENT_FUSION \
    "$MEETING_POLICY_CHECK_DIR/AgentToolTypes.swift" \
    Vendor/Phone/src/ios/AgentKit/SubagentTools.swift \
    Vendor/Phone/src/ios/AgentKit/OrchestratorPrompt.swift \
    Vendor/Phone/src/ios/Agent/Chat/AIChatViewModel+ToolDefinitions.swift \
    "$MEETING_POLICY_CHECK_DIR/PolicyWiring.swift" \
    tools/integration/test_meeting_tool_policy.swift \
    -o "$MEETING_POLICY_CHECK_DIR/check"
"$MEETING_POLICY_CHECK_DIR/check"
