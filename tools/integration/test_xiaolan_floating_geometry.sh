#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
XIAOLAN_FLOATING_CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/xiaolan-floating.XXXXXX")
trap 'rm -rf "$XIAOLAN_FLOATING_CHECK_DIR"' EXIT
# Host-only placement checks: no iOS application or Simulator is launched.
xcrun swiftc -default-isolation MainActor -module-cache-path "$XIAOLAN_FLOATING_CHECK_DIR/modules" \
    Integration/App/XiaolanFloatingGeometry.swift tools/integration/test_xiaolan_floating_geometry.swift \
    -o "$XIAOLAN_FLOATING_CHECK_DIR/check"
"$XIAOLAN_FLOATING_CHECK_DIR/check"
