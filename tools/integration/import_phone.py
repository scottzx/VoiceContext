#!/usr/bin/env python3
"""Import a committed iOS source snapshot and optional local native build cache.

Run only for the initial import. Subsequent updates require reviewing the local
integration changes; this command refuses to overwrite an existing snapshot.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('source', type=Path)
args = parser.parse_args()
source = args.source.resolve()
dest = ROOT / 'Vendor/Phone'
if dest.exists():
    raise SystemExit('Vendor/Phone already exists; review and merge upstream changes explicitly.')
revision = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
paths = ['src/ios', 'src/apple', 'src/shared', 'scripts', 'deps', 'LICENSE', 'THIRD_PARTY_LICENSES.md', 'BUILDING.md', '.gitmodules']
archive = subprocess.check_output(['git', '-C', str(source), 'archive', revision, *paths])
dest.mkdir(parents=True)
with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
    tar.extractall(dest, filter='data')
# The iSH gitlink needs its own committed source snapshot for reproducible builds.
ish = source / 'deps/ish'
ish_revision = subprocess.check_output(['git', '-C', str(ish), 'rev-parse', 'HEAD'], text=True).strip()
with tarfile.open(fileobj=io.BytesIO(subprocess.check_output(['git', '-C', str(ish), 'archive', ish_revision]))) as tar:
    tar.extractall(dest / 'deps/ish', filter='data')
nested = {}
for relative in ['deps/ish/deps/libapps', 'deps/ish/deps/libarchive']:
    repository = source / relative
    pinned = subprocess.check_output(['git', '-C', str(repository), 'rev-parse', 'HEAD'], text=True).strip()
    with tarfile.open(fileobj=io.BytesIO(subprocess.check_output(['git', '-C', str(repository), 'archive', pinned]))) as tar:
        tar.extractall(dest / relative, filter='data')
    nested[relative] = pinned
snapshot = {'sourceRevision': revision, 'ishRevision': ish_revision, 'nestedSubmodules': nested,
            'excludedSubmodules': {'deps/ish/deps/linux': 'Not used by iOS kernel=ish.', 'deps/proot': 'Android only.'}}
(dest / 'SOURCE_SNAPSHOT.json').write_text(json.dumps(snapshot, indent=2) + '\n')
cache = []
for relative in ['deps/libs', 'deps/include', 'deps/frameworks', 'deps/resources', 'deps/lame-build']:
    p = source / relative
    if p.exists():
        shutil.copytree(p, dest / relative, dirs_exist_ok=True)
        cache.append(relative)
config = dest / 'src/ios/Configs/ProviderCustomization.xcconfig'
shutil.copyfile(config.with_suffix('.xcconfig.example'), config)
# Source generator scripts produce these during the build; do not import credentials.
manifest = {'sourceRevision': revision, 'ishRevision': ish_revision, 'nestedSubmodules': nested,
            'sourcePolicy': 'committed HEAD only; upstream working-tree changes excluded',
            'nativeCache': cache,
            'files': {str(p.relative_to(dest)): hashlib.sha256(p.read_bytes()).hexdigest()
                      for p in dest.rglob('*') if p.is_file() and not any(str(p.relative_to(dest)).startswith(x + '/') for x in cache)}}
(ROOT / 'tools/integration/phone-source-manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
print(f'Imported {len(manifest["files"])} files from {revision}; cached native dependencies locally.')
