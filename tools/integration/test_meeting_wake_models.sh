#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK_DIR="$ROOT/build/meeting-wake-model-checks"
MODEL_DIR="$ROOT/speech_note/speech_note/MeetingWakeModels"
mkdir -p "$CHECK_DIR"
ditto "$MODEL_DIR" "$CHECK_DIR/MeetingWakeModels"
swiftc -swift-version 6 -parse-as-library \
  "$ROOT/speech_note/speech_note/Infrastructure/Inference/ModelIntegrity.swift" \
  "$ROOT/speech_note/speech_note/Infrastructure/Inference/MeetingWakeModelResources.swift" \
  "$ROOT/tools/integration/test_meeting_wake_models.swift" \
  -o "$CHECK_DIR/checks"
"$CHECK_DIR/checks" "$MODEL_DIR"
python3 - "$ROOT" <<'PY'
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1])
models = root / 'speech_note/speech_note/MeetingWakeModels'
manifest = json.loads((models / 'MeetingWakeManifest.json').read_text())
assert {x['relativePath'] for x in manifest} == {
    'encoder.onnx', 'decoder.onnx', 'joiner.onnx', 'tokens.txt', 'keywords.txt'
}
for artifact in manifest:
    contents = (models / artifact['relativePath']).read_bytes()
    assert len(contents) == artifact['sizeBytes']
    assert hashlib.sha256(contents).hexdigest() == artifact['sha256']
tokens = {line.split()[0] for line in (models / 'tokens.txt').read_text().splitlines()}
keyword = (models / 'keywords.txt').read_text().split()
assert keyword == ['x', 'iǎo', 'l', 'án', 't', 'óng', 'x', 'ué', '@小蓝同学']
assert all(token in tokens for token in keyword[:-1])
assert 'Apache License' in (models / 'LICENSE.txt').read_text()
assert 'license: Apache License 2.0' in (models / 'UPSTREAM_MODEL_CARD.md').read_text()
download_manifest = json.loads((root / 'speech_note/speech_note/ModelResources/ModelManifest.json').read_text())
assert len(download_manifest) == 4 and all('meeting-wake' not in x['id'] for x in download_manifest)

for project, target_name in [
    ('Vendor/Phone/src/ios/VoiceContextAgent.xcodeproj/project.pbxproj', 'VoiceContextAgent'),
    ('speech_note/speech_note.xcodeproj/project.pbxproj', 'speech_note')
]:
    data = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(root / project)]))
    objects = data['objects']
    target = next(obj for obj in objects.values() if obj.get('isa') == 'PBXNativeTarget' and obj['name'] == target_name)
    resources = next(objects[key] for key in target['buildPhases'] if objects[key]['isa'] == 'PBXResourcesBuildPhase')
    references = [objects[objects[key]['fileRef']] for key in resources['files']]
    folders = [ref for ref in references if ref.get('path', '').endswith('speech_note/MeetingWakeModels')]
    assert len(folders) == 1 and folders[0]['lastKnownFileType'] == 'folder', project
print('Meeting wake model manifest, phonetic vocabulary, and project packaging checks passed')
PY
