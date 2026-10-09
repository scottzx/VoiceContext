#!/bin/zsh
set -euo pipefail

root="${1:-speech_note/speech_note/ModelResources}"
mkdir -p "$root"

python3 - "$root" "${0:A:h}/../speech_note/speech_note/ModelResources" <<'PY'
import hashlib
import json
import pathlib
import shutil
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
source = pathlib.Path(sys.argv[2]).resolve()
manifest = root / 'ModelManifest.json'
if not manifest.is_file():
    for path in source.iterdir():
        if path.is_file() and (path.name == manifest.name or path.suffix in {'.txt', '.md'}):
            shutil.copy2(path, root / path.name)

def matches(path, model):
    if not path.is_file():
        return False
    if model.get('sizeBytes') is not None and path.stat().st_size != model['sizeBytes']:
        return False
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest() == model['sha256'].lower()

for model in json.loads(manifest.read_text()):
    name = model['relativePath']
    if pathlib.PurePosixPath(name).name != name or name in {'.', '..'}:
        raise SystemExit(f'Invalid model filename: {name}')
    url = model.get('downloadURL')
    if not url or not url.startswith('https://'):
        raise SystemExit(f'Missing HTTPS downloadURL: {model["id"]}')
    path = root / name
    if matches(path, model):
        print(f'Already verified: {name}', flush=True)
        continue
    partial = path.with_name(path.name + '.partial')
    if not matches(partial, model):
        if partial.is_file() and model.get('sizeBytes') is not None and partial.stat().st_size >= model['sizeBytes']:
            partial.unlink()
        subprocess.run(['curl', '--fail', '--location', '--continue-at', '-', '--output', str(partial), url], check=True)
    if not matches(partial, model):
        partial.unlink()
        raise SystemExit(f'Model size or SHA-256 mismatch: {name}; run again to retry')
    partial.replace(path)
PY

"${0:A:h}/verify-model-resources.sh" "$root"
