# 开发版、TestFlight 与正式版切换

更新日期：2026-09-29。适用于一芥伙伴 / Yima 个人助手融合工程。产品已更名，Bundle ID 不变；App Store Connect 显示名称需随后续发布另行更新。

同一套源码通过 Scheme 和构建配置选择安装身份，不需要复制代码或手工把 Bundle ID 改来改去。开发版用于日常调试；TestFlight 和 App Store 正式版沿用现有听记的产品身份。

## 1. 选择构建入口

统一打开仓库根目录的 [VoiceContextAgent.xcworkspace](../../VoiceContextAgent.xcworkspace/contents.xcworkspacedata)。

| 用途 | Scheme | 构建配置 | Bundle ID | 安装行为 |
|---|---|---|---|---|
| 日常开发、USB 真机调试 | `VoiceContextAgentDev` | `Debug-Dev` | `YiJie.speech-note.dev` | 显示为「一芥伙伴 Dev / Yima Dev」，与现有听记并存 |
| 明确验证同身份覆盖升级 | `VoiceContextAgent` | `Debug` | `YiJie.speech-note` | 覆盖设备上的现有听记 |
| TestFlight 测试版 | `VoiceContextAgent` | Archive 使用 `Release` | `YiJie.speech-note` | 测试者安装时替换同身份的听记；Dev 仍可并存 |
| App Store 正式版 | 使用测试通过的正式身份构建 | `Release` | `YiJie.speech-note` | 作为现有听记的新版本更新 |

`VoiceContextAgentDev` 的 Archive 也使用 `Debug-Dev`，不会自动转为正式身份。准备向现有听记的 App Store Connect 记录上传时，必须选择 `VoiceContextAgent`。

原 `speech_note/speech_note.xcodeproj` 保留独立录音应用的构建能力。发布融合版使用上表中的 workspace 和 Scheme。

## 2. 身份与数据隔离

| 项目 | 正式身份 / TestFlight | 开发身份 |
|---|---|---|
| App 名称 | 一芥伙伴 / Yima | 一芥伙伴 Dev / Yima Dev |
| 主 Bundle ID | `YiJie.speech-note` | `YiJie.speech-note.dev` |
| 原录音 Widget | `YiJie.speech-note.RecordWidget` | `YiJie.speech-note.dev.RecordWidget` |
| Agent Widget | `YiJie.speech-note.AgentWidget` | `YiJie.speech-note.dev.AgentWidget` |
| 分享扩展 | `YiJie.speech-note.ShareExtension` | `YiJie.speech-note.dev.ShareExtension` |
| FileProvider | `YiJie.speech-note.FileProvider` | `YiJie.speech-note.dev.FileProvider` |
| 录音文稿 iCloud | `iCloud.YiJie.speech-note` | `iCloud.YiJie.speech-note.dev` |
| Agent iCloud | `iCloud.YiJie.speech-note.agent` | `iCloud.YiJie.speech-note.dev.agent` |
| App Group | `group.YiJie.speech-note.agent` | `group.YiJie.speech-note.dev.agent` |
| Keychain group | `$(AppIdentifierPrefix)com.yijie.shared_entitlements` | `$(AppIdentifierPrefix)com.yijie.shared_entitlements.dev` |
| 录音入口 | `voicecontext://` | `voicecontext-dev://` |
| Agent 分享入口 | `minis://` | `minis-dev://` |

开发版从独立数据开始，不自动复制正式录音、文稿、聊天或登录配置。两边可以使用相同的沙箱内相对路径（如 `Documents/VoiceContext`），实际属于不同的 App 数据容器。开发版构建定义 `VOICE_AGENT_DEV`，使运行时代码与签名权限选择同一组身份。

系统提醒事项等 iPhone 系统服务仍使用同一份系统数据；开发版获得权限后，对提醒事项的修改仍会反映到系统。第三方 OAuth 回调保留原有约定，双安装登录流程需要另行验证。开发 Bundle ID 不继承正式 App Store 的内购商品关联。

切换 Scheme 只影响下一次构建，不会迁移已有数据、卸载另一个版本，或将此前覆盖安装的听记自动还原为 App Store 版本。

## 3. 日常开发与本地编译

在 Xcode 中选择 `VoiceContextAgentDev` 和已连接的 iPhone，再 Build / Run。遵守仓库约定：禁止模拟器；代理运行真机 App 或测试前需要用户明确授权。

以下命令均在仓库根目录执行，只进行未签名的 iPhone 目标编译与装配检查，不安装、不运行、不上传：

```bash
# 默认：开发身份，Debug-Dev
bash tools/integration/build_device.sh

# 显式选择开发身份，与默认行为一致
bash tools/integration/build_device.sh development

# 正式 Bundle ID 的 Debug 编译检查
bash tools/integration/build_device.sh production
```

开发产物位于 `build/VoiceContextAgent/Build/Products/Debug-Dev-iphoneos/VoiceContextAgent.app`；正式身份 Debug 产物位于 `Debug-iphoneos/VoiceContextAgent.app`。

