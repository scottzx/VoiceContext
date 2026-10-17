#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
XIAOLAN_AGENT_CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/xiaolan-agent.XXXXXX")
trap 'rm -rf "$XIAOLAN_AGENT_CHECK_DIR"' EXIT
# Product profile bootstrap and session/roster adapters run against a temporary
# persona tree and in-memory storage; no user profile or history is modified.
python3 - "$XIAOLAN_AGENT_CHECK_DIR" <<'PY'
from pathlib import Path
import sys
out = Path(sys.argv[1])
def method(path, prefix):
    source = Path(path).read_text()
    start = source.index(prefix)
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        if source[end] == '{': depth += 1
        if source[end] == '}': depth -= 1
        end += 1
    return source[start:end]
out.joinpath('Create.swift').write_text('import Foundation\nextension IOSAgentSessionRunner {\n' + method('Vendor/Phone/src/ios/AgentKit/Runtime/IOSAgentSessionRunner.swift', '    func createSession(') + '\n}\n')
out.joinpath('Roster.swift').write_text('import Foundation\nextension AgentStore {\n' + method('Vendor/Phone/src/ios/AgentKit/AgentStore.swift', '    func refresh(') + '\n}\n')
PY
sed -n '1,/\/\/ MARK: - Agent Messages/p' Vendor/Phone/src/ios/Providers/AgentProvider.swift > "$XIAOLAN_AGENT_CHECK_DIR/ToolTypes.swift"
xcrun swiftc -default-isolation MainActor -swift-version 5 -D VOICE_AGENT_FUSION \
    "$XIAOLAN_AGENT_CHECK_DIR/ToolTypes.swift" \
    Vendor/Phone/src/ios/AgentKit/AgentRuntimePolicy.swift \
    Vendor/Phone/src/ios/AgentKit/Runtime/AgentSessionRunner.swift \
    Integration/App/XiaolanAgent.swift \
    "$XIAOLAN_AGENT_CHECK_DIR/Create.swift" "$XIAOLAN_AGENT_CHECK_DIR/Roster.swift" \
    tools/integration/test_xiaolan_agent.swift \
    -o "$XIAOLAN_AGENT_CHECK_DIR/check"
"$XIAOLAN_AGENT_CHECK_DIR/check" "$XIAOLAN_AGENT_CHECK_DIR/files"
