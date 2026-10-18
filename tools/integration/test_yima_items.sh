#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
YIMA_CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/yima-items.XXXXXX")
trap 'rm -rf "$YIMA_CHECK_DIR"' EXIT
# Host-only logic checks; never build/run an iOS test or Simulator.
xcrun swiftc -default-isolation MainActor Integration/App/YimaItemsRepository.swift \
    Integration/App/YimaItemsStore.swift tools/integration/test_yima_items.swift -o "$YIMA_CHECK_DIR/store"
"$YIMA_CHECK_DIR/store"
# Keep the actual canonical schema types while excluding provider runtime code.
sed -n '1,/\/\/ MARK: - Agent Messages/p' Vendor/Phone/src/ios/Providers/AgentProvider.swift > "$YIMA_CHECK_DIR/AgentToolTypes.swift"
python3 - "$YIMA_CHECK_DIR/YimaDispatch.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Vendor/Phone/src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift').read_text()
case = source.split('case "yima_items":', 1)[1].split('case "apple_native":', 1)[0]
body = case.split('\n            toolOutput = result.output', 1)[0].strip()
assert body.startswith('let result = await MainActor.run {') and body.endswith('}')
assert body.count('YimaItemsAgentTool.execute(') == 1
# Inject only the persistence boundary; compile the actual dispatch permission code.
assert body.count('YimaItemsAgentTool.execute(toolArgs, sessionID: self.sessionId,') == 1
body = body.replace('YimaItemsAgentTool.execute(toolArgs, sessionID: self.sessionId,',
                    'YimaItemsAgentTool.execute(toolArgs, sessionID: self.sessionId, store: self.store,', 1)
Path(sys.argv[1]).write_text('''import Foundation
@MainActor final class YimaDispatchHost {
    let store: YimaItemsStore
    var sessionId: String? = "items-session"
    var sessionSource: String? = "bound-items"
    var appNavigationVoiceGeneration: UInt64? = 9
    init(store: YimaItemsStore) { self.store = store }
    func execute(_ toolArgs: [String: Any]) async -> (output: String, success: Bool) {
''' + body + '''
        return result
    }
}
''')
PY
xcrun swiftc -default-isolation MainActor "$YIMA_CHECK_DIR/AgentToolTypes.swift" \
    Vendor/Phone/src/ios/AgentKit/AgentRuntimePolicy.swift Integration/App/AppNavigationCenter.swift \
    Integration/App/YimaItemsRepository.swift Integration/App/YimaItemsStore.swift \
    Integration/App/YimaItemsAgentTool.swift "$YIMA_CHECK_DIR/YimaDispatch.swift" \
    tools/integration/test_yima_items_agent.swift -o "$YIMA_CHECK_DIR/agent"
"$YIMA_CHECK_DIR/agent"
xcrun swiftc Integration/App/TaskCalendarRules.swift tools/integration/test_task_calendar.swift -o "$YIMA_CHECK_DIR/calendar"
"$YIMA_CHECK_DIR/calendar"