`production` 参数表示正式产品身份，**不表示发行归档**。该脚本仍使用 `Debug` 和 `CODE_SIGNING_ALLOWED=NO`，产物不能直接用于 TestFlight 上传。

## 4. 从开发版转到 TestFlight

1. 在 Dev 中验证录音连续性、后台恢复、聊天、shell、Skills、浏览器和提醒事项。切回正式身份后，再验证旧录音及文稿升级、正式 iCloud、Widget 深链和购买恢复。Dev 数据隔离，因此不能代替正式身份的升级验证。
2. 查看 App Store Connect 中现有版本与已上传 Build，确定本次版本号和新的 Build 号。本文记录时本地为 `1.0 (7)`，不据此推断线上最新编号。
3. 在根目录 [VERSION](../../VERSION) 中设置本次 `VERSION` 和 `BUILD`，再依次同步原工程与融合工程：

   ```bash
   python3 tools/sync_version.py --sync-only
   python3 tools/integration/generate_project.py
   ```

   `sync_version.py` 将版本同步到原 [speech_note 工程](../../speech_note/speech_note.xcodeproj/project.pbxproj)的各 target / 配置，并更新原发布文档中的版本字段。融合生成器再从 `speech_note` target 继承 Team、版本号和 Build 号，统一应用到融合主 App、录音 framework 与四个扩展。只修改生成后的融合工程会在下次生成时被覆盖；只修改原工程而不更新 `VERSION`，也会被后续版本同步覆盖。修改切换规则本身应编辑 [generate_project.py](../../tools/integration/generate_project.py)。

   旧 `tools/release.sh` 仍归档原独立录音工程，不用于融合版归档；融合版使用下面的 Xcode 步骤或命令行步骤。

4. 打开 `VoiceContextAgent.xcworkspace`，选择 `VoiceContextAgent`，确认 Archive 的 Build Configuration 为 `Release`。选择已连接 iPhone 或 `Any iOS Device (arm64)` 构建目标，再执行 `Product > Archive`。
5. 在 Organizer 中选择本次归档，执行 `Distribute App > App Store Connect`，完成发行签名、校验和上传。若计划让同一构建进入外部测试及正式发布，不要选择仅限 TestFlight 内部测试的分发方式。[Apple 上传说明](https://help.apple.com/xcode/mac/current/en.lproj/dev442d7f2ca.html)
6. 等待构建处理完成，在 App Store Connect 的现有「听记」记录中进入 TestFlight，填写测试说明并配置内部或外部测试组。外部测试可能需要 Beta 审核。[TestFlight 流程](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/)

只创建 Release 归档的命令行等价操作如下。它会请求签名配置，但不会上传、安装或运行；使用前需按[融合工程说明](../../Integration/README.md)准备依赖。

```bash
python3 tools/integration/generate_project.py
xcodebuild -workspace VoiceContextAgent.xcworkspace \
  -scheme VoiceContextAgent -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/VoiceContextAgent \
  -clonedSourcePackagesDirPath build/PhonePackages \
  -disableAutomaticPackageResolution \
  -archivePath build/archives/VoiceContextAgent.xcarchive \
  -allowProvisioningUpdates CODE_SIGN_STYLE=Automatic archive
```

上传前核对归档的主 App 为 `YiJie.speech-note`，四个扩展也使用正式前缀；容器、Keychain、版本和 Build 号均应对应正式身份。可对归档内的产品执行现有装配审计：

```bash
python3 tools/integration/verify_fusion.py --variant production \
  --products build/archives/VoiceContextAgent.xcarchive/Products/Applications
```

该审计检查装配和身份，不代替 Xcode 的发行签名校验、App Store Connect 处理及 Apple 审核。TestFlight 使用正式身份，测试安装会替换同一台手机上的正式听记；验证覆盖升级前应保留可恢复备份，沿用原数据容器而非先卸载。

## 5. 从 TestFlight 转到 App Store 正式版

1. 测试通过后，在现有听记的 App Store Connect 记录下创建与构建版本号匹配的新版本。
2. 更新版本说明、截图、App 隐私信息和审核说明；功能与旧版差异应反映在发布材料中。
3. 选择已测试通过且可用于正式发布的同一构建，提交 App Review。通常不需要为了“转正式”重新编译；如果继续修改代码，则递增 Build、重新上传并验证。[选择提交构建](https://developer.apple.com/help/app-store-connect/manage-builds/choose-a-build-to-submit)
4. 按本次版本选择的发布方式，在审核通过后发布。继续日常开发时切回 `VoiceContextAgentDev`，正式发布不会改变开发版身份。

## 6. 当前验证边界

截至 2026-09-29，已完成开发身份的真机签名编译、四个扩展权限核对、并存安装和启动检查；开发版持续运行 84 秒且无新增崩溃报告，原听记安装位置和版本未变。正式身份也已完成开发签名的覆盖安装及启动检查。

尚未执行此次融合版本的 Release 归档、App Store Connect 上传、TestFlight 分发或完整功能与升级验收。详细证据和后续验收范围见[融合工程说明](../../Integration/README.md)。
