#!/usr/bin/env python3
"""Merge the upstream v1.15 Xcode project into the product's imported project.

The product keeps a forked `Minis.xcodeproj` (extra targets, synced source
groups for fork-only directories, product build settings). Upstream v1.15
rewrote its own project: new split source files, folder-synced groups, the
FFmpeg/libav xcframeworks and a test host target.

This tool takes the fork project as the base and unions upstream's additions
into it, then prunes file references whose files no longer exist (sources the
merge deleted or renamed). Build settings that identify the product
(bundle ids, team, version) stay as the fork set them.
"""
import json
import plistlib
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PHONE = ROOT / 'Vendor/Phone/src/ios'
PROJECT = PHONE / 'Minis.xcodeproj/project.pbxproj'
UPSTREAM = 'openminis/main:src/ios/Minis.xcodeproj/project.pbxproj'
FORK_REV = ':2:Vendor/Phone/src/ios/Minis.xcodeproj/project.pbxproj'

# Product-owned settings the fork must keep.
IDENTITY_KEYS = {'PRODUCT_BUNDLE_IDENTIFIER', 'DEVELOPMENT_TEAM', 'MARKETING_VERSION',
                 'CURRENT_PROJECT_VERSION', 'CODE_SIGN_ENTITLEMENTS', 'INFOPLIST_FILE'}
# Source files upstream v1.15 added that this product deliberately does not
# compile: their types duplicate the shared domain model in
# src/apple/Domain/ChatPersistence.swift (see the upstream integration notes).
EXCLUDED_SOURCES = {
    # ChatStore stays the fork's single implementation. Upstream v1.15 split it
    # across the files below; compiling those as well would redeclare members.
    # AIChatViewModel was restructured onto upstream's split files, with the
    # fork's stored state and fusion behavior ported into them, so those files
    # stay in the target.
    'ChatStoreModels.swift',
    'ChatStore+BackupRestore.swift', 'ChatStore+CompactMarkers.swift',
    'ChatStore+Folders.swift', 'ChatStore+Helpers.swift',
    'ChatStore+Maintenance.swift', 'ChatStore+Media.swift',
    'ChatStore+Messages.swift', 'ChatStore+Schema.swift',
    'ChatStore+Search.swift', 'ChatStore+SessionCRUD.swift',
    'ChatStore+SessionDeletion.swift', 'ChatStore+SessionList.swift',
    'ChatStore+SessionQueries.swift', 'ChatStore+StoredPreview.swift',
    'ChatStore+SyncDirty.swift', 'ChatStore+SyncRemoteSessions.swift',
    'ChatStore+Tombstones.swift', 'ChatStore+UsageStats.swift',
    'ChatStore+WebAppShortcuts.swift',
}


def plutil_json(path_or_bytes):
    result = subprocess.run(['plutil', '-convert', 'json', '-o', '-', '-'],
                            input=path_or_bytes, capture_output=True)
    if result.returncode:
        raise SystemExit(result.stderr.decode())
    return json.loads(result.stdout)


def upstream_objects():
    raw = subprocess.run(['git', 'show', UPSTREAM], cwd=ROOT, capture_output=True, check=True).stdout
    return plutil_json(raw)['objects']


def fork_objects():
    raw = subprocess.run(['git', 'show', FORK_REV], cwd=ROOT, capture_output=True, check=True).stdout
    return plutil_json(raw)['objects']


