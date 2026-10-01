#!/usr/bin/env python3
"""Generate the fusion project from both source projects, preserving their settings."""
from pathlib import Path
import copy
import hashlib
import json
import plistlib
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
PHONE = ROOT / 'Vendor/Phone/src/ios'
OUT = PHONE / 'VoiceContextAgent.xcodeproj'

# Local provider overrides may contain secrets; recreate only from the example.
config = PHONE / 'Configs/ProviderCustomization.xcconfig'
if not config.exists():
    config.write_bytes(config.with_suffix('.xcconfig.example').read_bytes())

def read(path):
    return json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)]))

def uid(name):
    return hashlib.sha256(('VoiceContextFusion:' + name).encode()).hexdigest()[:24].upper()

d = read(PHONE / 'Minis.xcodeproj/project.pbxproj')
o = d['objects']
p = o[d['rootObject']]
voice = read(ROOT / 'speech_note/speech_note.xcodeproj/project.pbxproj')
vo = voice['objects']
vp = vo[voice['rootObject']]
# Resolve original voice group-relative references before moving objects.
resolved = {}
def walk(key, base):
    x = vo[key]
    tree = x.get('sourceTree', '<group>')
    if tree == 'SOURCE_ROOT': base = ROOT / 'speech_note'
    path = x.get('path', '')
    current = base / path if tree in ('<group>', 'SOURCE_ROOT') else None
    if current is not None: resolved[key] = current
    for child in x.get('children', []): walk(child, current or base)
walk(vp['mainGroup'], ROOT / 'speech_note')
for key, value in vo.items():
    if key in o: raise SystemExit('Object ID collision: ' + key)
    x = copy.deepcopy(value)
    if key in resolved and x['isa'] in ('PBXFileReference', 'PBXFileSystemSynchronizedRootGroup'):
        import os
        x['path'] = os.path.relpath(resolved[key], PHONE)
        x['sourceTree'] = 'SOURCE_ROOT'
    o[key] = x

main_id = next(t for t in p['targets'] if o[t]['name'] == 'Minis')
main = o[main_id]
main['name'] = 'VoiceContextAgent'
main['productName'] = 'VoiceContextAgent'
o[main['productReference']]['path'] = 'VoiceContextAgent.app'
keep = ['VoiceContextAgent', 'MinisShare', 'AgentWidgetExtension', 'MinisFileProvider']
p['targets'] = [t for t in p['targets'] if o[t]['name'] in keep]
# Make imported voice code a distinct module without copying or renaming its models.
record_id = next(t for t in vp['targets'] if vo[t]['name'] == 'speech_note')
record = o[record_id]
record['name'] = 'VoiceRecording'
record['productName'] = 'VoiceRecording'
record['productType'] = 'com.apple.product-type.framework'
record['dependencies'] = []
record['buildPhases'] = [ph for ph in record['buildPhases'] if o[ph]['isa'] in ('PBXSourcesBuildPhase', 'PBXFrameworksBuildPhase')]
record['fileSystemSynchronizedGroups'] = []
o[record['productReference']].update(path='VoiceRecording.framework', explicitFileType='wrapper.framework')
p['targets'].append(record_id)
widget_id = next(t for t in vp['targets'] if vo[t]['name'] == 'RecordWidgetExtension')
p['targets'].append(widget_id)
# Add the original voice group for navigability; source membership below is explicit.
o[p['mainGroup']]['children'].append(vp['mainGroup'])

def phase(target, kind):
    return next(o[x] for x in target['buildPhases'] if o[x]['isa'] == kind)
def ref(path, kind):
    import os
    key = uid('file:' + str(path))
    o[key] = {'isa':'PBXFileReference', 'path':os.path.relpath(path, PHONE), 'sourceTree':'SOURCE_ROOT', 'lastKnownFileType':kind}
    if key not in o[p['mainGroup']]['children']: o[p['mainGroup']]['children'].append(key)
    return key

def add(target, phase_kind, file_id, settings=None):
    ph = phase(target, phase_kind)
    key = uid(target['name'] + ':' + phase_kind + ':' + file_id)
    o[key] = {'isa':'PBXBuildFile','fileRef':file_id}
    if settings: o[key]['settings'] = settings
    ph.setdefault('files', []).append(key)

for file in sorted((ROOT / 'speech_note/speech_note').rglob('*.swift')):
    add(record,'PBXSourcesBuildPhase',ref(file,'sourcecode.swift'))
