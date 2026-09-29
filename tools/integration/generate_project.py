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
# Phone and recording use the same original CTranscribe framework binary.
for fid,x in o.items():
    if x.get('isa')=='PBXFileReference' and x.get('name')=='TranscribeCpp.xcframework':
        import os
        x.update(path=os.path.relpath(ROOT/'speech_note/speech_note/Frameworks/TranscribeCpp.xcframework',PHONE),sourceTree='SOURCE_ROOT')
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
        resources['files'].remove(bid)  # old localized Minis display name must not override 听记
for path,kind in [(ROOT/'Integration/Resources/Localizable.xcstrings','text.json.xcstrings'),
                  (ROOT/'Integration/Resources/Assets.xcassets','folder.assetcatalog'),
                  (ROOT/'speech_note/speech_note/ModelResources','folder'),
                  (ROOT/'speech_note/speech_note/VoiceContextPack.zip','archive.zip')]:
    if path.exists(): add(main,'PBXResourcesBuildPhase',ref(path,kind))
# Preserve the full platform plist but use the released product's identity and privacy text.
with (PHONE/'Info.plist').open('rb') as f: info=plistlib.load(f)
with (ROOT/'speech_note/speech_note/Info.plist').open('rb') as f: original=plistlib.load(f)
# Move generated privacy strings into the merged plist so legacy product text
# cannot be silently overridden by Phone's INFOPLIST_KEY_* build settings.
phone_settings = o[o[main['buildConfigurationList']]['buildConfigurations'][0]]['buildSettings']
for key, value in phone_settings.items():
    if key.startswith('INFOPLIST_KEY_') and key.endswith('UsageDescription'):
        info[key.removeprefix('INFOPLIST_KEY_')] = value.replace('Yima', '听记')
for key,value in original.items():
    if key in ['UIBackgroundModes','CFBundleURLTypes','BGTaskSchedulerPermittedIdentifiers']:
        info[key]=info.get(key,[])+[x for x in value if x not in info.get(key,[])]
    else: info[key]=value
# Do not advertise the old app's shortcut branding.
info.pop('UIApplicationShortcutItems',None)
info['CFBundleDisplayName']='听记'
info['CFBundleName']='VoiceContext'
info['NSMicrophoneUsageDescription']='听记使用麦克风录制你主动开始的会议或日常语音，并在你选择语音输入时转为聊天文字。'
info['NSRemindersFullAccessUsageDescription']='在待办事项中展示和管理你的系统提醒事项，并让你授权的智能体任务使用同一份待办。'
for key, value in info.items():
    if key.endswith('UsageDescription') and isinstance(value, str):
        info[key] = value.replace('Yima', '听记')
info['NSUbiquitousContainers'] = {
    identifier: {'NSUbiquitousContainerIsDocumentScopePublic': True,
                 'NSUbiquitousContainerName': title, 'NSUbiquitousContainerSupportedFolderLevels': 'Any'}
    for identifier, title in [('iCloud.YiJie.speech-note', 'VoiceContext'),
                              ('iCloud.YiJie.speech-note.agent', '听记智能体')]
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
                      TARGETED_DEVICE_FAMILY='1', INFOPLIST_KEY_CFBundleDisplayName='听记',
                      INFOPLIST_KEY_CFBundleName='VoiceContext',
                      INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone='UIInterfaceOrientationPortrait')
        elif tid not in [record_id,widget_id]:
            bs['PRODUCT_BUNDLE_IDENTIFIER']=bs.get('PRODUCT_BUNDLE_IDENTIFIER','').replace('com.1agents.phone','YiJie.speech-note')
            bs['INFOPLIST_KEY_CFBundleDisplayName'] = {
                'MinisShare': '发送到听记', 'MinisFileProvider': '听记文件', 'AgentWidgetExtension': '智能体活动'
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
(ROOT/'Integration/Resources/Localizable.xcstrings').write_text(json.dumps(strings,ensure_ascii=False,indent=2)+'\n')
# Resources are generated above; first generation may not have found them earlier.
for path,kind in [(assets,'folder.assetcatalog'),(ROOT/'Integration/Resources/Localizable.xcstrings','text.json.xcstrings')]:
    fid=ref(path,kind)
    if not any(o[x].get('fileRef')==fid for x in resources['files']): add(main,'PBXResourcesBuildPhase',fid)
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
workspace=ROOT/'VoiceContextAgent.xcworkspace';workspace.mkdir(exist_ok=True)
(workspace/'contents.xcworkspacedata').write_text('<?xml version="1.0" encoding="UTF-8"?>\n<Workspace version="1.0"><FileRef location="group:Vendor/Phone/src/ios/VoiceContextAgent.xcodeproj"/></Workspace>\n')
print('Generated VoiceContextAgent workspace and recording framework target.')
