#!/bin/zsh
set -euo pipefail

root="${1:-speech_note/speech_note/ModelResources}"
manifest="$root/ModelManifest.json"

[[ -f "$manifest" ]] || { print -u2 "Missing manifest: $manifest"; exit 2; }

python3 - "$manifest" "$root" <<'PY'
import hashlib, json, pathlib, sys

manifest = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
errors = []
for model in json.loads(manifest.read_text()):
    path = root / model["relativePath"]
    if not path.is_file():
        errors.append(f"MISSING  {model['id']}: {path}")
        continue
    expected = model["sha256"].lower()
    if len(expected) != 64 or any(c not in "0123456789abcdef" for c in expected):
        errors.append(f"UNPINNED {model['id']}: SHA-256 must be a 64-character hex digest")
        continue
    expected_size = model.get('sizeBytes')
    if expected_size is not None and path.stat().st_size != expected_size:
        errors.append(f"SIZE     {model['id']}: expected {expected_size}, got {path.stat().st_size}")
        continue
    hasher = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b''):
            hasher.update(chunk)
    digest = hasher.hexdigest()
    if digest != expected:
        errors.append(f"MISMATCH {model['id']}: expected {expected}, got {digest}")
    else:
        print(f"OK       {model['id']}: {digest}")

if errors:
    print("\n".join(errors), file=sys.stderr)
    raise SystemExit(1)
PY
