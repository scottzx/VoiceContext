#!/usr/bin/env python3
"""Prepare synthetic upstream trees for a three-way merge into Vendor/Phone.

The product keeps the imported Phone sources under Vendor/Phone, so the
upstream history cannot be merged directly. This tool builds two synthetic
commits in the product repository:

- base commit: the imported upstream baseline content at the Vendor/Phone
  paths, everything else kept from the current product tree;
- target commit: the new upstream content at the same paths.

Merging the target commit into the product branch then compares the product
fork against the upstream baseline and the new upstream release, so upstream
renames, deletions and additions are resolved by git instead of by hand.
"""
import argparse
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# Upstream path prefix -> product path prefix.
DIR_MAP = [
    ('src/ios/', 'Vendor/Phone/src/ios/'),
    ('src/shared/', 'Vendor/Phone/src/shared/'),
    ('scripts/', 'Vendor/Phone/scripts/'),
    ('deps/', 'Vendor/Phone/deps/'),
]
FILE_MAP = {
    '.gitmodules': 'Vendor/Phone/.gitmodules',
    'BUILDING.md': 'Vendor/Phone/BUILDING.md',
    'LICENSE': 'Vendor/Phone/LICENSE',
    'THIRD_PARTY_LICENSES.md': 'Vendor/Phone/THIRD_PARTY_LICENSES.md',
}
# Submodules are vendored or out of scope and are merged separately.
SKIP_PATHS = {'deps/ish', 'deps/proot'}


def git(*args, check=True):
    result = subprocess.run(['git', *args], cwd=ROOT, capture_output=True, text=True)
    if check and result.returncode:
        raise SystemExit(result.stderr.strip())
    return result.stdout


def mapped(path):
    if path in FILE_MAP:
        return FILE_MAP[path]
    for source, target in DIR_MAP:
        if path.startswith(source):
            return target + path[len(source):]
    return None


def upstream_tree(revision):
    """Return {upstream path: (mode, blob)} for the paths in the merge scope."""
    paths = [path for path, _ in DIR_MAP] + list(FILE_MAP)
    entries = {}
    for prefix in paths:
        output = git('ls-tree', '-r', '-z', revision, '--', prefix)
        for record in output.split('\0'):
            if not record:
                continue
            meta, path = record.split('\t', 1)
            mode, kind, blob = meta.split()
            if kind != 'blob' or path in SKIP_PATHS:
                continue
            entries[path] = (mode, blob)
    return entries


def apply_to_index(tree, entries, remove_missing):
    git('read-tree', tree)
    for path, (mode, blob) in entries.items():
        target = mapped(path)
        git('update-index', '--add', '--cacheinfo', f'{mode},{blob},{target}')
    if remove_missing:
        for path in remove_missing:
            target = mapped(path)
            if target:
                git('update-index', '--force-remove', target)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--base', required=True, help='upstream baseline revision')
    parser.add_argument('--target', required=True, help='upstream target revision')
    parser.add_argument('--base-commit', help='write the base commit to this ref')
    parser.add_argument('--target-commit', help='write the target commit to this ref')
    parser.add_argument('--manifest', help='write the merged path manifest here')
    args = parser.parse_args()

    base_entries = upstream_tree(args.base)
    target_entries = upstream_tree(args.target)
    removed = sorted(set(base_entries) - set(target_entries))

    base_commit = git('rev-parse', 'HEAD').strip()
    apply_to_index(base_commit, base_entries, remove_missing=[])
    base_tree = git('write-tree').strip()
    base_id = git('commit-tree', base_tree, '-p', base_commit,
                  '-m', 'synthetic upstream baseline ' + args.base).strip()

    apply_to_index(base_tree, target_entries, remove_missing=removed)
    target_tree = git('write-tree').strip()
    target_id = git('commit-tree', target_tree, '-p', base_id,
                    '-m', 'synthetic upstream target ' + args.target).strip()

    if args.base_commit:
        git('update-ref', args.base_commit, base_id)
    if args.target_commit:
        git('update-ref', args.target_commit, target_id)
    if args.manifest:
        manifest = {
            'repository': 'https://github.com/OpenMinis/OpenMinis.git',
            'fromRevision': git('rev-parse', args.base).strip(),
            'toRevision': git('rev-parse', args.target).strip(),
            'scope': 'iOS and imported shared build dependencies; excludes Android-only sources',
            'files': [],
        }
        for path in sorted(set(base_entries) | set(target_entries)):
            manifest['files'].append({
                'path': path,
                'productPath': mapped(path),
                'upstreamBlob': (target_entries.get(path) or base_entries.get(path))[1],
                'disposition': 'removed' if path in removed else 'merged',
            })
        Path(args.manifest).write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')

    print('base commit   ', base_id)
    print('target commit ', target_id)
    print('scoped paths  ', len(set(base_entries) | set(target_entries)),
          '(removed upstream:', len(removed), ')')


if __name__ == '__main__':
    main()
