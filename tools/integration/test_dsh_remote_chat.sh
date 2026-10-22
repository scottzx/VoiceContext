#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
DSH_CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/yima-dsh-checks.XXXXXX")
trap 'rm -rf "$DSH_CHECK_DIR"' EXIT

# macOS-host checks only. No iOS application, device or simulator is launched.
xcrun swiftc -D DSH_OFFLINE_TESTS -swift-version 5 -default-isolation MainActor -parse-as-library \
    Vendor/Phone/src/ios/Agent/RemoteDSH/DSHModels.swift \
    Vendor/Phone/src/ios/Agent/RemoteDSH/DSHChatReducer.swift \
    Vendor/Phone/src/ios/Agent/RemoteDSH/DSHClient.swift \
    tools/integration/test_dsh_protocol.swift -o "$DSH_CHECK_DIR/protocol"
"$DSH_CHECK_DIR/protocol"

xcrun swiftc -swift-version 5 -default-isolation MainActor -parse-as-library \
    Vendor/Phone/src/ios/Agent/RemoteDSH/DSHServiceStore.swift \
    tools/integration/test_dsh_service_store.swift -o "$DSH_CHECK_DIR/store"
"$DSH_CHECK_DIR/store"

xcrun swiftc -swift-version 5 -parse-as-library \
    Vendor/Phone/src/ios/Agent/RemoteDSH/DSHModels.swift \
    Vendor/Phone/src/ios/Agent/Chat/AIChatViewModel+DSH.swift \
    tools/integration/test_dsh_chat_driver.swift -o "$DSH_CHECK_DIR/driver"
"$DSH_CHECK_DIR/driver"

python3 tools/integration/test_dsh_cache_policy.py
node tools/integration/test_dsh_tailnet_trust.mjs
