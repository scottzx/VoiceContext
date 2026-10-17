#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
MEETING_RUNNER_CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/meeting-runner.XXXXXX")
trap 'rm -rf "$MEETING_RUNNER_CHECK_DIR"' EXIT
sed -n '1,/\/\/ MARK: - Agent Messages/p' Vendor/Phone/src/ios/Providers/AgentProvider.swift > "$MEETING_RUNNER_CHECK_DIR/ToolTypes.swift"
# Run the production adapter method on the Mac with an in-memory VM boundary.
# No iOS runtime, microphone, model request or device connection is used.
python3 - "$MEETING_RUNNER_CHECK_DIR" <<'PY'
from pathlib import Path
import sys
source = Path('Vendor/Phone/src/ios/AgentKit/Runtime/IOSAgentSessionRunner.swift').read_text()
start = source.index('    func run(')
opening = source.index('{', start)
depth, end = 1, opening + 1
while depth:
    if source[end] == '{': depth += 1
    if source[end] == '}': depth -= 1
    end += 1
Path(sys.argv[1], 'Runner.swift').write_text('''import Combine
import Foundation
extension IOSAgentSessionRunner {
''' + source[start:end] + '\n}\n')

PY
xcrun swiftc -default-isolation MainActor -swift-version 5 -D VOICE_AGENT_FUSION \
    "$MEETING_RUNNER_CHECK_DIR/ToolTypes.swift" \
    Vendor/Phone/src/ios/AgentKit/AgentRuntimePolicy.swift \
    Vendor/Phone/src/ios/AgentKit/Runtime/AgentSessionRunner.swift \
    "$MEETING_RUNNER_CHECK_DIR/Runner.swift" \
    tools/integration/test_meeting_session_runner.swift \
    -o "$MEETING_RUNNER_CHECK_DIR/check"
"$MEETING_RUNNER_CHECK_DIR/check"
