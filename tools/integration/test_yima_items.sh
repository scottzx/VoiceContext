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
xcrun swiftc -default-isolation MainActor "$YIMA_CHECK_DIR/AgentToolTypes.swift" \
    Integration/App/YimaItemsRepository.swift Integration/App/YimaItemsStore.swift \
    Integration/App/YimaItemsAgentTool.swift tools/integration/test_yima_items_agent.swift -o "$YIMA_CHECK_DIR/agent"
"$YIMA_CHECK_DIR/agent"
xcrun swiftc Integration/App/TaskCalendarRules.swift tools/integration/test_task_calendar.swift -o "$YIMA_CHECK_DIR/calendar"
"$YIMA_CHECK_DIR/calendar"
