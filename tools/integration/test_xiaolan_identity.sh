#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
XIAOLAN_IDENTITY_CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/xiaolan-identity.XXXXXX")
trap 'rm -rf "$XIAOLAN_IDENTITY_CHECK_DIR"' EXIT
python3 - "$XIAOLAN_IDENTITY_CHECK_DIR" <<'PY'
from pathlib import Path
import subprocess,sys
out=Path(sys.argv[1])
path='Vendor/Phone/src/ios/Agent/Session/SoulStore.swift'
def section(s):
    return s[s.index('enum SystemPromptBuilder {'):s.index('// MARK: - Reusable SwiftUI text view')]
out.joinpath('Current.swift').write_text('import Foundation\n'+section(Path(path).read_text()))
old=subprocess.run(['git','show','HEAD:'+path],check=True,capture_output=True,text=True).stdout
out.joinpath('Baseline.swift').write_text('import Foundation\n'+section(old).replace('enum SystemPromptBuilder {','enum BaselinePromptBuilder {',1))
PY
xcrun swiftc -default-isolation MainActor \
    "$XIAOLAN_IDENTITY_CHECK_DIR/Current.swift" "$XIAOLAN_IDENTITY_CHECK_DIR/Baseline.swift" \
    Integration/App/VoiceAgentPrompt.swift \
    tools/integration/test_xiaolan_identity.swift -o "$XIAOLAN_IDENTITY_CHECK_DIR/check"
"$XIAOLAN_IDENTITY_CHECK_DIR/check"
