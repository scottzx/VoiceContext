#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
APP_PRESENTATION_CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/app-presentation.XXXXXX")
trap 'rm -rf "$APP_PRESENTATION_CHECK_DIR"' EXIT
sed -n '1,/\/\/ MARK: - Agent Messages/p' Vendor/Phone/src/ios/Providers/AgentProvider.swift > "$APP_PRESENTATION_CHECK_DIR/AgentToolTypes.swift"
# Production presentation logic runs against isolated host fixtures only.
xcrun swiftc -default-isolation MainActor -module-cache-path "$APP_PRESENTATION_CHECK_DIR/modules" \
    "$APP_PRESENTATION_CHECK_DIR/AgentToolTypes.swift" \
    Vendor/Phone/src/ios/AgentKit/AgentRuntimePolicy.swift \
    Integration/App/AppArtifact.swift Integration/App/AppArtifactStore.swift Integration/App/AppPresentationTool.swift \
    tools/integration/test_app_presentation.swift -o "$APP_PRESENTATION_CHECK_DIR/check"
"$APP_PRESENTATION_CHECK_DIR/check"
