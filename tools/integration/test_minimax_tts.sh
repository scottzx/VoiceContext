#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
MINIMAX_CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/minimax-tts.XXXXXX")
trap 'rm -rf "$MINIMAX_CHECK_DIR"' EXIT
# Exercise the actual adapter and base request builder on the Mac, without
# credentials, network requests, an iOS runtime, or a Simulator.
sed -n '/^final class MiniMaxVoiceProvider/,/^\/\/ MARK: - Doubao/p' \
    Vendor/Phone/src/ios/Providers/Voice/VoiceProvider+Vendors.swift \
    > "$MINIMAX_CHECK_DIR/MiniMaxVoiceProvider.swift"
sed -i '' '1i\
import Foundation\
' "$MINIMAX_CHECK_DIR/MiniMaxVoiceProvider.swift"
xcrun swiftc -default-isolation MainActor \
    Vendor/Phone/src/ios/Providers/Voice/VoiceInputModels.swift \
    Vendor/Phone/src/ios/Providers/Voice/VoiceProvider.swift \
    "$MINIMAX_CHECK_DIR/MiniMaxVoiceProvider.swift" \
    tools/integration/test_minimax_tts.swift -o "$MINIMAX_CHECK_DIR/check"
"$MINIMAX_CHECK_DIR/check"
