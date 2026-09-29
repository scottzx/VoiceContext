# 工程目录约定

本文描述融合后的工程。原录音代码继续位于 `speech_note/`，完整 Agent 平台源码位于 `Vendor/Phone/`，两者通过 `Integration/` 接入；统一入口是仓库根目录 `VoiceContextAgent.xcworkspace`。

## 工程与模块边界

| 目录 / 工程 | 职责 | 修改方式 |
|---|---|---|
| `Vendor/Phone/src/ios` | App 启动骨架、Agent、模型认证、shell、Skills、浏览器及 Phone 扩展 | 在本仓库的导入源码上做必要适配 |
| `Vendor/Phone/src/apple`、`src/shared` | Apple 共用领域代码、跨平台共用规则 | 保留来源边界，按需要修改 |
| `speech_note/speech_note` | 原录音、转写、文稿、购买、设置等业务 | 保留相对路径，同时兼容原独立工程 |
| `Integration/App` | 四 Tab、音频桥、会议快照、产物预览、系统提醒事项 | 融合专用代码放这里 |
| `Integration/Recording` | 对宿主暴露 `VoiceRecordingWorkspace` | 与原录音源码一起编入 `VoiceRecording.framework` |
| `Integration/Shared` | App 与 Agent 扩展共用的开发 / 正式身份 | 生成器加入对应 target 的 Sources |
| `Vendor/Phone/src/ios/VoiceContextAgent.xcodeproj` | 生成的融合 targets、配置和 Schemes | 修改生成器后重新生成 |
| `speech_note/speech_note.xcodeproj` | 原独立录音工程，同时是融合生成器的输入 | 保留独立构建能力与版本设置 |
| `Vendor/Phone/src/ios/Minis.xcodeproj` | 原 Phone 工程，作为融合生成器输入 | 不是融合版日常打开的入口 |

融合主 Swift 模块名保留 `Minis`，产品 target 为 `VoiceContextAgent`。原录音代码成为独立 `VoiceRecording` 模块，原 `@main` 在 `VOICE_AGENT_FUSION` 条件下停用，避免两个应用入口以及同名类型冲突。录音模型没有整体搬进 Phone 的 Agent Store。

主 App 嵌入 `RecordWidgetExtension`、`AgentWidgetExtension`、`MinisShare` 和 `MinisFileProvider` 四个扩展。开发版给主 App 和扩展使用独立 `.dev` 身份，详见[构建与发布切换](../release/build-variants-and-release.md)。

## 原录音代码的内部结构

以下路径均相对 `speech_note/speech_note/`：

- `App/`：原应用入口、Deep Link、本地化。
- `Features/`：Home、Recording、Transcription、Speakers、Documents、Import、Export、Clients、Folders、Purchase、Onboarding 等业务。
- `Features/Recording/Persistence/`：录音仓库、索引与附件；`Features/Recording/LiveActivity/`：录音实时活动。
- `Features/Speakers/Voiceprints/`：声纹档案、密钥、加密与镜像。
- `Infrastructure/`：推理运行时、系统权限和归档工具。

`speech_note/RecordWidget/` 与 `speech_note/LiveActivityShared/` 保留原位置和目标职责。原 App、Widget 中各自的实时活动类型继续按原工程装配，不随意合并文件。

## 工程生成和新增文件

融合生成入口为 [tools/integration/generate_project.py](../../tools/integration/generate_project.py)，由原 Phone 工程和原录音工程生成融合工程、主 App 的 Info / entitlements、Dev 配置及合并资源。

```bash
python3 tools/integration/generate_project.py
```

- 原独立录音工程使用文件系统同步分组。融合生成器则显式加入录音源码，并扫描 `Integration/App/*.swift` 与 `Integration/Recording/*.swift`；新增这些文件后需重新生成。
- Phone 的文件成员关系来自导入的 `Minis.xcodeproj`。新增 Phone 源文件时，应维护生成器的输入工程或生成逻辑，不能只把文件放进目录。
- `Integration/Shared/AgentBuildIdentity.swift` 由生成器显式加入主 App 和三个 Agent 扩展。新增跨 target 文件时同样需声明成员关系。
- 融合业务放 `Integration`，录音业务留在原 Features，Agent 业务留在 Phone 对应目录。不要为了新增融合功能复制整套录音模型或重排上游目录。
- `Integration/*Dev.Info.plist`、`Integration/*Dev.entitlements`、主 App 的 `Integration/Info.plist` / `VoiceContextAgent.entitlements`、融合工程与 Schemes 都由生成器维护。持久改动应落在源配置或生成器中，避免下次生成被覆盖。