for file in sorted((ROOT / 'speech_note/LiveActivityShared').glob('*.swift')):
    add(record,'PBXSourcesBuildPhase',ref(file,'sourcecode.swift'))
for file in sorted((ROOT / 'Integration/Recording').glob('*.swift')):
    add(record,'PBXSourcesBuildPhase',ref(file,'sourcecode.swift'))
for file in sorted((ROOT / 'Integration/App').glob('*.swift')):
    add(main,'PBXSourcesBuildPhase',ref(file,'sourcecode.swift'))
for tid in p['targets']:
    if tid not in [record_id, widget_id]:
        add(o[tid], 'PBXSourcesBuildPhase', ref(ROOT / 'Integration/Shared/AgentBuildIdentity.swift', 'sourcecode.swift'))
# The recording module keeps its original actor isolation; the phone module keeps its own.
for cid in o[record['buildConfigurationList']]['buildConfigurations']:
    bs = o[cid]['buildSettings']
    for key in list(bs):
        if key.startswith('INFOPLIST_KEY_') or key in ['CODE_SIGN_ENTITLEMENTS','INFOPLIST_FILE','ASSETCATALOG_COMPILER_APPICON_NAME','ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME']:
            del bs[key]
    bs.update(PRODUCT_NAME='VoiceRecording', PRODUCT_MODULE_NAME='VoiceRecording', PRODUCT_BUNDLE_IDENTIFIER='YiJie.speech-note.VoiceRecording',
              GENERATE_INFOPLIST_FILE='YES', DEFINES_MODULE='YES', SKIP_INSTALL='YES', MACH_O_TYPE='mh_dylib',
              DYLIB_INSTALL_NAME_BASE='@rpath',
              SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) VOICE_AGENT_FUSION', SUPPORTED_PLATFORMS='iphoneos', SDKROOT='iphoneos')

# Framework links and dependency edges.
for tid in [record_id, widget_id]:
    dep = uid('dependency:' + tid)
    o[dep] = {'isa':'PBXTargetDependency', 'target':tid}
    main.setdefault('dependencies',[]).append(dep)
add(main,'PBXFrameworksBuildPhase',record['productReference'])
embed = next(o[x] for x in main['buildPhases'] if o[x].get('name') == 'Embed Frameworks')
def embed_file(ph, fid):
    key=uid('embed:' + fid)
    o[key]={'isa':'PBXBuildFile','fileRef':fid,'settings':{'ATTRIBUTES':['CodeSignOnCopy','RemoveHeadersOnCopy']}}
    ph['files'].append(key)
embed_file(embed,record['productReference'])
# Both modules consume the pinned TranscribeKit package, including its C binary.
import os
package_id = uid('package:TranscribeKit')
o[package_id] = {'isa':'XCLocalSwiftPackageReference',
                 'relativePath':os.path.relpath(ROOT/'Vendor/TranscribeKit', PHONE)}
p.setdefault('packageReferences', []).append(package_id)
transcribe_refs = {fid for fid,x in o.items() if x.get('isa') == 'PBXFileReference'
                   and x.get('path', '').endswith('TranscribeCpp.xcframework')}
for target in [main, record]:
    for phid in target['buildPhases']:
        ph = o[phid]
        if ph['isa'] in ['PBXFrameworksBuildPhase', 'PBXCopyFilesBuildPhase']:
            ph['files'] = [bid for bid in ph['files'] if o[bid].get('fileRef') not in transcribe_refs]
    for product_name in ['TranscribeNative', 'CTranscribeRuntime']:
        product_id = uid(target['name'] + ':' + product_name)
        o[product_id] = {'isa':'XCSwiftPackageProductDependency', 'package':package_id, 'productName':product_name}
        target.setdefault('packageProductDependencies', []).append(product_id)
        build_id = uid(target['name'] + ':link:' + product_name)
        o[build_id] = {'isa':'PBXBuildFile', 'productRef':product_id}
        phase(target, 'PBXFrameworksBuildPhase')['files'].append(build_id)
# Embed the original recording widget in addition to existing Agent extensions.
extensions=next(o[x] for x in main['buildPhases'] if o[x].get('name')=='Embed Foundation Extensions')
embed_file(extensions,o[widget_id]['productReference'])
for cid in o[o[widget_id]['buildConfigurationList']]['buildConfigurations']:
    bs=o[cid]['buildSettings'];bs['INFOPLIST_FILE']='$(SRCROOT)/../../../../speech_note/RecordWidget/Info.plist'
    bs['SUPPORTED_PLATFORMS']='iphoneos';bs['SDKROOT']='iphoneos'
