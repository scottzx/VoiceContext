#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
AGENT_RELAY_CONTEXT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/agent-relay-context.XXXXXX")
trap 'rm -rf "$AGENT_RELAY_CONTEXT_DIR"' EXIT
python3 - "$AGENT_RELAY_CONTEXT_DIR" <<'PY'
from pathlib import Path
import sys
source = Path('Vendor/Phone/src/ios/Agent/Chat/AIChatViewModel.swift').read_text()
start = source.index('    var isHeadlessSession: Bool {')
opening = source.index('{', start)
depth, end = 1, opening + 1
while depth:
    if source[end] == '{': depth += 1
    if source[end] == '}': depth -= 1
    end += 1
headless = source[start:end]
runtime_start = source.index('    var runtimePolicy: AgentRuntimePolicy {')
runtime_end = source.index('}', runtime_start) + 1
headless = source[runtime_start:runtime_end] + '\n' + headless
start = source.index('        // Check if context is near capacity', source.index('    func send()'))
end = source.index('        UIImpactFeedbackGenerator', start)
branch = source[start:end]
Path(sys.argv[1], 'ContextWiring.swift').write_text('import Foundation\nextension AIChatViewModel {\n' + headless +
    '\n    func sendContextForCheck(text: String, pendingAttachments: [String]) {\n' + branch +
    '\n        continuedSend = true\n    }\n}\n')
PY
# Only actual headless detection/context decisions run, with no iOS UI or engine.
sed -n '1,/\/\/ MARK: - Agent Messages/p' Vendor/Phone/src/ios/Providers/AgentProvider.swift > "$AGENT_RELAY_CONTEXT_DIR/ToolTypes.swift"
xcrun swiftc -swift-version 6 -default-isolation MainActor \
    "$AGENT_RELAY_CONTEXT_DIR/ToolTypes.swift" Vendor/Phone/src/ios/AgentKit/AgentRuntimePolicy.swift \
    "$AGENT_RELAY_CONTEXT_DIR/ContextWiring.swift" tools/integration/test_agent_relay_context.swift \
    -o "$AGENT_RELAY_CONTEXT_DIR/check"
"$AGENT_RELAY_CONTEXT_DIR/check"
