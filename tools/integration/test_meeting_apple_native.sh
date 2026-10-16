#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
MEETING_APPLE_CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/meeting-apple.XXXXXX")
trap 'rm -rf "$MEETING_APPLE_CHECK_DIR"' EXIT
sed -n '1,/\/\/ MARK: - Agent Messages/p' Vendor/Phone/src/ios/Providers/AgentProvider.swift > "$MEETING_APPLE_CHECK_DIR/AgentToolTypes.swift"
xcrun swiftc -default-isolation MainActor \
    "$MEETING_APPLE_CHECK_DIR/AgentToolTypes.swift" \
    Integration/App/MeetingAppleTool.swift tools/integration/test_meeting_apple_native.swift \
    -o "$MEETING_APPLE_CHECK_DIR/check"
"$MEETING_APPLE_CHECK_DIR/check"
python3 - <<'PY'
from pathlib import Path
bridge = Path('Integration/NativeOffloads/MeetingAppleNativeBridge.m').read_text()
assert 'dispatch_queue_create' in bridge and 'DISPATCH_QUEUE_SERIAL' in bridge
assert 'mkstemp' in bridge and 'unlink(template)' in bridge and '256 * 1024' in bridge
for forbidden in ['native_offload_exec(', 'ISHShellExecutor', 'posix_spawn(', 'system(', 'popen(']:
    assert forbidden not in bridge
for stem, name in [('Calendar','calendar'),('Reminders','reminders'),('Location','location'),('Maps','maps'),('Weather','weather'),('Device','device')]:
    source = Path(f'Vendor/Phone/src/ios/NativeOffloads/{stem}Offload.m').read_text()
    start = source.index(f'int {name}_offload_execute_direct(')
    direct = source[start:source.index('\n}',start)]
    assert f'return {name}_handler(argc, argv, -1, stdout_fd, stderr_fd);' in direct
    assert f'@"apple-{name}"' in bridge
for forbidden in ['apple-speech', 'apple-player', 'apple-speak', 'browser-use', 'apple-open']:
    assert forbidden not in bridge
print('Native routing checks passed: same handlers, serial queue, file-backed bounded result, no guest/shell/audio/browser dispatch')
PY
