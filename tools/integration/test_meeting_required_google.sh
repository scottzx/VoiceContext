#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
MEETING_GOOGLE_CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/meeting-google.XXXXXX")
trap 'rm -rf "$MEETING_GOOGLE_CHECK_DIR"' EXIT
python3 - "$MEETING_GOOGLE_CHECK_DIR" <<'PY'
from pathlib import Path
import sys

root = Path('Vendor/Phone/src/ios/Providers')
out = Path(sys.argv[1])
template = Path('tools/integration/test_meeting_required_google.swift').read_text()

def method(source, signature):
    start = source.index('    ' + signature)
    end = source.index('\n    }', start) + len('\n    }')
    return source[start:end]

# Compile the real protocol extension, all four forwarding/stream implementations,
# error checks, envelopes, and final HTTP serializers. Only transport and unrelated
# message conversion/parser/dependency types are supplied by the host fixture.
(out / 'AgentProvider.swift').write_text((root / 'AgentProvider.swift').read_text())
for name in ['Gemini', 'Antigravity']:
    source = (root / name / f'{name}Provider.swift').read_text()
    signatures = ['func streamWithTools(', 'private func buildRequest(',
                  'private func checkStreamHTTPResponse(', 'func mapError(']
    signatures += ['private func wrapCloudCodeBody('] if name == 'Gemini' else ['private func wrapEnvelope(']
    actual = '\n\n'.join(method(source, signature) for signature in signatures)
    template = template.replace(f'// ACTUAL_{name.upper()}_PROVIDER_METHODS', actual)
    agent = (root / name / f'{name}AgentProvider.swift').read_text()
    template = template.replace(f'// ACTUAL_{name.upper()}_AGENT_METHOD', method(agent, 'func streamAgentMessageClamped('))
assert '// ACTUAL_' not in template
(out / 'GoogleWire.swift').write_text(template)
PY
xcrun swiftc -swift-version 5 -parse-as-library \
    "$MEETING_GOOGLE_CHECK_DIR/AgentProvider.swift" \
    "$MEETING_GOOGLE_CHECK_DIR/GoogleWire.swift" \
    -o "$MEETING_GOOGLE_CHECK_DIR/check"
"$MEETING_GOOGLE_CHECK_DIR/check"
