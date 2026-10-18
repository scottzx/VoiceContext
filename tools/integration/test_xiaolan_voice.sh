#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
XIAOLAN_VOICE_CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/xiaolan-voice.XXXXXX")
trap 'rm -rf "$XIAOLAN_VOICE_CHECK_DIR"' EXIT
# Execute the production controller against in-memory microphone/model/player
# boundaries on macOS. No iOS device, simulator or microphone is opened.
sed '/^import AVFoundation$/d; /^import VoiceRecording$/d' Integration/App/XiaolanVoiceController.swift > "$XIAOLAN_VOICE_CHECK_DIR/Controller.swift"
sed -n '1,/\/\/ MARK: - Agent Messages/p' Vendor/Phone/src/ios/Providers/AgentProvider.swift > "$XIAOLAN_VOICE_CHECK_DIR/Tools.swift"
# Exercise the actual compaction cleanup, including cancellation ownership,
# without copying its state-restoration rule into the test VM.
python3 - "$XIAOLAN_VOICE_CHECK_DIR/CompactionCleanup.swift" <<'PY'
from pathlib import Path
import re
import sys

source = Path('Vendor/Phone/src/ios/Agent/Chat/AIChatViewModel+Compaction.swift').read_text()
matches = list(re.finditer(r'        defer \{\n            isCompacting = false\n', source))
assert len(matches) == 1, 'Expected one production compaction state cleanup'
start = matches[0].start()
opening = source.index('{', start)
depth, end = 1, opening + 1
while depth:
    if source[end] == '{': depth += 1
    if source[end] == '}': depth -= 1
    end += 1
Path(sys.argv[1]).write_text('''import Foundation
extension HostVM {
    func runCompactionCleanup(wasProcessingOnEntry: Bool, wait: () async -> Void) async {
        isCompacting = true
        isProcessing = true
''' + source[start:end] + '''
        await wait()
    }
}
''')
PY
xcrun swiftc -default-isolation MainActor -swift-version 5 \
    "$XIAOLAN_VOICE_CHECK_DIR/Tools.swift" \
    Vendor/Phone/src/ios/AgentKit/Runtime/AgentSessionRunner.swift \
    Vendor/Phone/src/ios/AgentKit/AgentRuntimePolicy.swift \
    Integration/App/MeetingAnswerUserTool.swift \
    "$XIAOLAN_VOICE_CHECK_DIR/Controller.swift" \
    "$XIAOLAN_VOICE_CHECK_DIR/CompactionCleanup.swift" \
    tools/integration/test_xiaolan_voice.swift \
    -o "$XIAOLAN_VOICE_CHECK_DIR/check"
"$XIAOLAN_VOICE_CHECK_DIR/check"