# Voice resources are app resources because legacy loaders use Bundle.main.
resources=phase(main,'PBXResourcesBuildPhase')
for bid in list(resources['files']):
    x=o[o[bid]['fileRef']]
    if x.get('path') in ['Localizable.xcstrings','Assets.xcassets']:
        resources['files'].remove(bid)
    if x.get('name')=='InfoPlist.strings':
        resources['files'].remove(bid)  # localized branding is generated per target and build identity
for path,kind in [(ROOT/'Integration/Resources/Localizable.xcstrings','text.json.xcstrings'),
                  (ROOT/'Integration/Resources/Assets.xcassets','folder.assetcatalog'),
                  (ROOT/'speech_note/speech_note/VoiceContextPack.zip','archive.zip')]:
    if path.exists(): add(main,'PBXResourcesBuildPhase',ref(path,kind))
# Copy model files individually so Bundle.main loaders share one flat resource root.
for path in sorted((ROOT/'speech_note/speech_note/ModelResources').iterdir()):
    if path.is_file(): add(main,'PBXResourcesBuildPhase',ref(path, 'text.json' if path.suffix == '.json' else 'file'))
add(main,'PBXResourcesBuildPhase',ref(ROOT/'speech_note/speech_note/SenseVoiceFixture.m4a', 'file'))
# Preserve the full platform plist but use the released product's identity and privacy text.
with (PHONE/'Info.plist').open('rb') as f: info=plistlib.load(f)
with (ROOT/'speech_note/speech_note/Info.plist').open('rb') as f: original=plistlib.load(f)
# Move generated privacy strings into the merged plist so legacy product text
# cannot be silently overridden by Phone's INFOPLIST_KEY_* build settings.
phone_settings = o[o[main['buildConfigurationList']]['buildConfigurations'][0]]['buildSettings']
for key, value in phone_settings.items():
    if key.startswith('INFOPLIST_KEY_') and key.endswith('UsageDescription'):
        info[key.removeprefix('INFOPLIST_KEY_')] = value.replace('一伴', '一芥伙伴').replace('听记', '一芥伙伴')
for key,value in original.items():
    if key in ['UIBackgroundModes','CFBundleURLTypes','BGTaskSchedulerPermittedIdentifiers']:
        info[key]=info.get(key,[])+[x for x in value if x not in info.get(key,[])]
    else: info[key]=value
# Do not advertise the old app's shortcut branding.
info.pop('UIApplicationShortcutItems',None)
info['CFBundleDisplayName']='一芥伙伴'
info['CFBundleName']='Yima'
info['NSMicrophoneUsageDescription']='一芥伙伴使用麦克风录制你主动开始的会议或日常语音，并在你选择语音输入时转为聊天文字。'
info['NSRemindersFullAccessUsageDescription']='在待办事项中展示和管理你的系统提醒事项，并让你授权的智能体任务使用同一份待办。'
info['NSCalendarsFullAccessUsageDescription']='在待办事项中只读展示你的系统日历日程和日期标记，并支持你授权的智能体日历任务。'
for key, value in info.items():
    if key.endswith('UsageDescription') and isinstance(value, str):
        info[key] = value.replace('一伴', '一芥伙伴').replace('听记', '一芥伙伴')
