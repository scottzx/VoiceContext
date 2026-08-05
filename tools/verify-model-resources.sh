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
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if digest != expected:
        errors.append(f"MISMATCH {model['id']}: expected {expected}, got {digest}")
    else:
        print(f"OK       {model['id']}: {digest}")

if errors:
    print("\n".join(errors), file=sys.stderr)
    raise SystemExit(1)
PY
