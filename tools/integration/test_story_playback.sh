#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
STORY_PLAYBACK_CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/story-playback.XXXXXX")
trap 'rm -rf "$STORY_PLAYBACK_CHECK_DIR"' EXIT
# Execute the real controller with fake audio boundaries; no microphone or
# speaker, iOS device, or simulator is used.
sed '/^import AVFoundation$/d' Integration/App/StoryPlaybackController.swift > "$STORY_PLAYBACK_CHECK_DIR/Player.swift"
xcrun swiftc -default-isolation MainActor -swift-version 5 \
    "$STORY_PLAYBACK_CHECK_DIR/Player.swift" tools/integration/test_story_playback.swift \
    -o "$STORY_PLAYBACK_CHECK_DIR/check"
"$STORY_PLAYBACK_CHECK_DIR/check"