info['NSUbiquitousContainers'] = {
    identifier: {'NSUbiquitousContainerIsDocumentScopePublic': True,
                 'NSUbiquitousContainerName': title, 'NSUbiquitousContainerSupportedFolderLevels': 'Any'}
    for identifier, title in [('iCloud.YiJie.speech-note', 'VoiceContext'),
                              ('iCloud.YiJie.speech-note.agent', 'Yima')]
}
with (ROOT/'Integration/Info.plist').open('wb') as f: plistlib.dump(info,f)
with (PHONE/'Minis.entitlements').open('rb') as f: ent=plistlib.load(f)
with (ROOT/'speech_note/speech_note/speech_note.entitlements').open('rb') as f: ve=plistlib.load(f)
ent.update(ve)
ent['com.apple.developer.icloud-services']=['CloudDocuments','CloudKit']
ent['com.apple.developer.icloud-container-identifiers']=['iCloud.YiJie.speech-note','iCloud.YiJie.speech-note.agent']
ent['com.apple.developer.ubiquity-container-identifiers']=['iCloud.YiJie.speech-note','iCloud.YiJie.speech-note.agent']
ent['com.apple.security.application-groups']=['group.YiJie.speech-note.agent']
with (ROOT/'Integration/VoiceContextAgent.entitlements').open('wb') as f: plistlib.dump(ent,f)
for tid in p['targets']:
    t=o[tid]
    for cid in o[t['buildConfigurationList']]['buildConfigurations']:
        bs=o[cid]['buildSettings']
        bs['IPHONEOS_DEPLOYMENT_TARGET']='18.0'
        bs['SUPPORTED_PLATFORMS']='iphoneos'
        bs['SDKROOT']='iphoneos'
        original_configuration = next(vo[x]['buildSettings'] for x in vo[vo[record_id]['buildConfigurationList']]['buildConfigurations']
                                      if vo[x]['name'] == o[cid]['name'])
        for key in ['DEVELOPMENT_TEAM', 'MARKETING_VERSION', 'CURRENT_PROJECT_VERSION']:
            if key in original_configuration: bs[key] = original_configuration[key]
        if tid == main_id:
            for key in list(bs):
                if key.startswith('INFOPLIST_KEY_') and key.endswith('UsageDescription'): del bs[key]
            bs.update(PRODUCT_BUNDLE_IDENTIFIER='YiJie.speech-note', PRODUCT_MODULE_NAME='Minis',
                      INFOPLIST_FILE='$(SRCROOT)/../../../../Integration/Info.plist',
                      CODE_SIGN_ENTITLEMENTS='$(SRCROOT)/../../../../Integration/VoiceContextAgent.entitlements',
                      FLAVOR_ID='openminis', ASSETCATALOG_COMPILER_APPICON_NAME='AppIcon',
                      SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) VOICE_AGENT_FUSION',
                      TARGETED_DEVICE_FAMILY='1', INFOPLIST_KEY_CFBundleDisplayName='一芥伙伴',
                      INFOPLIST_KEY_CFBundleName='Yima',
                      INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone='UIInterfaceOrientationPortrait')
        elif tid not in [record_id,widget_id]:
            bs['PRODUCT_BUNDLE_IDENTIFIER']=bs.get('PRODUCT_BUNDLE_IDENTIFIER','').replace('com.1agents.phone','YiJie.speech-note')
            bs['INFOPLIST_KEY_CFBundleDisplayName'] = {
                'MinisShare': '发送到一芥伙伴', 'MinisFileProvider': '一芥伙伴文件', 'AgentWidgetExtension': '智能体活动'
            }[t['name']]
# Separate resources must not rewrite upstream or original asset catalogs.
import shutil
assets=ROOT/'Integration/Resources/Assets.xcassets'
shutil.copytree(PHONE/'Assets.xcassets',assets,dirs_exist_ok=True)
for name in ['AppIcon.appiconset','AccentColor.colorset']:
    target=assets/name
    if target.exists(): shutil.rmtree(target)
    shutil.copytree(ROOT/'speech_note/speech_note/Assets.xcassets'/name,target)
strings=json.loads((PHONE/'Localizable.xcstrings').read_text())
vc=json.loads((ROOT/'speech_note/speech_note/Localizable.xcstrings').read_text())
strings['strings'].update(vc['strings'])
fusion=json.loads((ROOT/'Integration/Resources/Fusion.xcstrings').read_text())
for key, value in fusion['strings'].items():
    entry = strings['strings'].setdefault(key, {'extractionState': 'manual', 'localizations': {}})
    entry.setdefault('localizations', {}).update(value['localizations'])
(ROOT/'Integration/Resources/Localizable.xcstrings').write_text(json.dumps(strings,ensure_ascii=False,indent=2)+'\n')
# Resources are generated above; first generation may not have found them earlier.
for path,kind in [(assets,'folder.assetcatalog'),(ROOT/'Integration/Resources/Localizable.xcstrings','text.json.xcstrings')]:
    fid=ref(path,kind)
    if not any(o[x].get('fileRef')==fid for x in resources['files']): add(main,'PBXResourcesBuildPhase',fid)
