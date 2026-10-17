#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
INDEPENDENT_INPUT_CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/independent-input.XXXXXX")
trap 'rm -rf "$INDEPENDENT_INPUT_CHECK_DIR"' EXIT
# Production input orchestration and classifier, with an in-memory PCM producer
# and ASR boundary. No microphone, model, iOS runtime or simulator is opened.
sed '/^\/\/\/ The real-time callback/,$d; /^@preconcurrency import AVFoundation$/d' \
    Integration/Recording/IndependentVoiceInput.swift > "$INDEPENDENT_INPUT_CHECK_DIR/Input.swift"
xcrun swiftc -default-isolation MainActor -swift-version 5 \
    speech_note/speech_note/Features/Recording/MeetingWakeCommandText.swift \
    "$INDEPENDENT_INPUT_CHECK_DIR/Input.swift" \
    tools/integration/test_independent_voice_input.swift \
    -o "$INDEPENDENT_INPUT_CHECK_DIR/check"
"$INDEPENDENT_INPUT_CHECK_DIR/check"