def main():
    project = plutil_json(subprocess.run(['git', 'show', FORK_REV], cwd=ROOT,
                                         capture_output=True, check=True).stdout)
    root_object_id = project['rootObject']
    up = upstream_objects()
    fork = fork_objects()
    merged = json.loads(json.dumps(fork))

    # Phase ids belonging to upstream targets the product does not build.
    skip_targets = {key for key, value in up.items()
                    if value.get('isa') == 'PBXNativeTarget' and value['name'] not in
                    {'Minis', 'MinisShare', 'AgentWidgetExtension', 'MinisFileProvider',
                     'MinisTests', 'MinisUITests'}}
    skip_phases = set()
    skip_config_lists = set()
    skip_products = set()
    skip_proxies = set()
    for target in skip_targets:
        skip_phases.update(up[target].get('buildPhases', []))
        skip_config_lists.add(up[target]['buildConfigurationList'])
        if up[target].get('productReference'):
            skip_products.add(up[target]['productReference'])
        skip_proxies.update(up[target].get('dependencies', []))
    skip_configs = set()
    for config_list in skip_config_lists:
        skip_configs.update(up[config_list].get('buildConfigurations', []))
    skip_proxies.update(key for key, value in up.items()
                        if value.get('isa') == 'PBXContainerItemProxy'
                        and value.get('remoteGlobalIDString') in skip_targets)
    skip_objects = skip_targets | skip_phases | skip_config_lists | skip_configs | skip_products | skip_proxies

    # Copy upstream-only objects we keep.
    added = set()
    for key, value in up.items():
        if key in merged or key in skip_objects:
            continue
        merged[key] = value
        added.add(key)

    # Build files whose file reference existed only upstream: drop if it is not
    # coming along, or if it points at an excluded/duplicate source.
    def file_ref_path(ref_id, seen=None):
        """Resolve a file reference to a path relative to src/ios."""
        ref = merged.get(ref_id) or up.get(ref_id) or fork.get(ref_id)
        if not ref:
            return None
        tree = ref.get('sourceTree', '<group>')
        path = ref.get('path', '')
        if tree == 'SOURCE_ROOT':
            return path
        if tree == '<group>':
            for group_id, group in merged.items():
                if group.get('isa') in ('PBXGroup', 'PBXVariantGroup') and ref_id in group.get('children', []):
                    parent = group.get('path', '')
                    base = file_ref_path(group_id) if group.get('sourceTree') == '<group>' and parent else parent
                    if parent:
                        return str(Path(parent) / path) if path else parent
                    return path
        return path

    dropped = set()
    for key in list(added):
        value = merged[key]
        if value.get('isa') == 'PBXBuildFile':
            ref = value.get('fileRef')
            if ref and ref not in merged:
                dropped.add(key)
                continue
            path = file_ref_path(ref) if ref else None
            if path and Path(path).name in EXCLUDED_SOURCES:
                dropped.add(key)
    for key in dropped:
        merged.pop(key, None)
    added -= dropped

    # Union build-phase memberships for phases both sides have.
    for key, value in up.items():
        if value.get('isa') != 'PBXBuildPhase' or key not in merged:
            continue
        existing = merged[key].setdefault('files', [])
        for build_id in value.get('files', []):
            if build_id in merged and build_id not in existing:
                existing.append(build_id)

    # Union group children so new upstream files stay navigable.
    for key, value in up.items():
        if value.get('isa') not in ('PBXGroup', 'PBXVariantGroup') or key not in merged:
            continue
        existing = merged[key].setdefault('children', [])
        for child in value.get('children', []):
            if child in merged and child not in existing:
                existing.append(child)

    # Union the app target's synced groups and build phases.
    for key, value in up.items():
        if value.get('isa') != 'PBXNativeTarget' or key not in merged:
            continue
        for field in ('fileSystemSynchronizedGroups', 'buildPhases', 'dependencies'):
            existing = merged[key].setdefault(field, [])
            for child in value.get(field, []):
                if child in merged and child not in existing:
                    existing.append(child)

    # Adopt upstream's changes to shared objects, keeping product identity.
    for key, value in up.items():
        if key not in fork or key in skip_objects:
            continue
        if value == fork[key]:
            continue
        if value.get('isa') == 'XCBuildConfiguration':
            settings = merged[key]['buildSettings']
            for name, upstream_value in value.get('buildSettings', {}).items():
                if name in IDENTITY_KEYS:
                    continue
                settings[name] = upstream_value
            continue
        if value.get('isa') in ('PBXFileReference', 'PBXVariantGroup'):
            merged[key] = value
            continue
        # Groups, phases, targets and the project object were merged above.
        merged[key] = {**merged[key], **{k: v for k, v in value.items()
                                        if k in ('path', 'name', 'productType', 'productName')}}

    # Prune references to files the merge removed or renamed. Resolve paths by
    # walking the group tree from the root group, which is how Xcode does it:
    # a group's path prefixes its children unless the child re-roots itself.
    root = merged[root_object_id]['mainGroup']
    resolved_paths = {}

    def walk(group_id, base):
        group = merged.get(group_id)
        if not group:
            return
        tree = group.get('sourceTree', '<group>')
        path = group.get('path', '')
        current = base
        if tree == 'SOURCE_ROOT':
            current = ''
        if path:
            current = str(Path(current) / path) if current else path
        for child in group.get('children', []):
            node = merged.get(child)
            if not node:
                continue
            kind = node.get('isa')
            if kind == 'PBXFileSystemSynchronizedRootGroup':
                node_path = node.get('path', '')
                resolved_paths[child] = str(Path(current) / node_path) if current else node_path
                continue
            if kind in ('PBXGroup',):
                walk(child, current)
                continue
            if kind in ('PBXFileReference', 'PBXVariantGroup'):
                child_tree = node.get('sourceTree', '<group>')
                child_path = node.get('path', '')
                if child_tree == 'SOURCE_ROOT':
                    resolved_paths[child] = child_path
                elif child_tree == '<group>':
                    resolved_paths[child] = str(Path(current) / child_path) if current and child_path else child_path
                if kind == 'PBXVariantGroup':
                    for grandchild in node.get('children', []):
                        grand = merged.get(grandchild, {})
                        grand_path = grand.get('path', '')
                        if grand_path:
                            resolved_paths[grandchild] = str(Path(current) / grand_path) if current else grand_path
                continue
            if kind in ('PBXBuildFile', 'PBXBuildPhase'):
                continue
            # Anything else that still names a path (e.g. package products).
            if node.get('path'):
                resolved_paths[child] = node['path']

    walk(root, '')

    present = {str(p.relative_to(PHONE)) for p in PHONE.rglob('*') if p.is_file()}
    present_dirs = {str(p.relative_to(PHONE)) for p in PHONE.rglob('*') if p.is_dir()}

    removed_refs = set()
    for ref_id, ref in merged.items():
        if ref.get('isa') != 'PBXFileReference':
            continue
        tree = ref.get('sourceTree', '<group>')
        if tree in ('BUILT_PRODUCTS_DIR', 'SDKROOT', 'DEVELOPER_DIR'):
            continue
        path = resolved_paths.get(ref_id)
        if path is None:
            continue
        if path in present or path in present_dirs:
            continue
        removed_refs.add(ref_id)
    for ref_id in removed_refs:
        merged.pop(ref_id, None)
    for key, value in list(merged.items()):
        kind = value.get('isa')
        if kind in ('PBXGroup', 'PBXVariantGroup'):
            value['children'] = [c for c in value.get('children', []) if c not in removed_refs]
        elif kind == 'PBXBuildFile':
            if value.get('fileRef') in removed_refs:
                merged.pop(key, None)
        elif kind.endswith('BuildPhase') or kind == 'PBXBuildPhase':
            value['files'] = [f for f in value.get('files', []) if f in merged]

    # Drop the excluded duplicate source from the sources phases too.
    for key, value in list(merged.items()):
        if value.get('isa') != 'PBXBuildFile':
            continue
        ref = merged.get(value.get('fileRef', ''))
        if ref and Path(ref.get('path', '')).name in EXCLUDED_SOURCES:
            merged.pop(key, None)
    for value in merged.values():
        if value.get('isa', '').endswith('BuildPhase'):
            value['files'] = [f for f in value.get('files', []) if f in merged]

    project['objects'] = merged
    with PROJECT.open('wb') as handle:
        plistlib.dump(project, handle, sort_keys=False)

    # Report the shape so the run can be audited.
    targets = [key for key, value in merged.items()
               if value.get('isa') == 'PBXNativeTarget' and value['name'] == 'Minis']
    source_ids = []
    for key in targets:
        for phase_id in merged[key].get('buildPhases', []):
            phase = merged.get(phase_id, {})
            if phase.get('isa') == 'PBXSourcesBuildPhase':
                for build_id in phase.get('files', []):
                    ref = merged.get(merged.get(build_id, {}).get('fileRef', ''), {})
                    if ref:
                        source_ids.append(str(Path(ref.get('path', '')).name))
    print(f'objects: {len(merged)}  added-from-upstream: {len(added)}  '
          f'removed-refs: {len(removed_refs)}  sources: {len(source_ids)}')
    print('excluded sources present:', [n for n in EXCLUDED_SOURCES if n in source_ids])
    print('synced groups:', sorted({value['path'] for value in merged.values()
                                   if value.get('isa') == 'PBXFileSystemSynchronizedRootGroup'}))


if __name__ == '__main__':
    main()
