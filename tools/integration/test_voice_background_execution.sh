#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
VOICE_BACKGROUND_CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/voice-background-execution.XXXXXX")
trap 'rm -rf "$VOICE_BACKGROUND_CHECK_DIR"' EXIT
python3 - "$VOICE_BACKGROUND_CHECK_DIR" <<'PY'
from pathlib import Path
import sys

def block(source, declaration):
    assert source.count(declaration) == 1, declaration
    start = source.index(declaration)
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        if source[end] == '{': depth += 1
        if source[end] == '}': depth -= 1
        end += 1
    return source[start:end]

manager = Path('Vendor/Phone/src/ios/Agent/Background/BackgroundKeepAliveManager.swift').read_text()
background = Path('Vendor/Phone/src/ios/Agent/Chat/AIChatViewModel+BackgroundTask.swift').read_text()
vm = Path('Vendor/Phone/src/ios/Agent/Chat/AIChatViewModel.swift').read_text()
voice = Path('Integration/App/XiaolanVoiceController.swift').read_text()
wiring = 'import Foundation\n'
for name, source, declarations in [
    ('XiaolanVoiceController', voice, ['    var isCapturingVoice: Bool']),
    ('BackgroundKeepAliveManager', manager, ['    var enhancedBackgroundEffective: Bool',
                                          '    var canContinueBackgroundExecution: Bool']),
    ('AIChatViewModel', background, ['    func beginBackgroundProcessing()',
                                    '    func waitIfBackgroundSuspended()']),
    ('AIChatViewModel', vm, ['    func markLongBackgroundBrowserTasks()']),
    ('BackgroundInterruptionTracker', manager, ['    func recordInterruption()',
                                               '    func checkOnForeground()']),
]:
    wiring += f'extension {name} {{\n'
    for declaration in declarations:
        wiring += block(source, declaration) + '\n'
    wiring += '}\n'
Path(sys.argv[1], 'ProductionBackgroundExecution.swift').write_text(wiring)
PY
swiftc -swift-version 5 -DVOICE_AGENT_FUSION \
    tools/integration/test_voice_background_execution.swift \
    "$VOICE_BACKGROUND_CHECK_DIR/ProductionBackgroundExecution.swift" \
    -o "$VOICE_BACKGROUND_CHECK_DIR/fusion-test"
"$VOICE_BACKGROUND_CHECK_DIR/fusion-test"
swiftc -swift-version 5 \
    tools/integration/test_voice_background_execution.swift \
    "$VOICE_BACKGROUND_CHECK_DIR/ProductionBackgroundExecution.swift" \
    -o "$VOICE_BACKGROUND_CHECK_DIR/standalone-test"
"$VOICE_BACKGROUND_CHECK_DIR/standalone-test"
