#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
APP_NAVIGATION_CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/app-navigation.XXXXXX")
trap 'rm -rf "$APP_NAVIGATION_CHECK_DIR"' EXIT
sed -n '1,/\/\/ MARK: - Agent Messages/p' Vendor/Phone/src/ios/Providers/AgentProvider.swift > "$APP_NAVIGATION_CHECK_DIR/AgentToolTypes.swift"
# Host-only logic checks; no iOS application, device or Simulator is launched.
xcrun swiftc -default-isolation MainActor -module-cache-path "$APP_NAVIGATION_CHECK_DIR/modules" \
    "$APP_NAVIGATION_CHECK_DIR/AgentToolTypes.swift" \
    Vendor/Phone/src/ios/AgentKit/AgentRuntimePolicy.swift \
    Integration/App/CustomExtensionsStore.swift Integration/App/AppNavigationCenter.swift Integration/App/AppNavigationTool.swift \
    tools/integration/test_app_navigation.swift -o "$APP_NAVIGATION_CHECK_DIR/check"
"$APP_NAVIGATION_CHECK_DIR/check"
