#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
MEETING_WAKE_CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/meeting-wake.XXXXXX")
trap 'rm -rf "$MEETING_WAKE_CHECK_DIR"' EXIT
# Host-only logic checks; never build/run an iOS test or Simulator.
xcrun swiftc -default-isolation MainActor \
    speech_note/speech_note/Features/Recording/MeetingWakeCommandDetector.swift \
    tools/integration/test_meeting_wake_commands.swift -o "$MEETING_WAKE_CHECK_DIR/check"
"$MEETING_WAKE_CHECK_DIR/check"
# Compile the actual bridge without its recording-page view and iOS dependencies.
sed '/^struct MeetingAssistantPanel/,$d' Integration/Recording/MeetingAssistantBridge.swift \
    > "$MEETING_WAKE_CHECK_DIR/MeetingAssistantBridge.swift"
xcrun swiftc -default-isolation MainActor \
    speech_note/speech_note/Features/Recording/MeetingWakeCommandDetector.swift \
    "$MEETING_WAKE_CHECK_DIR/MeetingAssistantBridge.swift" \
    tools/integration/test_meeting_assistant_bridge.swift -o "$MEETING_WAKE_CHECK_DIR/bridge"
"$MEETING_WAKE_CHECK_DIR/bridge"
