#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
YIMA_CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/yima-extensions-cli.XXXXXX")
trap 'rm -rf "$YIMA_CHECK_DIR"' EXIT
# Host-only logic checks; never build/run an iOS test or Simulator.
xcrun swiftc -default-isolation MainActor -module-cache-path "$YIMA_CHECK_DIR/modules" \
    Integration/App/CustomExtensionsStore.swift Integration/App/CustomExtensionsCLI.swift \
    Integration/App/CustomExtensionsOffloadBridge.swift tools/integration/test_custom_extensions_cli.swift \
    -o "$YIMA_CHECK_DIR/cli"
"$YIMA_CHECK_DIR/cli"
