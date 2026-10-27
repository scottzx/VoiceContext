# OpenMinis 上游维护约定

决策日期：2026-09-29。

## 单仓开发

`voice_type` 是唯一产品开发、提交、构建与交付仓库：录音代码在 `speech_note/`，Agent 代码在 `Vendor/Phone/`，融合代码在 `Integration/`。Agent 的后续上游来源为 [OpenMinis/OpenMinis](https://github.com/OpenMinis/OpenMinis)，跟踪 `main`。

`1agents_phone` 不再作为独立产品仓库维护，也不再承担上游更新中转。原本地目录和远端可以作为历史留档保留；本次没有删除目录或归档远端。已有定制能力由 `voice_type` 承接。

## 来源与基线

| 记录 | 值 / 含义 |
|---|---|
| 官方上游 | `https://github.com/OpenMinis/OpenMinis.git` |
| 本地上游 remote | `openminis`，用于读取和比较 |
| 产品 remote | `origin`，继续指向现有 VoiceContext 产品仓库 |
| 首次导入仓库 | `https://github.com/scottzx/1agents_phone.git`，仅历史来源 |
| 首次导入提交 | `02956e269857e32335b16b4d5e6af999ff14c6e1` |
| 首次导入的 OpenMinis 基线 | `09fc199928de0f26685e766c34e6d541c7a69e5a` |
| 当前 iOS 合入基线 | `4ef29002e88db1e20e462ec2ff46916e8a7dcb45`（v1.13；保留本地适配）|
| 最新已拉取的上游 main | `1a71df0f381cefde80bf912b723de6f9831bc177`（v1.15 + Tailscale 修复；2026-10-27 拉取，未合入）|

首次导入包含 fork 的 AgentKit、硬件桥、云端子 Agent 等定制，不能将首次导入 SHA 改写成 OpenMinis SHA，也不能直接用官方源码覆盖现有目录。上游基线来自导入提交与原 `upstream/main` 的共同祖先；它不表示已跟上当前最新上游。

[SOURCE_SNAPSHOT.json](../../Vendor/Phone/SOURCE_SNAPSHOT.json) 记录来源地址、原始 SHA、上游基线与维护策略；[phone-source-manifest.json](../../tools/integration/phone-source-manifest.json) 保留首次导入文件指纹。后者是历史审计依据，不为消除本地修改提示而重算。原生缓存指纹也不等于源码版本验证。

## 获取上游

Git remote 配置仅保存在本地 `.git/config`，不会随普通克隆传递。新检出仓库时，先查看已有 remotes；尚无 `openminis` 时再添加：

```bash
git remote -v
git remote add openminis https://github.com/OpenMinis/OpenMinis.git
git fetch --no-tags openminis main
```

已有该 remote 时只执行 fetch。获取远端提交不会更新 `Vendor/Phone`，也不会改变当前工作分支。正常提交与推送仍面向产品 `origin`。

查看上游相对当前 iOS 合入基线的变化（首次导入与 v1.13 的对比保留在下方历史记录）：

```bash
git log --oneline 4ef29002e88db1e20e462ec2ff46916e8a7dcb45..openminis/main
git diff --stat 4ef29002e88db1e20e462ec2ff46916e8a7dcb45 openminis/main -- src/ios src/apple src/shared deps scripts
```

## 合入更新

1. 在 `voice_type` 创建本次更新分支，固定目标 OpenMinis SHA，记录需要的修复或功能范围。
2. 对照上游基线、目标上游和本地源码，按文件合入。上游 `src/ios/` 对应本地 `Vendor/Phone/src/ios/`，其他已导入目录按相同前缀映射；新增文件还需检查融合工程成员关系。部分目录可能是 fork 新增，应保留。
3. 保留产品身份、Dev 隔离、录音优先、会议上下文、已导入的 fork 能力和凭据移除等本地适配。上游更新涉及 iSH 或其他子模块时，单独审核对应源码、固定版本和原生库重建需求。
4. 重新生成融合工程，执行静态装配审计，再按变更范围进行设备编译和获得授权的真机验证。遵守项目禁止模拟器的约定。
5. 将目标 SHA、实际合入的提交 / 文件范围、冲突处理和验证结果记录在 `docs/`，与代码一起提交。只有完成相应范围的合并后才能推进该范围的基线；选择性修复不能记作完整升级。

```bash
python3 tools/integration/generate_project.py
python3 tools/integration/verify_fusion.py --variant development
python3 tools/integration/verify_fusion.py --variant production
```

两仓库根目录布局和 Git 历史不同，不在产品分支直接执行 `git pull openminis main`、整体 merge 或未经路径适配的 cherry-pick。`import_phone.py` 是首次导入工具，会拒绝覆盖已有 Vendor，不作为更新工具使用。

最初配置阶段仅确定单仓维护策略、配置直接上游并补充来源记录；没有升级 Agent 源码，也没有移除既有功能。

## 2026-09-29 上游拉取记录

已成功执行 `git fetch --no-tags openminis main`，建立本地 `openminis/main`：

- 上游提交：`4ef29002e88db1e20e462ec2ff46916e8a7dcb45`，`Merge pull request #289 from OpenMinis/v1.13`。
- 上游提交时间：2026-09-02 02:19:16 +08:00；这是提交时间，不是本次拉取时间。
- 已确认原基线 `09fc199928de0f26685e766c34e6d541c7a69e5a` 是该提交的祖先，两者之间新增 11 个提交。
- 上游整仓差异为 483 个文件，新增 107,203 行、删除 5,063 行，包含 Android 变更；此数字不代表融合产品需要全部移植。
- iOS 相关变化主要涉及备份恢复（文件夹 / rclone、流式包写入）、模型服务与语音、thinking 与模型路由、聊天 / 同步 / 用量 / Intents / 界面，以及 iSH 内核与终端相关更新。以上按提交说明归类，尚未逐项评估融合兼容性。

本次利用本机保留的历史上游对象减少重复下载，随后从官方 remote 完成增量传输；这些对象已进入 `voice_type` 自身的 Git 对象库，不依赖旧仓库的对象链接。后续直接 fetch `openminis` 即可。

上述拉取阶段只获取上游历史并核对差异，没有 merge、cherry-pick 或覆盖 `Vendor/Phone`。产品实际合入基线仍为原记录，既有定制与工作区未提交代码继续保留；后续按上面的更新流程选择并合入具体变更。

后续已按用户要求将 v1.13 的 iOS 及共用依赖更新合入融合工程。当前适配、检查和运行验证边界见 [v1.13 合并记录](openminis-v1.13-integration.md)。

## 2026-10-09 免费转写与按需模型分发定制

本次是产品 fork 定制，不推进 OpenMinis 上游基线。`src/ios/AppDelegate.swift` 在融合条件下桥接产品的后台下载 session；`HardwareBridge/Transcription/HardwareVoiceTranscriber.swift` 从已校验的持久模型目录加载，缺模型时请求打开下载页；`Views/Chat/AIChatView.swift` 在开始本地 SenseVoice 输入前检查模型并展示产品下载页。`Providers/Voice/VoiceProvider+SenseVoice.swift` 更新模型来源注释。

以上适配通过 `VOICE_AGENT_FUSION` 与独立上游模块隔离。保留原聊天的系统 / 云语音和固定 RealTimeCutVADLibrary 依赖，未修改 TranscribeKit 快照。后续合并上游时保留这些下载入口、生命周期桥接与模型路径适配。设计与验证边界见[免费转写与魔搭按需模型下载](../design/free-transcription-model-download.md)。

## 2026-10-20 美食地图融合定制

本次是产品 fork 定制，不推进上游基线。`Agent/Chat/AIChatViewModel+ConcurrentTools.swift` 在 `VOICE_AGENT_FUSION` 分支分派 `yima_places`，独立传递当前执行代次和语音导航绑定；`AIChatViewModel.swift` 只为支持该工具的融合主会话增加真实搜索、收藏、地图展示和导航回执规则。子 Agent 和完成通知回合不获得本工具权限。

真机试用后产品负责人追加选择收藏确认弹窗：工具等待用户核对名称、完整地址和最终标签并点击确认；主聊天提示词同步要求不以口头收藏或页面跳转代替按钮确认，取消/失效后不自动重复弹窗。原生确认状态机、页面、语音输入等待和导航恢复仍由 `Integration` 承接。

地图页面、搜索、收藏、标签及导航交接均在 `Integration/App`，未改动原生 `apple-maps` 或 `apple-location` 桥接。后续合并上游时保留上述两处融合接入及工具运行策略。设计与验证见[美食地图](../design/food-map.md)和[实施检查记录](../testing/food-map.md)。

## 2026-10-22 DSH 远程聊天定制

本次为产品 fork 定制，不推进上游基线。`ContentView` 增加融合版会话来源切换；`AIChatView` / `AIChatViewModel` 保留本机路径并接入独立 `Agent/RemoteDSH` 客户端和展示 driver。消息列表复用原有渲染，远程工具使用只读详情，避免访问本地终端/文件；缓存增加来源、origin 与草稿别名隔离。生成器显式加入新增源文件。

后续合并上游时保留这些分派、无本机执行/持久化副作用的边界及页面长表达式拆分。网络只使用 Tailscale；服务元数据和受保护凭据不属于上游同步数据。设计与验证见[接入设计](../design/dsh-remote-chat.md)和[实施检查](../testing/dsh-remote-chat.md)。

## 2026-10-27 上游拉取记录（v1.14 / v1.15）

已执行 `git fetch --no-tags openminis main`，`openminis/main` 由 `b4c0661` 前进到 `1a71df0`：

- 上游提交：`1a71df0f381cefde80bf912b723de6f9831bc177`，`Merge pull request #495 from OpenMinis/android-1.15-tailscale-fix`。
- 上游提交时间：2026-10-26 19:16:16 +08:00；这是提交时间，不是本次拉取时间。
- 相对当前 iOS 合入基线 `4ef29002e88db1e20e462ec2ff46916e8a7dcb45`（v1.13）新增 36 个提交（其中非合并提交 33 个），基线仍是上游 main 的祖先。
- 上游整仓差异 2806 个文件，新增 721,547 行、删除 95,948 行，含大量 Android 变更；此数字不代表融合产品需要移植的范围。
- iOS 相关范围（`src/ios`、`src/apple`、`src/shared`、`deps`、`scripts`）差异 1055 个文件，新增 472,094 行、删除 83,641 行；其中 `src/ios` 单独 952 个文件。

主要上游内容：

- **v1.14**（`b4c0661`）：iOS 聊天 / 同步 / Intents / 本地化、Providers 与 thinking、备份恢复、iSH 推进到 1.14、脚本与依赖修复。
- **v1.15**（`6eda552`）：iOS Agent / 聊天 / ask-user / 分享与界面、Providers / OAuth / thinking / 语音、备份恢复、iSH 推进到 1.15（含 AOJIT 运行时与沙箱）、构建脚本修复；Android 侧为 1.15 beta。
- **Tailscale 出口节点修复**（`ee718c6`、`b518a7c`）：Go 侧网络行为调整，Android 版本 1.15。

与本地融合的交叉点（尚未合入，仅评估）：

- 上游对 `src/ios` 做了大规模目录拆分：`Views/Chat/AIChatView.swift` → `Views/Chat/AIChatView/*`、`Views/ContentView.swift` → `Views/ContentView/*`、`Views/Chat/SelectableMarkdownView.swift` → `Views/Chat/Markdown/*`。这些正是本产品 DSH 远程聊天、免费转写下载入口、美食地图融合所依赖的文件，冲突面比 v1.13 大。
- 以 v1.13 基线为参照，上游改动的 971 个 iOS 共享路径中，本地与上游一致 212 个、本地已定制 81 个、本地尚不存在 678 个（即上游新增或改名后的新路径）。
- 原生依赖：iSH 子模块由 `3f6384c` 前进到 `0fd17a1`（v1.15），设备静态库需重建；`deps/proot` 同步前进（Android 运行时，不在 iOS 范围）；`deps/rclone-mobile` 源码新增 51 个文件，`go.mod` 升级到 Go 1.25.5 并引入 `tailscale/wireguard-go`，rclone 仍固定 `v1.75.0`，`build_ish.sh` / `build_ffmpeg.sh` / `build_lame.sh` / `build_rclone_ios.sh` 均已修改。`src/ios/AOJITRestore` 为上游新增目录，内容是 Android 恢复用 APK，融合时需确认是否纳入。

本次只执行 fetch 并核对差异，没有 merge、cherry-pick 或覆盖 `Vendor/Phone`；产品实际合入基线仍为 `4ef29002e88db1e20e462ec2ff46916e8a7dcb45`，`SOURCE_SNAPSHOT.json` 未改动。工作区分支 `codex/dsh-remote-chat` 上未提交的修改全部保留（拉取前后 `git status` 一致）。后续合入按上面「合入更新」流程执行。
