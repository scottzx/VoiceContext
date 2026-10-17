#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
AGENT_POLICY_CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/agent-runtime-policy.XXXXXX")
trap 'rm -rf "$AGENT_POLICY_CHECK_DIR"' EXIT
sed -n '1,/\/\/ MARK: - Agent Messages/p' Vendor/Phone/src/ios/Providers/AgentProvider.swift > "$AGENT_POLICY_CHECK_DIR/ToolTypes.swift"
xcrun swiftc -default-isolation MainActor \
    "$AGENT_POLICY_CHECK_DIR/ToolTypes.swift" \
    Vendor/Phone/src/ios/AgentKit/AgentRuntimePolicy.swift \
    tools/integration/test_agent_runtime_policy.swift -o "$AGENT_POLICY_CHECK_DIR/check"
"$AGENT_POLICY_CHECK_DIR/check"
python3 - <<'PY'
from pathlib import Path
import re
root=Path('Vendor/Phone/src/ios')
files=list((root/'Agent/Chat').glob('AIChatViewModel*.swift')) + [
 root/'AgentKit/Runtime/IOSAgentSessionRunner.swift',
 root/'AgentKit/Runtime/AgentSessionRunner.swift',
 root/'AgentKit/Runtime/AsyncTaskNoticeManager.swift',
 root/'AgentKit/AgentRuntimePolicy.swift',
 root/'AgentKit/OrchestratorPrompt.swift',
 root/'AgentKit/AgentDirectoryCoordinator.swift',
 root/'AgentKit/AgentStore.swift',
]
forbidden=re.compile(r'Xiaolan|xiaolan_voice|meeting_assistant|delegate_to_yima|deliver_to_xiaolan|xiaolanDelegation|isMeetingCoordinator|isStandaloneVoiceCoordinator|isVoiceCoordinator|meetingVoiceMode|appVoiceMode|voiceNoticeMode')
violations=[]
for path in files:
 for n,line in enumerate(path.read_text().splitlines(),1):
  if forbidden.search(line): violations.append(f'{path}:{n}: {line.strip()}')
soul=(root/'Agent/Session/SoulStore.swift').read_text().split('enum SystemPromptBuilder {',1)[1].split('// MARK: - Reusable SwiftUI text view',1)[0]
if forbidden.search(soul) or 'voiceMode' in soul: violations.append('SystemPromptBuilder still contains a role-specific identity branch')
assert not violations, '\n'.join(violations)
assert not Path('Integration/App/XiaolanYimaTool.swift').exists()
assert not Path('Integration/App/XiaolanDeliveryTool.swift').exists()
print('PASS: common engine/runner/notice/prompt code has no product-role branches or dedicated Yima relay; identity behavior is configured')
PY
