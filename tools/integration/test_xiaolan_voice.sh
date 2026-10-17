#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
XIAOLAN_VOICE_CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/xiaolan-voice.XXXXXX")
trap 'rm -rf "$XIAOLAN_VOICE_CHECK_DIR"' EXIT
# Execute the production controller against in-memory microphone/model/player
# boundaries on macOS. No iOS device, simulator or microphone is opened.
sed '/^import AVFoundation$/d; /^import VoiceRecording$/d' Integration/App/XiaolanVoiceController.swift > "$XIAOLAN_VOICE_CHECK_DIR/Controller.swift"
sed -n '1,/\/\/ MARK: - Agent Messages/p' Vendor/Phone/src/ios/Providers/AgentProvider.swift > "$XIAOLAN_VOICE_CHECK_DIR/Tools.swift"
xcrun swiftc -default-isolation MainActor -swift-version 5 \
    "$XIAOLAN_VOICE_CHECK_DIR/Tools.swift" \
    Vendor/Phone/src/ios/AgentKit/Runtime/AgentSessionRunner.swift \
    Vendor/Phone/src/ios/AgentKit/AgentRuntimePolicy.swift \
    Integration/App/MeetingAnswerUserTool.swift \
    "$XIAOLAN_VOICE_CHECK_DIR/Controller.swift" \
    tools/integration/test_xiaolan_voice.swift \
    -o "$XIAOLAN_VOICE_CHECK_DIR/check"
"$XIAOLAN_VOICE_CHECK_DIR/check"
