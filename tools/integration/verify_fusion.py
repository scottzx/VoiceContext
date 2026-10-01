#!/usr/bin/env python3
"""Audit the fusion assembly and unsigned device product without running iOS."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parents[2]
PHONE = ROOT / 'Vendor/Phone'
parser = argparse.ArgumentParser()
parser.add_argument('--products', type=Path, help='Xcode Build/Products/Debug-iphoneos directory')
parser.add_argument('--check-cache', action='store_true')
parser.add_argument('--variant', choices=['production', 'development'], default='production')
args = parser.parse_args()

def read_project(path):
    return json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)]))['objects']

def target(objects, name):
    return next(x for x in objects.values() if x.get('isa') == 'PBXNativeTarget' and x['name'] == name)

def members(objects, native_target, kind):
    phase = next(objects[x] for x in native_target['buildPhases'] if objects[x]['isa'] == kind)
    return {objects[x].get('fileRef', objects[x].get('productRef')) for x in phase['files']}

upstream = read_project(PHONE / 'src/ios/Minis.xcodeproj/project.pbxproj')
fusion = read_project(PHONE / 'src/ios/VoiceContextAgent.xcodeproj/project.pbxproj')
main = target(fusion, 'VoiceContextAgent')
original = target(upstream, 'Minis')
model_root = ROOT / 'speech_note/speech_note/ModelResources'
model_manifest = json.loads((model_root / 'ModelManifest.json').read_text())
model_resource_names = {'ModelManifest.json', *(artifact['relativePath'] for artifact in model_manifest)}
resource_paths = {fusion[fid].get('path', '') for fid in members(fusion, main, 'PBXResourcesBuildPhase')}
for name in model_resource_names:
    assert any(Path(path).name == name for path in resource_paths), f'Model resource not copied to app root: {name}'
assert not any(Path(path).name == 'ModelResources' for path in resource_paths), 'Nested model resources break Bundle.main loaders'
for kind in ['PBXSourcesBuildPhase', 'PBXFrameworksBuildPhase']:
    missing = members(upstream, original, kind) - members(fusion, main, kind)
    if kind == 'PBXFrameworksBuildPhase':
        missing = {fid for fid in missing if not upstream[fid].get('path', '').endswith('TranscribeCpp.xcframework')}
    assert not missing, f'Dropped Phone build inputs: {kind}: {missing}'
package_root = ROOT / 'Vendor/TranscribeKit'
package_snapshot = json.loads((package_root / 'SOURCE_SNAPSHOT.json').read_text())
for relative, expected_digest in package_snapshot['files'].items():
    assert hashlib.sha256((package_root / relative).read_bytes()).hexdigest() == expected_digest, f'TranscribeKit snapshot changed: {relative}'
package_ids = {key for key, value in fusion.items() if value.get('isa') == 'XCLocalSwiftPackageReference'
               and (PHONE / 'src/ios' / value['relativePath']).resolve() == package_root}
assert len(package_ids) == 1, 'Expected one pinned TranscribeKit package'
for module_name in ['VoiceContextAgent', 'VoiceRecording']:
    module = target(fusion, module_name)
    assert any(fusion[pid].get('productName') == 'TranscribeNative' and fusion[pid].get('package') in package_ids
               for pid in module.get('packageProductDependencies', [])), f'Missing shared native package: {module_name}'
    assert not any(fusion[fid].get('path', '').endswith('TranscribeCpp.xcframework')
                   for fid in members(fusion, module, 'PBXFrameworksBuildPhase')), f'Legacy native link remains: {module_name}'

legacy = read_project(ROOT / 'speech_note/speech_note.xcodeproj/project.pbxproj')
legacy_target = target(legacy, 'speech_note')
legacy_settings = {legacy[c]['name']: legacy[c]['buildSettings'] for c in legacy[legacy_target['buildConfigurationList']]['buildConfigurations']}
for c in fusion[main['buildConfigurationList']]['buildConfigurations']:
    config = fusion[c]; settings = config['buildSettings']; old = legacy_settings[config['name'].removesuffix('-Dev')]
    for key in ['PRODUCT_BUNDLE_IDENTIFIER', 'DEVELOPMENT_TEAM', 'MARKETING_VERSION', 'CURRENT_PROJECT_VERSION']:
        expected = old[key] + ('.dev' if key == 'PRODUCT_BUNDLE_IDENTIFIER' and config['name'].endswith('-Dev') else '')
        assert settings[key] == expected, f'Identity changed: {config["name"]}: {key}'
    assert settings['SUPPORTED_PLATFORMS'] == 'iphoneos'
    assert settings['IPHONEOS_DEPLOYMENT_TARGET'] == '18.0'

ent = plistlib.loads((ROOT / 'Integration/VoiceContextAgent.entitlements').read_bytes())
assert ent['keychain-access-groups'] == plistlib.loads((ROOT / 'speech_note/speech_note/speech_note.entitlements').read_bytes())['keychain-access-groups']
assert ent['com.apple.developer.icloud-container-identifiers'][0] == 'iCloud.YiJie.speech-note'
assert ent['com.apple.security.application-groups'] == ['group.YiJie.speech-note.agent']
dev_ent = plistlib.loads((ROOT / 'Integration/VoiceContextAgentDev.entitlements').read_bytes())
for key in ['keychain-access-groups', 'com.apple.developer.icloud-container-identifiers',
            'com.apple.developer.ubiquity-container-identifiers', 'com.apple.security.application-groups']:
    assert not set(ent[key]) & set(dev_ent[key]), f'Development shares production data: {key}'
for native_target in [x for x in fusion.values() if x.get('isa') == 'PBXNativeTarget' and x.get('name') in
                      ['VoiceContextAgent', 'VoiceRecording', 'MinisShare', 'AgentWidgetExtension', 'MinisFileProvider', 'RecordWidgetExtension']]:
    configurations = {fusion[c]['name']: fusion[c]['buildSettings'] for c in fusion[native_target['buildConfigurationList']]['buildConfigurations']}
    dev = configurations['Debug-Dev']; production = configurations['Debug']
    assert dev['PRODUCT_BUNDLE_IDENTIFIER'] == production['PRODUCT_BUNDLE_IDENTIFIER'].replace('YiJie.speech-note', 'YiJie.speech-note.dev')
    assert 'VOICE_AGENT_DEV' in dev['SWIFT_ACTIVE_COMPILATION_CONDITIONS']
    if 'CODE_SIGN_ENTITLEMENTS' in dev:
        path = Path(dev['CODE_SIGN_ENTITLEMENTS'].replace('$(SRCROOT)', str(PHONE / 'src/ios')))
        dev_capabilities = plistlib.loads(path.read_bytes())
        assert dev_capabilities['com.apple.security.application-groups'] == ['group.YiJie.speech-note.dev.agent']
    if native_target['name'] == 'MinisFileProvider':
        path = Path(dev['INFOPLIST_FILE'].replace('$(SRCROOT)', str(PHONE / 'src/ios')))
        assert plistlib.loads(path.read_bytes())['NSExtension']['NSExtensionFileProviderDocumentGroup'] == 'group.YiJie.speech-note.dev.agent'
manifest = json.loads((ROOT / 'tools/integration/phone-source-manifest.json').read_text())
modified = []
for relative, digest in manifest['files'].items():
    file = PHONE / relative
    assert file.is_file(), f'Missing imported source: {relative}'
    if hashlib.sha256(file.read_bytes()).hexdigest() != digest: modified.append(relative)

if args.check_cache:
    cache = json.loads((ROOT / 'tools/integration/native-cache-manifest.json').read_text())
    for relative, digest in cache['files'].items():
        assert hashlib.sha256((PHONE / relative).read_bytes()).hexdigest() == digest, f'Native cache changed: {relative}'

if args.products:
    is_dev = args.variant == 'development'
    bundle_id = 'YiJie.speech-note' + ('.dev' if is_dev else '')
    app = args.products / 'VoiceContextAgent.app'
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    assert info['CFBundleIdentifier'] == bundle_id
    assert info['CFBundleDisplayName'] == ('一芥伙伴 Dev' if is_dev else '一芥伙伴')
    suffix = ' Dev' if is_dev else ''
    for language, display_name in [('en', 'Yima'), ('zh-Hans', '一芥伙伴'), ('zh-Hant', '一芥伙伴')]:
        localized = plistlib.loads((app / f'{language}.lproj/InfoPlist.strings').read_bytes())
        assert localized['CFBundleDisplayName'] == display_name + suffix
        assert localized['NSCalendarsFullAccessUsageDescription']
    for extension in (app / 'PlugIns').glob('*.appex'):
        for language in ['en', 'zh-Hans', 'zh-Hant']:
            localized = plistlib.loads((extension / f'{language}.lproj/InfoPlist.strings').read_bytes())
            assert localized['CFBundleDisplayName'].endswith(' Dev') == is_dev
    assert info['MinimumOSVersion'] == '18.0'
    assert '会议' in info['NSMicrophoneUsageDescription']
    assert '待办' in info['NSRemindersFullAccessUsageDescription']
    assert '日程' in info['NSCalendarsFullAccessUsageDescription']
    schemes = {scheme for entry in info['CFBundleURLTypes'] for scheme in entry['CFBundleURLSchemes']}
    assert ('voicecontext-dev' if is_dev else 'voicecontext') in schemes
    assert ('minis-dev' if is_dev else 'minis') in schemes
    if is_dev: assert not {'voicecontext', 'minis'} & schemes
    assert set(info['NSUbiquitousContainers']) == {f'iCloud.{bundle_id}', f'iCloud.{bundle_id}.agent'}
    recording = app / 'Frameworks/VoiceRecording.framework/VoiceRecording'
    assert recording.is_file()
    recording_install_name = '@rpath/VoiceRecording.framework/VoiceRecording'
    install_names = subprocess.check_output(['xcrun', 'otool', '-D', str(recording)], text=True).splitlines()[1:]
    assert recording_install_name in [line.strip() for line in install_names], f'Invalid recording install name: {install_names}'
    # Debug builds may put the app's framework imports in a separate dylib.
    binaries = [app / info['CFBundleExecutable'], *app.glob('*.dylib'), *(app / 'Frameworks').glob('*.framework/*')]
    recording_linked = False
    for binary in binaries:
        if not binary.is_file() or binary.suffix in {'.plist', '.json'}:
            continue
        if binary.parent.suffix == '.framework' and binary.name != binary.parent.stem:
            continue
        dependencies = subprocess.check_output(['xcrun', 'otool', '-L', str(binary)], text=True)
        assert '/Library/Frameworks/VoiceRecording.framework/' not in dependencies, f'Absolute recording dependency in {binary.name}'
        if binary != recording and recording_install_name in dependencies:
            recording_linked = True
    assert recording_linked, 'App does not link the embedded recording framework'
    for resource in ['alpine-rootfs.zip', 'RootfsPatch.bundle', 'VoiceContextPack.zip', 'FlavorConfig.json', *model_resource_names]:
        assert (app / resource).exists(), f'Missing bundled capability: {resource}'
    assert json.loads((app / 'ModelManifest.json').read_text()) == model_manifest
    for artifact in model_manifest:
        hasher = hashlib.sha256()
        with (app / artifact['relativePath']).open('rb') as model_file:
            for chunk in iter(lambda: model_file.read(1 << 20), b''):
                hasher.update(chunk)
        assert hasher.hexdigest() == artifact['sha256'], f'Bundled model checksum mismatch: {artifact["id"]}'
        if artifact['relativePath'].endswith('.gguf'):
            assert list(app.rglob(artifact['relativePath'])) == [app / artifact['relativePath']], f'Duplicate bundled ASR model: {artifact["id"]}'
    extensions = list((app / 'PlugIns').glob('*.appex'))
    assert {p.name for p in extensions} == {'MinisShare.appex', 'MinisFileProvider.appex', 'AgentWidgetExtension.appex', 'RecordWidgetExtension.appex'}
    for extension in extensions:
        x = plistlib.loads((extension / 'Info.plist').read_bytes())
        assert x['CFBundleIdentifier'].startswith(bundle_id + '.')
        if not is_dev: assert not x['CFBundleIdentifier'].startswith(bundle_id + '.dev.')
        assert x['CFBundleVersion'] == info['CFBundleVersion']
        assert x['CFBundleShortVersionString'] == info['CFBundleShortVersionString']
    for key, value in info.items():
        if key.endswith('UsageDescription'):
            assert not any(old in value for old in ['听记', '一伴', 'VoiceContext']), f'Old product permission text: {key}'

print(json.dumps({'sourceFilesPresent': len(manifest['files']),
                  'phoneCompilationInputsPreserved': len(members(upstream, original, 'PBXSourcesBuildPhase')),
                  'identityAndContainers': 'passed', 'deviceProduct': 'passed' if args.products else 'not requested',
                  'variant': args.variant,
                  'localSourcePatches': sorted(modified)}, ensure_ascii=False, indent=2))
