# OpenMinis v1.13 融合记录

日期：2026-09-29。工作分支：`codex/openminis-v1.13`。

## 合入范围

从 OpenMinis 基线 `09fc199928de0f26685e766c34e6d541c7a69e5a` 合入到 `4ef29002e88db1e20e462ec2ff46916e8a7dcb45`（v1.13），覆盖已有 iOS 源码、相关构建脚本和共用依赖。Android 源码及 Android 专用 rclone 构建脚本不在本产品范围内。

采用“原上游基线 / 当前融合代码 / 目标上游”三方合并，没有把上游仓库整体合并到产品根目录。244 个上游路径逐项记录在 [openminis-v1.13-manifest.json](../../tools/integration/openminis-v1.13-manifest.json)，另行更新 iSH 的 4 个源码文件。原始导入 SHA 与文件指纹保留，当前上游和 iSH 版本记录在 [SOURCE_SNAPSHOT.json](../../Vendor/Phone/SOURCE_SNAPSHOT.json)。

主要更新包括：

- Agent 备份与恢复、文件夹 / rclone 远端目的地、流式备份包。
- 模型、语音、thinking、模型路由、用量归属修复。
- 聊天、同步、Intents、分享路由、Soul 图标及相关界面更新。
- iSH 内核、终端、Rootfs 故障处理及构建修复。

原有 403 个主 target 编译输入全部保留，合并后为 448 个。产品版本号仍由根目录 `VERSION` 控制；上游 v1.13 不作为听记的 App Store 版本号。

## 冲突处理与本地适配

15 个路径需要人工处理，已按模块职责解决：

- **共享领域模型**：fork 将 `RawMessage` 和 `SyncedMessage` 移到了 `src/apple/Domain`。上游新增的模型归属字段在共享模型中实现，覆盖初始化、旧数据解码、portable wire records 和 iOS 同步字段，避免恢复两套同名类型。
- **持久化与恢复**：同时保留群聊 `sender_agent_id` 和上游模型归属字段，核对 INSERT 参数与 SELECT 索引；备份恢复保留 Agent、父子会话、群聊角色和发送者关联。
- **Agent 工具**：保留已有 orchestrator / executor 工具策略，将上游大文件写入提示和浏览器 `full_page` 参数放回相应工具分支。
- **导航和输入**：保留融合四 Tab、现有聊天标题和已重构的语音输入框。上游仍修改的旧 `InlineVoiceInputView` 在 fork 中已被替代，不重新引入；依赖该旧输入框的键盘强制释放逻辑也不恢复。分享冷启动的目标会话修复迁入已有 `loadInitialWorkspace()`。
- **身份**：正式 / Dev Bundle ID、App Group、iCloud、Keychain、深链与 `FusionAudio.install()` 保留；上游 Info、字符串和 Xcode 工程按结构合并，版本冲突遵循本产品配置。
- **Soul**：保留群聊成员名称、标识与 Agent 人设，普通聊天接入上游自定义图标；Agent 人设保存时继续保留已有图标。
- **音频优先级**：新增备份静音保活通过 `AudioSessionCoordinator` 申请独立低优先级意图，不直接调用 `AVAudioSession.setCategory/setActive`。会议录音或语音采集开始时停止备份静音播放，备份本身继续按系统允许的后台时间运行；备份结束只释放自己的音频意图。

## 原生依赖

- iSH 更新到 `3f6384c70eefd1a370f121d3492a5f21f7767df9`，从 vendored 源码完成设备静态库重建；libapps / libarchive 固定版本未变。上游 `b_ndebug` 修复保留。
- Rclone 使用上游 `go.mod` 固定的 `v1.75.0`，完成 `Rclone.xcframework` 的 iphoneos arm64 构建。构建脚本已按项目约定去掉模拟器 slice。
- FFmpeg、LAME、Alpine、原录音推理框架等继续使用已有缓存，本次未宣称完成所有依赖的干净重建。
- 当前缓存指纹与重建来源更新在 [native-cache-manifest.json](../../tools/integration/native-cache-manifest.json)。原生二进制、iSH `build-ios/`、构建日志和工作区检查点保持本机忽略，不提交。

## 验证

- 开发身份 `VoiceContextAgentDev` / `Debug-Dev` 与正式身份 `VoiceContextAgent` / `Debug` 的最终未签名 iphoneos 构建均通过。
- 两种产品的 Bundle ID、容器、扩展、资源、录音 framework 加载路径及当前原生缓存审计均通过。
- 对合并后的真实 SQL 在内存 SQLite 中执行检查：消息 append/load 同时保留模型归属与群聊发送者，三个恢复 SQL 的列、占位符和语法通过准备检查。没有打开用户数据库。
- 已检查无剩余合并冲突标记、原有 403 个编译输入无丢失。

本机证据位于 `build/upstream-v1.13/`：`pre-merge.patch`、`pre-merge-files.tar.gz`、`ish-before.tar.gz`、`merge-report.json`、两项原生库构建日志、`device-build-final.log`、`production-build.log`、`audit-development-final.json`、`audit-production-final.json`。检查点包含合并前的未提交修改，用于本机回查，不作为源码提交。

## 验证边界

合并验证阶段未安装或启动新构建；后续 Dev 安装结果见下方。尚未执行新构建的启动验证、真机测试套件、Release 发行归档或上传。此前版本的启动验证不等于本次合并后的运行验证。下一轮真机需重点验证：录音过程中开始 / 结束备份、后台与来电恢复、聊天 / shell / 浏览器 / Skills、模型用量持久化与同步、备份恢复、Agent 与群聊关联、Dev 与正式身份隔离。

上游备份模块按自身类别处理 Agent 数据，不等于覆盖原听记 `Documents/VoiceContext` 的全产品备份；完整 Agent / 群聊档案、文稿和音频的备份恢复覆盖范围仍需专门验收。界面沿用已有 Phone 与上游组件，聊天头部装饰渐变及小于 44 pt 的点击区域等与 `DESIGN.md` 的差异仍待视觉和无障碍走查，不宣称已完成设计验收。


## 2026-09-29 Dev 真机安装

用户明确要求安装 Dev 后，完成 `VoiceContextAgentDev` / `Debug-Dev` 自动签名构建。主 App 与四个扩展签名有效，开发身份及容器核对通过，描述文件均覆盖 scottxz（iPhone 15 Pro）。USB 信任连接恢复后，已将 `YiJie.speech-note.dev` 1.0（7）覆盖安装为「听记 Dev」，未执行卸载。

安装前后核对正式 `YiJie.speech-note` 的安装 URL、版本号和 Build 号均未变化。本次仅安装，没有启动 App 或进行运行测试，也没有据此确认 Dev 数据迁移完整性。

证据：`build/upstream-v1.13/dev-signed-build.log`、`dev-signing-audit.json`、`dev-signed-audit.json`、`dev-install.json`、`dev-install-verification.json`；均保留在本机忽略目录。
