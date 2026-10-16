#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
MEETING_MODEL_CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/meeting-model.XXXXXX")
trap 'rm -rf "$MEETING_MODEL_CHECK_DIR"' EXIT
# Compile the actual availability/binding methods and router on the Mac;
# store/credential dependencies are in-memory fakes, without any iOS runtime.
python3 - "$MEETING_MODEL_CHECK_DIR" <<'PY'
from pathlib import Path
import sys

def method(source, name):
    start = source.index(name)
    start = source.rfind('\n', 0, start) + 1
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        if source[end] == '{': depth += 1
        if source[end] == '}': depth -= 1
        end += 1
    return source[start:end]

out = Path(sys.argv[1])
source = Path('Vendor/Phone/src/ios/Agent/Chat/AIChatViewModel+Persistence.swift').read_text()
names = ['func createInitialBinding(', 'func resolveInitialPrimaryGroupEntry(',
         'func resolveLastUsedEntry(', 'func resolveLatestProviderTextEntry(',
         'func isTextOutputModel(']
methods = '\n\n'.join(method(source, name) for name in names)
(out / 'BindingMethods.swift').write_text('''import Foundation
private let logger = AppLogger(category: "AIChatVM")
extension AIChatViewModel {
''' + methods + '''
    func testCreateBinding(_ id: String = "new-session") async {
        await createInitialBinding(for: id)
    }
}
''')
controller = Path('Integration/App/MeetingAssistantController.swift').read_text()
(out / 'Availability.swift').write_text('import Foundation\n@MainActor enum MeetingAssistantController {\n'
    + method(controller, 'func modelUnavailableReason(') + '\n}\n')
PY
xcrun swiftc -default-isolation MainActor \
    Vendor/Phone/src/ios/Providers/ModelGroup.swift \
    Vendor/Phone/src/ios/Providers/ModelGroupRouter.swift \
    "$MEETING_MODEL_CHECK_DIR/BindingMethods.swift" \
    "$MEETING_MODEL_CHECK_DIR/Availability.swift" \
    tools/integration/test_meeting_model_availability.swift \
    -o "$MEETING_MODEL_CHECK_DIR/check"
"$MEETING_MODEL_CHECK_DIR/check"
