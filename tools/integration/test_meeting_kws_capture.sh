#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
MEETING_KWS_CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/meeting-kws-capture.XXXXXX")
trap 'rm -rf "$MEETING_KWS_CHECK_DIR"' EXIT
# Pure PCM state-machine checks on the Mac host; no iOS runtime or Simulator.
xcrun swiftc -default-isolation MainActor \
    speech_note/speech_note/Features/Recording/MeetingWakeCommandCapture.swift \
    tools/integration/test_meeting_kws_capture.swift -o "$MEETING_KWS_CHECK_DIR/check"
"$MEETING_KWS_CHECK_DIR/check" "$@"
