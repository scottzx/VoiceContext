# 工程目录约定

主应用源码位于 `speech_note/speech_note/`，按 App、Features、Infrastructure 三部分组织。此次整理仅调整文件归属，仍使用原有 `speech_note` Swift 编译模块及 target，不引入 Swift Package 或访问控制变化。

## 文件归属

- `App/`：应用启动、Deep Link、本地化和截图自动化入口。
- `Features/`：业务功能的界面、模型及服务放在一起；按 Home、Recording、Transcription、Speakers、Documents、Import、Export、Clients、Folders、Purchase、Onboarding 查找。
- `Recording/Persistence/`：录音仓库、索引、日志及附件；`Recording/LiveActivity/`：主应用侧实时活动管理。
- `Speakers/Voiceprints/`：声纹归档、密钥、加密及云端镜像。
- `Infrastructure/`：Inference 保存模型校验与原生推理适配，Permissions 保存定位权限访问，Archives 保存 ZIP 工具。
- `speech_noteTests/`：按对应业务功能分组，`Fixtures/` 留在测试根目录共享；使用 `#filePath` 的测试须从实际文件位置解析资源。
- `RecordWidget/` 与 `speech_noteUITests/`：各自保持独立 target。Widget 与主应用各自的 `RecordingActivityAttributes.swift` 保留，不合并 target 归属。

## Xcode 与资源路径

工程使用 `PBXFileSystemSynchronizedRootGroup`，源码子目录由 Xcode 自动递归同步，不需要为每个 Swift 文件添加工程引用。目录分组不构成独立编译模块，也不强制单向依赖。

Info.plist、entitlements、PrivacyInfo.xcprivacy、Products.storekit、Assets.xcassets、VoiceContextPack.zip、ModelResources 和 Frameworks 保持既有位置，避免改变构建配置、签名、资源查找和脚本接口。

`tools/VoiceContext/` 是公开 Skill/模板源文件；`speech_note/Supporting/VoiceContextPack/` 和应用中的 ZIP 是同步脚本产物，使用现有 `tools/sync-voicecontext-pack.sh` 更新，不手工合并或删除。

`docs/` 中公开 HTML 页面保留路径，产品、设计、架构、测试、发布材料分别使用现有子目录。`build/`、设备证据、个人工具配置和 `transcribe.cpp` 外部依赖链接保持原位。

## 新增文件

优先放入已有业务目录。仅被某个功能使用的服务随该功能存放；跨功能且与平台或底层文件格式有关的实现放入 Infrastructure。共享的文稿能力归 Documents，录音持久化归 Recording/Persistence。新增测试放入对应分组，共享样本放入 Fixtures。

纯目录整理应校验移动前后内容一致、源码集合完整、资源相对路径有效、工程配置可解析。遵循 AGENTS.md：禁止模拟器，真机运行或测试需用户明确授权。
