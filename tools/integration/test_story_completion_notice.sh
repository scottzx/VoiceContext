#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
STORY_NOTICE_CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/story-completion-notice.XXXXXX")
trap 'rm -rf "$STORY_NOTICE_CHECK_DIR"' EXIT
# Real player and notice manager, fake audio and isolated host persistence.
# No iOS runtime, microphone, speaker, device, or simulator is used.
sed '/^import AVFoundation$/d' Integration/App/StoryPlaybackController.swift > "$STORY_NOTICE_CHECK_DIR/Player.swift"
sed '/^@main /,$d' tools/integration/test_story_playback.swift > "$STORY_NOTICE_CHECK_DIR/AudioStubs.swift"
sed -n '1,/\/\/ MARK: - Stream Events/p' Vendor/Phone/src/ios/Providers/AgentProvider.swift > "$STORY_NOTICE_CHECK_DIR/AgentTypes.swift"
xcrun swiftc -default-isolation MainActor -D STORY_NOTICE_FLOW \
    "$STORY_NOTICE_CHECK_DIR/AgentTypes.swift" \
    Vendor/Phone/src/ios/AgentKit/AgentRuntimePolicy.swift \
    Vendor/Phone/src/ios/AgentKit/Runtime/AsyncTaskNoticeManager.swift \
    "$STORY_NOTICE_CHECK_DIR/Player.swift" "$STORY_NOTICE_CHECK_DIR/AudioStubs.swift" \
    tools/integration/test_story_completion_notice.swift -o "$STORY_NOTICE_CHECK_DIR/check"
"$STORY_NOTICE_CHECK_DIR/check"
python3 - <<'PY'
from pathlib import Path
view = Path('Integration/App/StoryPlayerView.swift').read_text()
assert '@ObservedObject private var voice = XiaolanVoiceController.shared' in view
assert 'private var completionSessionID: String? { voice.isEnabled ? voice.sessionID : nil }' in view
assert 'player.next(sourceSessionID: completionSessionID)' in view
assert 'player.resume(sourceSessionID: completionSessionID)' in view
assert view.count('player.play(story, sourceSessionID: completionSessionID)') == 2
assert 'createSession' not in view
print('PASS: manual UI play/resume/next use the current enabled voice session, including paused mode, without creating a session')
PY
