#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
XIAOLAN_ACK_CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/xiaolan-ack.XXXXXX")
trap 'rm -rf "$XIAOLAN_ACK_CHECK_DIR"' EXIT
# Remove only the framework import; fake SDK types ensure no speech is played.
sed '/^import AVFoundation$/d' Integration/App/XiaolanVoiceAcknowledgement.swift > "$XIAOLAN_ACK_CHECK_DIR/XiaolanVoiceAcknowledgement.swift"
xcrun swiftc -swift-version 6 -default-isolation MainActor -strict-concurrency=complete \
    "$XIAOLAN_ACK_CHECK_DIR/XiaolanVoiceAcknowledgement.swift" \
    tools/integration/test_xiaolan_acknowledgement.swift -o "$XIAOLAN_ACK_CHECK_DIR/check"
"$XIAOLAN_ACK_CHECK_DIR/check"