版本号链路是根目录 `VERSION` 经 `tools/sync_version.py` 同步到原录音工程，再由融合生成器统一到主 App、framework 和扩展。旧 `tools/release.sh` 的归档目标仍为原 `speech_note`，不用于融合版归档。

## 源码快照、资源与构建产物

- `Vendor/Phone` 是本仓库内的源码快照，包含 iOS、Apple/shared 及 iSH 相关源码；不是旁边 `1agents_phone` 仓库的链接。来源见 `Vendor/Phone/SOURCE_SNAPSHOT.json` 和 `tools/integration/phone-source-manifest.json`。
- `tools/integration/import_phone.py` 仅供首次导入，会拒绝覆盖已存在的 Vendor。后续直接从 OpenMinis 合入所需更新，保留已导入的 fork 定制与融合适配，不再通过 `1agents_phone` 中转；见[上游维护约定](openminis-upstream.md)。不直接重新导入覆盖。
- 原 `Info.plist`、entitlements、隐私清单、StoreKit 文件、模型、原生框架及 `VoiceContextPack.zip` 保持既有来源路径；融合生成器把需要由 `Bundle.main` 加载的录音资源放入主 App 包。
- `Integration/Resources/Assets.xcassets` 和 `Localizable.xcstrings` 是合并生成资源，已在 Git 中忽略。`Integration/Resources/Branding/` 按 target / 配置生成一芥伙伴 / Yima 的本地化显示名，保留 Dev 后缀，同样不提交。
- `Vendor/Phone/deps` 中的依赖源码保留；`libs`、`include`、`frameworks`、`resources` 等本机原生构建缓存被忽略。缓存准备方式见[融合工程说明](../../Integration/README.md#构建与依赖)。
- `build/VoiceContextAgent` 保存 DerivedData 与产品，`build/PhonePackages` 保存 SwiftPM 缓存；`build/` 下的日志、备份、签名和设备证据不提交。
- `tools/VoiceContext/` 是公开 Skill / 模板源文件；`speech_note/Supporting/VoiceContextPack/` 和 ZIP 由 `tools/sync-voicecontext-pack.sh` 生成。
- 根目录 `transcribe.cpp` 是本地外部依赖符号链接；新环境需要准备实际依赖，不能仅凭存在这个链接就认定依赖完整。

## 源码目录与运行时数据

源码位置不等于手机数据位置。原录音资料仍使用各自 App 沙箱内的 `Documents/VoiceContext`。Agent 读取的会议文字快照位于 shell 来宾目录 `/var/minis/shared/VoiceContext/Source`，产物位于 `Generated/<recordingID>/`，不自动覆盖原文。

开发版与正式版使用各自的沙箱、App Group、iCloud 和 Keychain；相同相对目录名不代表共享数据。系统提醒事项由 EventKit 管理，属于 iPhone 系统数据。

## 测试与文档

原录音单元测试位于 `speech_note/speech_noteTests/`，UI 测试位于 `speech_note/speech_noteUITests/`；Phone 快照也保留其测试源码。生成的融合 Schemes 当前未接入这些测试 targets，不能把源码存在或装配审计通过等同于测试套件已运行。

`tools/integration/verify_fusion.py` 检查源码装配、身份、容器、扩展、资源和录音 framework 加载路径。它不验证实际录音连续性或 Agent 工具调用。项目禁止使用模拟器；代理运行 App 或真机测试需用户明确授权。

产品、设计、架构、测试、发布材料分别放在 `docs/` 已有子目录，入口为[文档索引](../README.md)。开发 / 正式身份切换以及上传流程见[开发版、TestFlight 与正式版切换](../release/build-variants-and-release.md)。