# A separate configuration keeps development installs beside the released app.
# All dependencies receive the same configuration, including the four extensions.
def development_value(value):
    if isinstance(value, dict):
        return {development_value(k): development_value(v) for k, v in value.items()}
    if isinstance(value, list): return [development_value(v) for v in value]
    if isinstance(value, str):
        value = value.replace('YiJie.speech-note', 'YiJie.speech-note.dev')
        value = value.replace('com.yijie.shared_entitlements', 'com.yijie.shared_entitlements.dev')
        if value in ['voicecontext', 'minis']: value += '-dev'
    return value

for owner in [p, *[o[tid] for tid in p['targets']]]:
    configurations = o[owner['buildConfigurationList']]['buildConfigurations']
    debug = next(cid for cid in configurations if o[cid]['name'] == 'Debug')
    dev_id = uid('development:' + debug)
    dev = copy.deepcopy(o[debug]); dev['name'] = 'Debug-Dev'
    bs = dev['buildSettings']
    if owner is not p:
        bs['PRODUCT_BUNDLE_IDENTIFIER'] = development_value(bs['PRODUCT_BUNDLE_IDENTIFIER'])
        bs['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = bs.get('SWIFT_ACTIVE_COMPILATION_CONDITIONS', '$(inherited)') + ' VOICE_AGENT_DEV'
        display_name = bs.get('INFOPLIST_KEY_CFBundleDisplayName')
        if display_name:
            bs['INFOPLIST_KEY_CFBundleDisplayName'] = display_name + ' Dev'
        for setting, suffix in [('INFOPLIST_FILE', 'Info.plist'), ('CODE_SIGN_ENTITLEMENTS', 'entitlements')]:
            if setting not in bs: continue
            source = Path(bs[setting].replace('$(SRCROOT)', str(PHONE)))
            if not source.is_absolute(): source = PHONE / source
            value = development_value(plistlib.loads(source.read_bytes()))
            if setting == 'INFOPLIST_FILE' and 'CFBundleDisplayName' in value:
                value['CFBundleDisplayName'] += ' Dev'
            path = ROOT / 'Integration' / f"{owner['name']}Dev.{suffix}"
            with path.open('wb') as f: plistlib.dump(value, f)
            bs[setting] = '$(SRCROOT)/../../../../Integration/' + path.name
    o[dev_id] = dev
    configurations.append(dev_id)

# Display names are localized independently of bundle IDs and storage paths.
brand_names = {
    'VoiceContextAgent': ('一芥伙伴', 'Yima'),
    'MinisShare': ('发送到一芥伙伴', 'Send to Yima'),
    'MinisFileProvider': ('一芥伙伴文件', 'Yima Files'),
    'AgentWidgetExtension': ('一芥伙伴活动', 'Yima Activity'),
    'RecordWidgetExtension': ('一芥伙伴录音', 'Yima Recording'),
}
for tid in p['targets']:
    target = o[tid]
    if target['name'] not in brand_names: continue
    zh, en = brand_names[target['name']]
    target_resources = phase(target, 'PBXResourcesBuildPhase')
    for bid in list(target_resources['files']):
        resource = o[o[bid]['fileRef']]
        if resource.get('name') == 'InfoPlist.strings': target_resources['files'].remove(bid)
    for cid in o[target['buildConfigurationList']]['buildConfigurations']:
        config = o[cid]; bs = config['buildSettings']
        suffix = ' Dev' if config['name'] == 'Debug-Dev' else ''
        folder = ROOT / 'Integration/Resources/Branding' / target['name'] / config['name']
        folder.mkdir(parents=True, exist_ok=True)
        entries = {}
        for key in ['CFBundleDisplayName', 'CFBundleName']:
            entries[key] = {'extractionState': 'manual', 'localizations': {
                lang: {'stringUnit': {'state': 'translated', 'value': name + suffix}}
                for lang, name in [('en', en), ('zh-Hans', zh), ('zh-Hant', zh)]}}
        if target['name'] == 'VoiceContextAgent':
            entries['NSCalendarsFullAccessUsageDescription'] = {'extractionState': 'manual', 'localizations': {
                lang: {'stringUnit': {'state': 'translated', 'value': text}}
                for lang, text in [
                    ('en', 'View your system calendar events and date markers in Tasks, and support calendar tasks you authorize the agent to perform.'),
                    ('zh-Hans', info['NSCalendarsFullAccessUsageDescription']),
                    ('zh-Hant', '在待辦事項中唯讀顯示你的系統行事曆行程和日期標記，並支援你授權的智慧體行事曆任務。')]}}
        (folder / 'InfoPlist.xcstrings').write_text(json.dumps(
            {'sourceLanguage': 'en', 'strings': entries, 'version': '1.0'}, ensure_ascii=False, indent=2) + '\n')
        bs['YIMA_BRANDING_DIR'] = '$(SRCROOT)/../../../../Integration/Resources/Branding/' + target['name'] + '/' + config['name']
        bs['INFOPLIST_KEY_CFBundleDisplayName'] = zh + suffix
    fid = uid('branding:' + target['name'])
    o[fid] = {'isa': 'PBXFileReference', 'path': '$(YIMA_BRANDING_DIR)/InfoPlist.xcstrings',
              'sourceTree': '<absolute>', 'lastKnownFileType': 'text.json.xcstrings'}
    o[p['mainGroup']]['children'].append(fid)
    add(target, 'PBXResourcesBuildPhase', fid)

# Localize the launch screen the same way the product name is localized: the
# storyboard's Base text is the English brand ("Yima") and the two Chinese
# localizations override the title to the Chinese brand ("一芥伙伴"). The
# storyboard file itself is not moved — its existing file reference becomes the
# Base member of a variant group, and the resources phase points at the group.
launch_storyboard = 'Launch Screen.storyboard'
launch_ref = next((key for key, value in o.items()
                   if value.get('isa') == 'PBXFileReference'
                   and value.get('path') == launch_storyboard), None)
assert launch_ref, 'Launch screen storyboard not found in the imported project'
o[launch_ref]['name'] = 'Base'
launch_children = [launch_ref]
for language in ['zh-Hans', 'zh-Hant']:
    strings = PHONE / (language + '.lproj/Launch Screen.strings')
    assert strings.is_file(), 'Missing launch screen localization: ' + str(strings)
    kid = uid('launch-strings:' + language)
    o[kid] = {'isa': 'PBXFileReference', 'lastKnownFileType': 'text.plist.strings',
              'name': language, 'path': os.path.relpath(strings, PHONE), 'sourceTree': 'SOURCE_ROOT'}
    launch_children.append(kid)
launch_group = uid('launch-storyboard-group')
o[launch_group] = {'isa': 'PBXVariantGroup', 'children': launch_children,
                   'name': launch_storyboard, 'sourceTree': '<group>'}
for key, value in list(o.items()):
    if key == launch_group:
        continue
    if value.get('isa') in ('PBXGroup', 'PBXVariantGroup') and launch_ref in value.get('children', []):
        value['children'] = [launch_group if child == launch_ref else child for child in value['children']]
    if value.get('isa') == 'PBXBuildFile' and value.get('fileRef') == launch_ref:
        value['fileRef'] = launch_group

OUT.mkdir(exist_ok=True)
with (OUT/'project.pbxproj').open('wb') as f: plistlib.dump(d,f,sort_keys=False)
scheme_dir=OUT/'xcshareddata/xcschemes';scheme_dir.mkdir(parents=True,exist_ok=True)
scheme=ET.parse(PHONE/'Minis.xcodeproj/xcshareddata/xcschemes/Minis.xcscheme')
for x in scheme.iter('BuildableReference'):
    if x.get('BlueprintIdentifier')==main_id:
        x.set('BlueprintName','VoiceContextAgent');x.set('BuildableName','VoiceContextAgent.app')
    x.set('ReferencedContainer','container:VoiceContextAgent.xcodeproj')
for test in scheme.iter('Testables'): test.clear()
scheme.write(scheme_dir/'VoiceContextAgent.xcscheme',encoding='UTF-8',xml_declaration=True)
for action in scheme.getroot():
    if 'buildConfiguration' in action.attrib: action.set('buildConfiguration', 'Debug-Dev')
scheme.write(scheme_dir/'VoiceContextAgentDev.xcscheme',encoding='UTF-8',xml_declaration=True)
workspace=ROOT/'VoiceContextAgent.xcworkspace';workspace.mkdir(exist_ok=True)
(workspace/'contents.xcworkspacedata').write_text('<?xml version="1.0" encoding="UTF-8"?>\n<Workspace version="1.0"><FileRef location="group:Vendor/Phone/src/ios/VoiceContextAgent.xcodeproj"/></Workspace>\n')
print('Generated VoiceContextAgent workspace with production and isolated development schemes.')
