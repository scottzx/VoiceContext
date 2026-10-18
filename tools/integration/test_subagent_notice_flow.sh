#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
SUBAGENT_NOTICE_CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/subagent-notice-flow.XXXXXX")
trap 'rm -rf "$SUBAGENT_NOTICE_CHECK_DIR"' EXIT
sed -n '1,/\/\/ MARK: - Stream Events/p' Vendor/Phone/src/ios/Providers/AgentProvider.swift > "$SUBAGENT_NOTICE_CHECK_DIR/ToolTypes.swift"
# Real dispatch/executor/notice bus/reply delivery, isolated host stores and runner.
xcrun swiftc -default-isolation MainActor \
    "$SUBAGENT_NOTICE_CHECK_DIR/ToolTypes.swift" \
    Vendor/Phone/src/ios/AgentKit/AgentRuntimePolicy.swift \
    Vendor/Phone/src/ios/AgentKit/Runtime/AgentSessionRunner.swift \
    Vendor/Phone/src/ios/AgentKit/Runtime/BackgroundRunOutcome.swift \
    Vendor/Phone/src/ios/AgentKit/Runtime/AsyncTaskNoticeManager.swift \
    Vendor/Phone/src/ios/AgentKit/SubagentExecutor.swift \
    Vendor/Phone/src/ios/AgentKit/SubagentTools.swift \
    Vendor/Phone/src/ios/AgentKit/SubagentCoordinator.swift \
    Integration/App/MeetingAnswerUserTool.swift \
    tools/integration/test_subagent_notice_flow.swift -o "$SUBAGENT_NOTICE_CHECK_DIR/check"
"$SUBAGENT_NOTICE_CHECK_DIR/check"
