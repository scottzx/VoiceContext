# TranscribeKit 分阶段迁移

日期：2026-10-01。用户已授权依次迁移、安装到手机和真机测试。禁止模拟器。

## 固定来源与依赖

- 产品使用仓库内 `Vendor/TranscribeKit` 快照，不依赖其他产品目录进行构建。
- `SOURCE_SNAPSHOT.json` 固定包文件 SHA-256、Swift 绑定版本 `0.2.3`、ABI 指纹 `7df72bf9e667b8c2`。
- 原包的 iOS 二进制缺少设备枚举符号，模型加载参数的 ABI 也早于 Swift 绑定；没有通过删除接口或跳过错误检查规避。
- 从 `https://github.com/handy-computer/transcribe.cpp.git` 的本地完整检出固定提交 `35ad52ec9cc3228a04165ff41106098e92c2d85e`，在忽略的 `build/asr-migration/native-source` 中重建。
- 仅执行 `TRANSCRIBE_XCFRAMEWORK_SLICES=ios-device scripts/ci/build_xcframework.sh`，替换快照中的 iPhone arm64 slice。其余 slice 未构建、未运行。原生来源、命令和产物指纹均记录在快照中，许可文本随快照保存。
- `VoiceContextAgent` 与 `VoiceRecording` 共用这个本地 Swift Package 的 `TranscribeNative` 和 `CTranscribeRuntime` 产品；后者显式链接该包管理的 C 运行库。原工程手工链接/嵌入的 C 框架已移除。

## 阶段与当前结果

| 阶段 | 当前状态 | 验证结果 |
|---|---|---|
| 1. 固定包来源 | 已完成 | 包文件指纹、原生源码提交和 ABI 对应；只重建 iPhone slice |
| 2. 统一工程依赖 | 已编译、签名、安装、真机测试 | 原 C 调用在新依赖上完成聊天、硬件 PCM 和会议短音频转写 |
| 3. 聊天/硬件迁移 | 已编译、安装、真机测试 | 改为 Model/Session API；短音频与基线逐字一致；48 kHz WAV、69.94 秒分段、空输入和损坏 WAV 均通过 |
| 4. 会议迁移 | 已编译、签名、安装、真机测试 | 改为 Model/Session/CancellationToken；保留语言、句子时间轴、性能指标、VAD/声纹处理与 Metal 门禁 |
| 5. 真机回归 | 已通过 | 69.94 秒会议输出九句；语言自动识别、静音拒绝、后台取消、前台恢复通过；三阶段短音频结果一致 |

## 安装和测试证据

- 设备：`scottxz`，iPhone 15 Pro，iOS 27.0，UDID `00008130-00063D581AFA001C`。
- 使用 `VoiceContextAgentDev` / `Debug-Dev`，Bundle ID `YiJie.speech-note.dev`。依赖、聊天和会议三个阶段分别安装、启动和读取真机报告。
- 签名编译、融合装配、四个扩展的设备授权、签名、四个清单模型 SHA-256 和单份 CTranscribe 动态框架检查通过。
- 增量安装成功，未卸载/清除数据。安装前后正式 `YiJie.speech-note` 的安装 URL、名称、版本和 Build 均未变化。
- 首次启动曾被系统拒绝为 Locked；用户解锁后继续运行，没有将此前的安装成功记作运行测试通过。
- 基线测试首先暴露后端名称断言不匹配：固定版本的 ggml 返回 `MTL0`，而非旧注释中的 `metal`。已用实际真机结果和原生 Metal 源码确认后修正测试；没有更改计算后端。
- 静音测试确认现有 VAD 抛出 `noSpeechDetected`，未进入 ASR 推理。
- 会议使用真实 VAD/分段及原生模型，短音频输出两句中文，所有句子时间范围与源音频偏移均通过检查。
- 三阶段比较确认硬件/聊天文本以及会议文本、原文、语言、后端、句数均一致。Metal 峰值并发为 1，结束后进行中的工作为 0。

本机证据位于忽略目录 `build/asr-migration/`：

- 报告：`dependency.json`、`chat.json`、`meeting.json`、`comparison.json`、`progress.json`。
- 编译：`dependency-probe-fixed-build.log`、`chat-build.log`、`meeting-build.log`。
- 安装/启动：`dependency-fixed-install.json`、`dependency-fixed-launch.json`、`chat-install.json`、`chat-launch.json`、`meeting-install.json`、`meeting-launch.json`。
- 装配/签名：`meeting-assembly-audit.json`、`meeting-signing-audit.json`。
- 应用隔离：`apps-before.json`、`apps-after-meeting.json`、`production-preservation.json`。

## 重复执行与验证范围

仅 DEBUG 编译包含探针；以 `--asr-migration-probe=dependency|chat|meeting` 启动 Dev 应用。探针使用内置 `SenseVoiceFixture.m4a`，直接调用真实识别服务，不创建或修改会议资料。报告写入 Dev 沙盒 `Documents/ASRMigration/<stage>.json`，必须读取 `passed: true` 才能记作通过。

硬件测试验证输入 PCM 和分段转写，未验证 BLE 传输及实体硬件按钮。会议后台测试直接驱动真实服务的生命周期接口，验证执行中取消、拒绝新 Metal 提交和前台恢复；用户于 2026-10-01 反馈已完成真实锁屏与来电测试；这属于用户实测反馈，非探针证据。麦克风连续录音仍未由本轮探针验收。用户发现的其他音频中断时锁屏卡片/灵动岛状态滞后已修复，真机 ActivityKit 回归及用户复测通过，见 `recording-live-activity-sync.md`。声纹/说话人流程保持原实现，此次探针未完整运行会后说话人整理。

会议补丁仅切换融合工程的 Native 路径；独立原录音 target 保留原 C 路径。此次编译和运行验证覆盖融合 Dev 工程；没有运行模拟器，也未验证其他平台 slice。
