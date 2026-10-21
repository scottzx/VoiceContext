#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
HOST_CALLBACK_CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/host-callbacks.XXXXXX")
trap 'rm -rf "$HOST_CALLBACK_CHECK_DIR"' EXIT
sed -n '1,/\/\/ MARK: - Agent Messages/p' Vendor/Phone/src/ios/Providers/AgentProvider.swift > "$HOST_CALLBACK_CHECK_DIR/ToolTypes.swift"
xcrun swiftc -default-isolation MainActor "$HOST_CALLBACK_CHECK_DIR/ToolTypes.swift" \
    Vendor/Phone/src/ios/AgentKit/AgentRuntimePolicy.swift \
    tools/integration/test_host_tool_callbacks.swift -o "$HOST_CALLBACK_CHECK_DIR/check"
"$HOST_CALLBACK_CHECK_DIR/check"
python3 - <<'PY'
from pathlib import Path
p = Path('Vendor/Phone/src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift').read_text()
assert p.index('runtimeToolRefusal(name:') < p.index('hooks?.willRunTool') < p.index('preflightValidateToolCall') < p.index('AgentRuntimePolicies.executeHostTool')
assert p.index('AgentRuntimePolicies.executeHostTool') < p.index('} catch is CancellationError')
print('PASS: dispatch is inside existing refusal/hooks/preflight and cancellation/result lifecycle')
PY
