#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
STORY_TOOL_CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/story-player-tool.XXXXXX")
trap 'rm -rf "$STORY_TOOL_CHECK_DIR"' EXIT
sed -n '1,/\/\/ MARK: - Agent Messages/p' Vendor/Phone/src/ios/Providers/AgentProvider.swift > "$STORY_TOOL_CHECK_DIR/AgentToolTypes.swift"
# Host logic checks only; no iOS app, device or Simulator is launched.
xcrun swiftc -default-isolation MainActor -module-cache-path "$STORY_TOOL_CHECK_DIR/modules" \
    "$STORY_TOOL_CHECK_DIR/AgentToolTypes.swift" \
    Vendor/Phone/src/ios/AgentKit/AgentRuntimePolicy.swift \
    Integration/App/StoryPlayerTool.swift tools/integration/test_story_player_tool.swift \
    -o "$STORY_TOOL_CHECK_DIR/check"
"$STORY_TOOL_CHECK_DIR/check"
python3 - <<'PY'
from pathlib import Path
configuration = Path('Integration/App/VoiceAgentConfiguration.swift').read_text()
dispatch = Path('Vendor/Phone/src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift').read_text()
runner = Path('Vendor/Phone/src/ios/AgentKit/Runtime/IOSAgentSessionRunner.swift').read_text()
vm = Path('Vendor/Phone/src/ios/Agent/Chat/AIChatViewModel.swift').read_text()
policy = Path('Vendor/Phone/src/ios/AgentKit/AgentRuntimePolicy.swift').read_text()
tool = Path('Integration/App/StoryPlayerTool.swift').read_text()
host_line = next(line for line in configuration.splitlines() if 'AgentRuntimePolicies.hostTools =' in line)
assert 'StoryPlayerTool' not in host_line
assert 'additionalTools: meeting ? [MeetingAppleTool.definition] : [MeetingAppleTool.definition, StoryPlayerTool.definition]' in configuration
case = dispatch.split('case "story_player":', 1)[1].split('#endif', 1)[0]
assert 'isExecutor: self.agentRole == .executor' in case
assert 'noticeDriven: self.isNoticeDriven' in case
assert 'voiceGeneration: self.toolExecutionGeneration' in case
assert 'sessionID: self.sessionId, sessionSource: self.sessionSource' in case
assert 'var toolExecutionGeneration: UInt64?' in vm
assert 'var executionGeneration: (@MainActor (String) -> UInt64?)?' in policy
assert 'vm.toolExecutionGeneration = runtimePolicy.executionGeneration?(request.sessionId)' in runner
notice_resume = runner.split('func resumeAfterAsyncToolResults(', 1)[1]
assert 'vm.toolExecutionGeneration = nil' in notice_resume
assert 'XiaolanVoiceController.shared.executionGeneration(sessionID: $0)' in configuration
assert 'XiaolanVoiceController.shared.executionGeneration(sessionID: sessionID) == voiceGeneration' in tool
assert 'AppNavigationCenter' not in tool and 'requiresNavigationBinding' not in tool
for name in ['app_navigation', 'app_present']:
    ui_case = dispatch.split(f'case "{name}":', 1)[1].split('case ', 1)[0]
    assert 'voiceGeneration: self.appNavigationVoiceGeneration' in ui_case
print('PASS: story dispatch captures host execution authority, clears it for notices and keeps navigation/preview on their separate foreground binding')
PY
