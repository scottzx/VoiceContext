#!/usr/bin/env python3
"""Audit the fusion assembly and unsigned device product without running iOS."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
from urllib.parse import parse_qs, urlsplit

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
model_weight_names = {artifact['relativePath'] for artifact in model_manifest}
excluded_model_names = model_weight_names | {name + '.partial' for name in model_weight_names}
model_resource_names = {path.name for path in model_root.iterdir()
                        if path.is_file() and (path.name == 'ModelManifest.json' or path.suffix in {'.txt', '.md'})}
wake_root = ROOT / 'speech_note/speech_note/MeetingWakeModels'
wake_manifest = json.loads((wake_root / 'MeetingWakeManifest.json').read_text())
assert {item['relativePath'] for item in wake_manifest} == {
    'encoder.onnx', 'decoder.onnx', 'joiner.onnx', 'tokens.txt', 'keywords.txt'
}, 'Preinstalled wake model manifest is incomplete'
for artifact in wake_manifest:
    path = wake_root / artifact['relativePath']
    assert path.stat().st_size == artifact['sizeBytes'], f'Wake model size changed: {path.name}'
    assert hashlib.sha256(path.read_bytes()).hexdigest() == artifact['sha256'], f'Wake model checksum changed: {path.name}'
assert 'MODEL_ATTRIBUTIONS.md' in model_resource_names, 'Missing model attribution notice'
assert 'pyannote-segmentation-3.0-LICENSE.txt' in model_resource_names, 'Missing bundled pyannote license'
for artifact in model_manifest:
    for key in ['sourceURL', 'licenseURL', 'downloadURL']:
        assert artifact[key].startswith('https://'), f'Missing HTTPS model metadata: {artifact["id"]}: {key}'
    assert artifact['sizeBytes'] > 0, f'Missing model size: {artifact["id"]}'
    assert len(artifact['revision']) == 40 and all(c in '0123456789abcdef' for c in artifact['revision']), f'Model revision is not pinned: {artifact["id"]}'
    assert len(artifact['sha256']) == 64 and all(c in '0123456789abcdef' for c in artifact['sha256']), f'Model checksum is not pinned: {artifact["id"]}'
    download = urlsplit(artifact['downloadURL'])
    query = parse_qs(download.query)
    assert download.hostname == 'modelscope.cn' and query.get('Revision') == [artifact['revision']] and query.get('FilePath') == [artifact['relativePath']], f'Model download metadata does not match the manifest: {artifact["id"]}'
resource_paths = {fusion[fid].get('path', '') for fid in members(fusion, main, 'PBXResourcesBuildPhase')}
assert any(Path(path).name == 'MeetingWakeModels' for path in resource_paths), 'Wake model folder is not preinstalled'
for name in model_resource_names:
    assert any(Path(path).name == name for path in resource_paths), f'Model resource not copied to app root: {name}'
for native_target in [value for value in fusion.values() if value.get('isa') == 'PBXNativeTarget' and value['name'] in ['VoiceContextAgent', 'VoiceRecording']]:
    for phase_id in native_target['buildPhases']:
        phase = fusion[phase_id]
        if phase['isa'] != 'PBXResourcesBuildPhase':
            continue
        for build_id in phase['files']:
            path = fusion[fusion[build_id]['fileRef']].get('path', '')
            assert Path(path).name not in excluded_model_names | {'ModelResources'}, f'Bundled model weights in {native_target["name"]}: {path}'
for kind in ['PBXSourcesBuildPhase', 'PBXFrameworksBuildPhase']:
    missing = members(upstream, original, kind) - members(fusion, main, kind)
    if kind == 'PBXFrameworksBuildPhase':
        missing = {fid for fid in missing if not upstream[fid].get('path', '').endswith('TranscribeCpp.xcframework')}
    assert not missing, f'Dropped Phone build inputs: {kind}: {missing}'
main_sources = [fusion[fid].get('path', '') for fid in members(fusion, main, 'PBXSourcesBuildPhase')]
for source in ['Integration/App/CustomExtensionsCLI.swift',
               'Integration/App/CustomExtensionsOffloadBridge.swift',
               'Integration/NativeOffloads/CustomExtensionsOffload.m']:
    assert sum(path.endswith(source) for path in main_sources) == 1, f'Missing or duplicated custom function CLI source: {source}'
package_root = ROOT / 'Vendor/TranscribeKit'
package_snapshot = json.loads((package_root / 'SOURCE_SNAPSHOT.json').read_text())
for relative, expected_digest in package_snapshot['files'].items():
    assert hashlib.sha256((package_root / relative).read_bytes()).hexdigest() == expected_digest, f'TranscribeKit snapshot changed: {relative}'
package_ids = {key for key, value in fusion.items() if value.get('isa') == 'XCLocalSwiftPackageReference'
               and (PHONE / 'src/ios' / value['relativePath']).resolve() == package_root}
assert len(package_ids) == 1, 'Expected one pinned TranscribeKit package'
for module_name in ['VoiceContextAgent', 'VoiceRecording']:
    module = target(fusion, module_name)
    design_sources = [fusion[fid].get('path', '') for fid in members(fusion, module, 'PBXSourcesBuildPhase')]
    assert sum(path.endswith('Integration/Shared/YimaDesignTokens.swift') for path in design_sources) == 1, f'Missing or duplicated shared design source: {module_name}'
    assert any(fusion[pid].get('productName') == 'TranscribeNative' and fusion[pid].get('package') in package_ids
               for pid in module.get('packageProductDependencies', [])), f'Missing shared native package: {module_name}'
    assert not any(fusion[fid].get('path', '').endswith('TranscribeCpp.xcframework')
                   for fid in members(fusion, module, 'PBXFrameworksBuildPhase')), f'Legacy native link remains: {module_name}'

legacy = read_project(ROOT / 'speech_note/speech_note.xcodeproj/project.pbxproj')
legacy_target = target(legacy, 'speech_note')
model_exceptions = {path for group_id in legacy_target['fileSystemSynchronizedGroups']
                    for exception_id in legacy[group_id].get('exceptions', [])
                    if legacy[legacy[exception_id]['target']]['name'] == 'speech_note'
                    for path in legacy[exception_id].get('membershipExceptions', [])}
assert {'ModelResources/' + name for name in excluded_model_names} <= model_exceptions, 'Standalone app still includes model weights'
legacy_settings = {legacy[c]['name']: legacy[c]['buildSettings'] for c in legacy[legacy_target['buildConfigurationList']]['buildConfigurations']}
for c in fusion[main['buildConfigurationList']]['buildConfigurations']:
    config = fusion[c]; settings = config['buildSettings']; old = legacy_settings[config['name'].removesuffix('-Dev')]
    for key in ['PRODUCT_BUNDLE_IDENTIFIER', 'DEVELOPMENT_TEAM', 'MARKETING_VERSION', 'CURRENT_PROJECT_VERSION']:
        expected = old[key] + ('.dev' if key == 'PRODUCT_BUNDLE_IDENTIFIER' and config['name'].endswith('-Dev') else '')
        assert settings[key] == expected, f'Identity changed: {config["name"]}: {key}'
    assert settings['SUPPORTED_PLATFORMS'] == 'iphoneos'
    assert settings['IPHONEOS_DEPLOYMENT_TARGET'] == '18.0'
    assert 'VOICE_AGENT_FUSION' in settings.get('SWIFT_ACTIVE_COMPILATION_CONDITIONS', '').split(), f'Missing Swift fusion condition: {config["name"]}'
    definitions = settings.get('GCC_PREPROCESSOR_DEFINITIONS', [])
    if isinstance(definitions, str): definitions = definitions.split()
    assert 'VOICE_AGENT_FUSION=1' in definitions, f'Missing native fusion condition: {config["name"]}'

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
    for name in model_resource_names - {'ModelManifest.json'}:
        assert (app / name).read_bytes() == (model_root / name).read_bytes(), f'Model attribution changed: {name}'
    for path in wake_root.iterdir():
        if path.is_file():
            assert (app / 'MeetingWakeModels' / path.name).read_bytes() == path.read_bytes(), f'Preinstalled wake resource changed: {path.name}'
    # Phone's system/cloud chat voice capture uses an independent Silero v5.
    # SwiftPM 1.0.14 also includes v4 under the same basename as our smaller VAD.
    chat_vad_resources = {
        'RealTimeCutVADLibrary_RealTimeCutVADLibrary.bundle/silero_vad.onnx':
            (1807522, 'a35ebf52fd3ce5f1469b2a36158dba761bc47b973ea3382b3186ca15b1f5af28'),
        'RealTimeCutVADLibrary_RealTimeCutVADLibrary.bundle/silero_vad_v5.onnx':
            (2327524, '2623a2953f6ff3d2c1e61740c6cdb7168133479b267dfef114a4a3cc5bdd788f'),
    }
    for relative, (size, digest) in chat_vad_resources.items():
        path = app / relative
        assert path.is_file(), f'Missing independent chat VAD resource: {relative}'
        assert path.stat().st_size == size and hashlib.sha256(path.read_bytes()).hexdigest() == digest, f'Independent chat VAD resource changed: {relative}'
    bundled_weights = [str(path.relative_to(app)) for path in app.rglob('*')
                       if path.is_file() and path.name in excluded_model_names
                       and path.relative_to(app).as_posix() not in chat_vad_resources]
    assert not bundled_weights, f'On-demand model weights are bundled: {bundled_weights}'
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
