#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
MEETING_ASYNC_CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/meeting-async.XXXXXX")
trap 'rm -rf "$MEETING_ASYNC_CHECK_DIR"' EXIT
# Exercise the actual notice drain, iOS adapter resume, meeting reply callbacks
# and bridge on the Mac. Provider/player/storage boundaries remain in memory.
sed -n '1,/\/\/ MARK: - Stream Events/p' Vendor/Phone/src/ios/Providers/AgentProvider.swift > "$MEETING_ASYNC_CHECK_DIR/ToolTypes.swift"
sed '/^struct MeetingAssistantPanel/,$d' Integration/Recording/MeetingAssistantBridge.swift > "$MEETING_ASYNC_CHECK_DIR/Bridge.swift"
sed '/^@main struct/,$d' tools/integration/test_meeting_assistant_bridge.swift > "$MEETING_ASYNC_CHECK_DIR/Fixture.swift"
python3 - "$MEETING_ASYNC_CHECK_DIR" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
def method(source, name, access='private '):
    start = source.index('    ' + access + 'func ' + name + '(')
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        if source[end] == '{': depth += 1
        if source[end] == '}': depth -= 1
        end += 1
    return source[start:end]
controller = Path('Integration/App/MeetingAssistantController.swift').read_text()
names = ['installAsyncReplies', 'prepareBackgroundReply', 'finishBackgroundReply']
root.joinpath('Controller.swift').write_text('import Foundation\nimport Combine\nextension MeetingAssistantController {\n' + '\n'.join(method(controller, n) for n in names) + '''
    func installForCheck() { installAsyncReplies() }
    func authorizeForCheck(sessionID: String) {
        replyAuthorizations[sessionID] = .init(generation: bridge.responseGeneration, systemPrompt: "会议总管；语音只用 answer_user")
    }
}
''')
runner = Path('Vendor/Phone/src/ios/AgentKit/Runtime/IOSAgentSessionRunner.swift').read_text()
root.joinpath('Runner.swift').write_text('import Foundation\nextension IOSAgentSessionRunner {\n' + method(runner, 'resumeAfterAsyncToolResults', '') + '\n}\n')
manager = Path('Vendor/Phone/src/ios/AgentKit/Runtime/AsyncTaskNoticeManager.swift').read_text()
root.joinpath('Manager.swift').write_text('import Foundation\nextension AsyncTaskNoticeManager {\n' + method(manager, 'checkAndDrain', 'public ') + '\n}\n')
PY
xcrun swiftc -default-isolation MainActor -swift-version 5 \
    "$MEETING_ASYNC_CHECK_DIR/ToolTypes.swift" \
    Vendor/Phone/src/ios/AgentKit/Runtime/AgentSessionRunner.swift \
    Integration/App/MeetingAnswerUserTool.swift \
    speech_note/speech_note/Features/Recording/MeetingWakeCommandText.swift \
    "$MEETING_ASYNC_CHECK_DIR/Bridge.swift" "$MEETING_ASYNC_CHECK_DIR/Fixture.swift" \
    "$MEETING_ASYNC_CHECK_DIR/Controller.swift" "$MEETING_ASYNC_CHECK_DIR/Runner.swift" \
    "$MEETING_ASYNC_CHECK_DIR/Manager.swift" tools/integration/test_meeting_async_reply.swift \
    -o "$MEETING_ASYNC_CHECK_DIR/check"
"$MEETING_ASYNC_CHECK_DIR/check"
