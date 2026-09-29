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
for kind in ['PBXSourcesBuildPhase', 'PBXFrameworksBuildPhase']:
    missing = members(upstream, original, kind) - members(fusion, main, kind)
    assert not missing, f'Dropped Phone build inputs: {kind}: {missing}'

legacy = read_project(ROOT / 'speech_note/speech_note.xcodeproj/project.pbxproj')
legacy_target = target(legacy, 'speech_note')
legacy_settings = {legacy[c]['name']: legacy[c]['buildSettings'] for c in legacy[legacy_target['buildConfigurationList']]['buildConfigurations']}
for c in fusion[main['buildConfigurationList']]['buildConfigurations']:
    config = fusion[c]; settings = config['buildSettings']; old = legacy_settings[config['name']]
    for key in ['PRODUCT_BUNDLE_IDENTIFIER', 'DEVELOPMENT_TEAM', 'MARKETING_VERSION', 'CURRENT_PROJECT_VERSION']:
        assert settings[key] == old[key], f'Legacy identity changed: {key}'
    assert settings['SUPPORTED_PLATFORMS'] == 'iphoneos'
    assert settings['IPHONEOS_DEPLOYMENT_TARGET'] == '18.0'

ent = plistlib.loads((ROOT / 'Integration/VoiceContextAgent.entitlements').read_bytes())
assert ent['keychain-access-groups'] == plistlib.loads((ROOT / 'speech_note/speech_note/speech_note.entitlements').read_bytes())['keychain-access-groups']
assert ent['com.apple.developer.icloud-container-identifiers'][0] == 'iCloud.YiJie.speech-note'
assert ent['com.apple.security.application-groups'] == ['group.YiJie.speech-note.agent']
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
    app = args.products / 'VoiceContextAgent.app'
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    assert info['CFBundleIdentifier'] == 'YiJie.speech-note'
    assert info['CFBundleDisplayName'] == '听记'
    assert info['MinimumOSVersion'] == '18.0'
    assert '会议' in info['NSMicrophoneUsageDescription']
    assert '待办' in info['NSRemindersFullAccessUsageDescription']
    assert any('voicecontext' in entry['CFBundleURLSchemes'] for entry in info['CFBundleURLTypes'])
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
    for resource in ['alpine-rootfs.zip', 'RootfsPatch.bundle', 'ModelResources', 'VoiceContextPack.zip', 'FlavorConfig.json']:
        assert (app / resource).exists(), f'Missing bundled capability: {resource}'
    extensions = list((app / 'PlugIns').glob('*.appex'))
    assert {p.name for p in extensions} == {'MinisShare.appex', 'MinisFileProvider.appex', 'AgentWidgetExtension.appex', 'RecordWidgetExtension.appex'}
    for extension in extensions:
        x = plistlib.loads((extension / 'Info.plist').read_bytes())
        assert x['CFBundleIdentifier'].startswith('YiJie.speech-note.')
        assert x['CFBundleVersion'] == info['CFBundleVersion']
        assert x['CFBundleShortVersionString'] == info['CFBundleShortVersionString']
    for key, value in info.items():
        if key.endswith('UsageDescription'): assert 'Yima' not in value, f'Old product permission text: {key}'

print(json.dumps({'sourceFilesPresent': len(manifest['files']),
                  'phoneCompilationInputsPreserved': len(members(upstream, original, 'PBXSourcesBuildPhase')),
                  'identityAndContainers': 'passed', 'deviceProduct': 'passed' if args.products else 'not requested',
                  'localSourcePatches': sorted(modified)}, ensure_ascii=False, indent=2))
