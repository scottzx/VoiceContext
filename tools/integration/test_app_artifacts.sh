#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
APP_ARTIFACT_CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/app-artifacts.XXXXXX")
trap 'rm -rf "$APP_ARTIFACT_CHECK_DIR"' EXIT
# Foundation-only host checks: no device or iOS Simulator is launched.
xcrun swiftc -default-isolation MainActor -module-cache-path "$APP_ARTIFACT_CHECK_DIR/modules" \
    Integration/App/AppArtifact.swift tools/integration/test_app_artifacts.swift \
    -o "$APP_ARTIFACT_CHECK_DIR/check"
"$APP_ARTIFACT_CHECK_DIR/check"
