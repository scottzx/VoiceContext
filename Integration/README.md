# 听记个人智能体融合工程

需求：[#85 的设计依据](../docs/design/personal-agent-integration.md)。入口是仓库根目录 `VoiceContextAgent.xcworkspace`，scheme 为 `VoiceContextAgent`。

这是同一听记产品的新工程装配，主 Bundle ID 仍为 `YiJie.speech-note`。安装融合版会替换同身份的旧版。原 `speech_note/speech_note.xcodeproj` 继续可独立构建。

## 实现边界

- `Vendor/Phone`：完整 iOS 平台源码、Apple/shared 共用代码、资源、构建脚本及 iSH 源码快照；不是只复制 AgentRunEngine。
- `Integration/App`：四 Tab、系统提醒事项、音频桥接、文稿快照、录音产物预览。
- `Integration/Recording`：将原录音业务作为 `VoiceRecording.framework` 提供给宿主。独立 Swift 模块保留原 actor isolation，避免两套 `ContentView` 等类型冲突。
- `speech_note/speech_note`：复用原录音、转写、SQLite/journal、文稿、购买和设置；仅增加宿主入口与必要桥接。旧数据不搬进新 Agent 容器。
- 主模块名保留 `Minis`，以兼容 phone 原有 Objective-C/Swift 桥接与运行时类型查找；产品显示名、签名身份属于听记。

录音服务由 App 层持有，四 Tab 和语言切换共用同一个实例。恢复完成后再显示会议页，避免冷启动深链先于数据恢复开始录音。

## 已接通的产品流程

1. 聊天：保留 phone 会话和完整工具执行界面。
2. 会议：承接原听记全部 Recording。详情菜单「交给智能体」先刷新文字快照，再创建聊天草稿；用户发送后才执行。
3. 待办事项：EventKit 查询所有系统提醒事项列表，默认隐藏已完成；新增默认系统列表，编辑可选可写列表。可新增、修改、完成、删除，并响应外部变更和授权撤销。与 `apple-reminders` 共用系统数据。
4. 拓展：Skills、模型与服务、浏览器、终端、智能体、录音设置和 Agent 设置。
5. 录音详情「智能体产物」预览 `Generated/<recordingID>/` 的文件。来源 revision 由草稿和 Skill 要求写入结果；当前不是独立的 session/产物关系数据库。

## 容器及签名映射

| 用途 | 身份 |
|---|---|
| 主应用 | `YiJie.speech-note` |
| 原录音 Widget | `YiJie.speech-note.RecordWidget` |
| Agent Widget | `YiJie.speech-note.AgentWidget` |
| 分享扩展 | `YiJie.speech-note.ShareExtension` |
| FileProvider | `YiJie.speech-note.FileProvider` |
| 原文稿 iCloud | `iCloud.YiJie.speech-note` |
| Agent iCloud | `iCloud.YiJie.speech-note.agent` |
| Agent App Group | `group.YiJie.speech-note.agent` |
| 原 Keychain group | `$(AppIdentifierPrefix)com.yijie.shared_entitlements` |

生成器继承原听记的 Team、版本号、build 号，所有扩展保持一致。原文稿容器不可用时留在本地，不退到 Agent 容器。保留原 StoreKit 标识与既有数据相对路径。

2026-09-29：已通过 Xcode 自动签名完成 USB iPhone 15 Pro 的开发编译。主应用和四个扩展的 embedded provisioning profile 均包含该设备；签名中的新 App Group、iCloud 容器均由描述文件覆盖，保留原 Keychain 组。此次验证为开发签名，尚未验证发行归档与真机运行。

## 音频与文件契约

宿主 `AudioSessionCoordinator` 负责会话配置；独立听记构建走原路径。录音持有 UUID 所有权，优先于聊天采集、shell 采集、播报、媒体和后台静音。开始录音会停止聊天麦克风和播报、暂停媒体，并抑制已注册 WebView 的媒体音频；录音中的新浏览器/WebApp 麦克风请求被拒绝。系统中断是否恢复继续交给原录音状态机处理。暂停中的录音仍保有优先级。

来宾目录：`/var/minis/shared/VoiceContext/`。

- `Source/`：从原 `Documents/VoiceContext` 的 Meetings、Daily、Transcripts、Templates、Skill、Folders 复制的文字快照；单文件原子替换，排除原音频、数据库、journal、符号链接和已有 generated 目录。
- `Generated/<recordingID>/`：Agent 生成物。与原文分开；录音 ID 将结果与详情入口关联。
- `README.md` / `source-files.json`：工作区约定与本次源文件清单。清除消失源文件的旧快照，不自动删除生成结果或系统提醒事项。
- 内置 `voicecontext` Skill 经 `SkillStore` 实际登记。只在缺失时创建，不覆盖用户编辑的 Skill。

快照在启动、前台恢复、文稿发布以及「交给智能体」之前刷新。shell 仍是通用文件能力：Source 是与原文分离的副本，不是安全沙箱内不可写的挂载。这里不自动加入音频或自动发起模型请求；用户发起聊天后，模型请求遵循原 phone 的上下文/附件机制。

## 完整能力装配清单

下列能力均保留源码、构建输入及原启动链路；**未把编译通过计为真机运行验收**。

| 能力 | 来源（相对 `Vendor/Phone/src/ios`） | 当前验证 |
|---|---|---|
| 模型、认证、聊天、会话 | `Providers/`、`Agent/Chat/`、`Agent/Session/` | 全部主 target 编译输入保留 |
| shell、Alpine、文件工具 | `iSH/`、`Agent/ISH/`、`Agent/Shell/`、`NativeOffloads/` | 链接原生依赖，包内包含 Alpine 与 RootfsPatch |
| Skills | `Agent/Session/SkillStore.swift`、`Views/Skills/` | 原安装/加载链保留，增加录音 Skill 登记 |
| 浏览器、WebApp | `Agent/BrowserUse/`、`WebApp/` | 管理页与工具链保留，接入录音音频抑制 |
| AgentKit、子任务、MCP、记忆 | `AgentKit/`、完整 phone Agent 相关源码及 shared/apple | 原装配整体保留；已有占位能力不提升为完成状态 |
| 原生 Apple 工具 | `NativeOffloads/`（27 个 `*Offload.m`） | 参与编译；权限及系统服务尚未逐项运行 |
| 后台、通知、同步 | `Agent/Background/`、`Agent/Sync/`、`Shared/` | 原链路保留，新容器 ID 已映射；受 iOS 生命周期限制 |
| 分享、Agent Widget、FileProvider | `ShareExtension/`、`AgentWidget/`、`FileProvider/` | 三个扩展与原 RecordWidget 均已构建并嵌入 |
| 原录音/ASR/购买/文档 | 原 `speech_note` 源码 | 独立 app 和融合 framework 均编译通过 |

## 构建与依赖

验证环境：Xcode 26.6 / build 17F113，iOS deployment target 18.0。禁止模拟器。以下命令只编译，不签名、不装机、不运行：

```bash
bash tools/integration/build_device.sh
```

已有工作区的依赖缓存已经就位；`build/`、原生缓存和生成资源不提交。新 checkout 需要：

1. 恢复原听记使用的 `speech_note/speech_note/Frameworks/TranscribeCpp.xcframework` 与本地模型资源（原仓库既有依赖约定）。
2. 在 `Vendor/Phone` 按 `BUILDING.md` 的 **iOS 真机**流程依次构建 `deps/build_lame.sh`、`deps/build_ffmpeg.sh`、`deps/build_ish.sh`、`deps/prepare_alpine_rootfs.sh`，或从相同来源缓存复制 `deps/{libs,include,frameworks,resources}`。本次使用的是本机已有缓存，没有声称完成干净源码重建。
3. 运行 `python3 tools/integration/generate_project.py`。它会生成 assets/strings 和工程，并从 example 创建不含凭据的本地 provider 配置。
4. 如 SwiftPM 尚无缓存，用 Xcode 解析 workspace 内已锁定的 `Package.resolved` 依赖，再执行设备编译。不要直接搬带有另一仓库绝对 artifact 路径的 `workspace-state.json`。

`import_phone.py` 仅用于首次导入，会拒绝覆盖已有 Vendor。后续更新需对照来源清单人工合并本地补丁，不能重新覆盖。

非运行时审计：

```bash
python3 tools/integration/verify_fusion.py \
  --products build/VoiceContextAgent/Build/Products/Debug-iphoneos --check-cache
```

它核对原 phone 的 403 个编译输入、4643 个来源文件、产品身份、权限文案、原 Keychain、容器映射、四个扩展版本和关键资源。`--check-cache` 核对本次缓存指纹；自行重建原生库后二进制可不同，需要另行记录新构建来源。

## 来源与本地补丁

- phone：`02956e269857e32335b16b4d5e6af999ff14c6e1`。
- iSH：`19c690c3b979c3addef38318231b93a2dcdbe990`；libapps/libarchive 子模块 SHA 见 `Vendor/Phone/SOURCE_SNAPSHOT.json`。
- Android PRoot 和未启用的 Linux kernel 子模块不进入 iOS 移植范围。
- `tools/integration/phone-source-manifest.json` 保存修改前的来源指纹；审计输出列出本地补丁，包括身份映射、音频协调、入口、聊天草稿、SwiftUI 编译表达式拆分、浏览器媒体接线及快照构建支持。
- `tools/integration/native-cache-manifest.json` 单独保存本机原生依赖缓存指纹；缓存可能来自上游工作区历史构建，不能据此推断与已导入源码逐字一致。
- 未带入上游未提交 Swift/iSH 修改、登录凭据或本地 provider 秘钥配置。
- 提交前移除上游硬件桥源码内置的演示 API Key；Moss 继续使用硬件桥设置或 `MOSS_API_KEY` 配置，不随源码分发凭据。
- 保留 `Vendor/Phone/LICENSE`（GPLv3）及 `THIRD_PARTY_LICENSES.md`。原录音源码和引入代码分别保留来源；不要把仓库原 MIT 文件解释为替代第三方许可。

## 验证记录与下一步验收

2026-09-29：融合 Debug unsigned iPhone build、原独立听记同类 build、装配审计、Python/shell 语法检查通过。日志在本机 `build/`。没有执行设备测试，未使用模拟器，未安装覆盖已发布应用，未上传 TestFlight。

2026-09-29 USB 编译补充：对 `scottxz`（iPhone 15 Pro，iOS 27.0）执行实际设备目标的 Debug 开发签名编译，`BUILD SUCCEEDED`。`codesign --verify --deep --strict`、五个描述文件设备覆盖、App Group/iCloud 权限及装配审计通过。日志：`build/fusion-device-build.log`；签名核验：`build/fusion-device-signing-audit.json`。本次按「真机编译」执行，未安装或启动应用。

2026-09-29 覆盖安装补充：用户明确授权「在真机上安装，作为增量更新」后，使用 `devicectl device install app` 将融合开发签名包覆盖安装到同一台 `scottxz`，安装成功。安装前后均为 `YiJie.speech-note`、1.0（7），未执行卸载或数据清除；安装后查询已确认实际包为 `VoiceContextAgent.app`。安装前设备服务无法读取原 App Store 签名的数据容器，备份尝试未成功；安装后只读枚举确认历史音频与文稿仍在，但未做升级前后逐字节比对，也未启动应用。安装证据：`build/fusion-device-install.json`；安装后身份：`build/iphone-listening-after-update.json`；历史文件统计：`build/fusion-update-data-summary.json`。这些设备数据与证据仅保留在本机忽略的 `build/` 下。

2026-09-29 启动闪退修复：设备崩溃报告确认 dyld 在启动时尝试加载 `/Library/Frameworks/VoiceRecording.framework/VoiceRecording`，因此尚未进入界面即退出。生成器将原 app target 转为 framework 时缺少 `DYLIB_INSTALL_NAME_BASE=@rpath`；已在 Debug/Release 配置中修正，并在装配审计中核对产物 install name 与调用方依赖。新增检查在旧产物上失败、在重新签名构建的产物上通过，修正版已覆盖安装。首次启动前已成功备份 Documents（5391 个文件，389943707 字节），仅保留在本机 `build/device-backup-20260929-startup/Documents`。用户明确授权启动验证后，设备解锁时成功启动；同一进程持续运行超过两分钟，停止本机控制台读取后仍在运行，没有新增 VoiceContextAgent 崩溃报告。本次仅验证启动，未据此确认所有功能；继承的 ChatStore 首次建库还有先迁移后建表的错误日志，未在此次加载路径修复中改动。证据汇总：`build/fusion-startup-fix-report.json`。

后续真机功能验收：

- 同身份覆盖升级：录音、文稿、附件、购买恢复、iCloud 和 Widget 深链。
- 长录音跨四 Tab、语言切换、聊天语音、shell 语音、TTS、浏览器媒体、锁屏/后台、来电/蓝牙切换；检查原音频连续性与 gap。
- shell 执行、Skills 加载、浏览器操作、模型认证、同步和所有原生工具的真实权限/失败路径。
- 会议 → 聊天草稿 → 读取快照 → 保存产物 → 详情预览 → 系统提醒事项的全流程。
- 提醒事项拒绝/撤销权限、只读列表、外部编辑删除、带时间/重复的事项编辑。
- 四 Tab、全局停止入口、深色、Dynamic Type、VoiceOver、Reduce Motion；phone 继承页面仍需按 `DESIGN.md` 逐屏走查，不能视为已完成视觉验收。
