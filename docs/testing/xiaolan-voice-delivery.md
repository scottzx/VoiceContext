# 小蓝独立语音与 App 全局导航：开发交付记录

更新：2026-10-17，Asia/Shanghai。用户已明确授权开发并部署到当前连接设备。

## 已完成实现

- 入口为「拓展 → 工具 → 语音模式」，开启后停留当前页。首版使用页头原生菜单；同日后续改为跨页单色胶囊，支持点击说话、暂停、继续、停播和关闭，详见下文追加记录。
- 复用 KWS、VAD、本地 SenseVoice、现有 Agent 会话和配置的 TTS。独立输入使用有界内存，不创建 Recording 或长音频文件。
- 未结束录音包含暂停状态，阻止开启语音。语音开启或暂停未关闭时，阻止开始、追录、恢复录音；授权等待后的竞态再次校验。
- `AppNavigationCenter` 统一真实页面状态、路由参数、revision、前台/解锁门禁、每次语音指令的 generation；原生页面挂载后才回报 visible。
- `app_navigation` 提供 tree/get_state/navigate/back；`app_present` 保存并展示文字、单图、柱/折线图和本地 HTML。主助手调用，子智能体只交付结果。
- 通用预览复用图片缩放，图表包含单位、来源和数据表，HTML 使用无持久化 WKWebView、受限本地资源和 CSP，无原生工具桥。
- 关闭、暂停、后台、系统音频中断作废旧语音授权；回前台需明确继续。普通模型输出不自动朗读，只有绑定本次请求的 `answer_user` 可播报。用户换页后的后台完成保持安静。

接口和已注册路由树见[设计文档第 9 节](../design/xiaolan-fullscreen.md)。这次增加的是 App 共用内容预览能力，没有独立小蓝首页、第五个 Tab 或底部语音栏。

## 主机与构建验证

以下检查在 macOS 运行生产逻辑配合隔离边界，不打开 iOS App、麦克风或模拟器：

| 检查 | 结果与覆盖 |
|---|---|
| `test_app_navigation.sh` | 通过；参数、真实挂载回执、返回、超时、取消、版本、前后台、语音 generation、子智能体拒绝及自定义入口元数据 |
| `test_app_artifacts.sh` | 通过；文件/目录符号链接越界、路径穿越、大小、会话 ID、内容类型、有限图表数据与来源/单位 |
| `test_app_presentation.sh` | 通过；四类实际工具参数、持久化、直属子会话与重开归属、过期语音、saved=true 但未显示的真实回执 |
| `test_xiaolan_voice.sh` | 通过；录音冲突、权限竞态、取消开启、会话复用、仅公开答复播报、后台暂停、迟到模型/TTS 与换页后后台静默 |
| `test_xiaolan_recording_gate.sh` | 通过；开始/追录/恢复在写入和开麦前阻止、权限等待后重检、正常录音路径 |
| 会中助手回归 | `test_meeting_tool_policy.sh`、`test_meeting_answer_user.sh`、`test_meeting_answer_recovery.sh`、`test_meeting_apple_native.sh`、`test_meeting_kws_capture.sh`、`test_meeting_session_runner.sh`、`test_meeting_async_reply.sh`、`test_meeting_speech_gate.sh`、`test_meeting_playback_gate.sh` 通过 |
| 静态检查 | 修改 Swift 的语法解析、独立输入层类型检查、`git diff --check` 通过 |
| iOS 签名构建 | Xcode 27.1；`VoiceContextAgentDev` / `Debug-Dev`，`generic/platform=iOS` 构建通过；包含所有新增 App/Recording 源文件 |
| 融合产物审计 | `verify_fusion.py --variant development --check-cache` 通过，保留原 Phone 编译输入及开发环境容器隔离 |

构建命令：

```sh
python3 tools/integration/generate_project.py
xcodebuild -workspace VoiceContextAgent.xcworkspace \
  -scheme VoiceContextAgentDev -configuration Debug-Dev \
  -destination 'generic/platform=iOS' -derivedDataPath build/VoiceContextAgent \
  -clonedSourcePackagesDirPath build/PhonePackages \
  -disableAutomaticPackageResolution -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic build
```

生成工程通过现有 generator 更新，没有手工改写 project.pbxproj。Xcode 构建日志中的既有 Swift 并发/弃用警告不代表本次新增逻辑已完成真机验收。

## 部署证据

- 目标：当前连接的 `scottxz`，iPhone 15 Pro。
- 安装包：`build/VoiceContextAgent/Build/Products/Debug-Dev-iphoneos/VoiceContextAgent.app`。
- 身份：`YiJie.speech-note.dev`，显示名 Yima Dev，版本 1.0 / build 7；生产包 `YiJie.speech-note` 单独保留。
- 签名审计：主应用与 4 个扩展均通过设备覆盖、有效期、开发环境容器和签名权限校验，13 个嵌入框架/动态库签名通过。
- 首版二进制 SHA-256：`5430e1f76f811dbbcb82efce69da0d4a39cbb894703023b362382ce883009f49`。
- 首版安装状态：CoreDevice 回执 `outcome=success`，确认安装 `YiJie.speech-note.dev`。安装后精确查询再次确认 Yima Dev 1.0 / build 7；生产版「听记」`YiJie.speech-note` 1.0 / build 7 仍在。没有卸载应用或清空容器。
- 本地证据目录：`build/xiaolan-voice/`，保存构建日志、签名审计、安装回执和安装前后精确 bundle 查询。设备标识和证书细节仅保存在该忽略目录。

本机 Xcode 的 devicectl 包装脚本因 CoreDevice 组件版本差异进入首次初始化等待；设备读取/安装改用系统已经安装的 CoreDevice 原生 devicectl，可正常查询。没有修改 Xcode 或系统组件。

## 真机验收边界

本轮只按授权安装，不自动启动 iOS App。尚未验证真机唤醒距离、ASR 准确率、扬声器/耳机切换、TTS 效果、页面实际动效和无障碍；以上主机检查及安装回执不能替代这些结果。整个开发过程未创建、启动或选择 iOS Simulator。

手动体验从 Yima Dev 的「拓展 → 工具 → 语音模式」开始；需要现有本地转写模型、麦克风授权和聊天模型配置。可先尝试“小蓝同学，打开今天的日程”“打开未完成待办”“返回上一页”，再请求展示文字、图片、图表或 HTML。

首版语音导航依赖已配置的聊天模型，离线可手动浏览已有内容；不提供连续免唤醒对话。全局工具查询路由与参数，不默认读取页面全文、截图或控制其他 App。文件展示只允许所属会话与已验证直属子会话的 workspace/attachments；HTML 外部登录网站继续使用原自定义功能浏览器。

## 同日追加：常驻胶囊与本地即时应答

用户反馈首版功能可用，明确选择单色小胶囊（麦克风＋短状态），支持靠边隐藏。设计依据与确认见[设计第 12 节](../design/xiaolan-fullscreen.md#12-常驻胶囊与即时应答2026-10-17)及 `DESIGN.md` 同日后续决策。

实现包括一个跟随当前 App 场景的透明原生浮窗：不抢 key window，空白点击透传；跨页、sheet 和全屏内容保留一份控件。支持拖动、左右贴边收起/恢复、归一化位置保存、键盘避让、44 pt 目标、原生菜单和 VoiceOver 移动操作。原有重复页头按钮已移除；拓展入口保留。App 锁/后台/权限提示隐藏，表单暂停及录音互斥不被浮窗绕过。

独立语音在约 0.7 秒 VAD 静音后识别完整话语，去掉唤醒词、空白和标点后分类；不使用总字数大于 5 的硬阈值。只有唤醒词时本地中文语音说「我在」，不调模型，随后最多等待约 8 秒直接指令；有指令先本地说「收到，开始处理」，再单次提交原 Agent。固定应答不经过网络 TTS，最终任务结果仍使用现有输出服务。采集和播报互斥；取消、暂停、关闭和后台不能复活旧反馈。应答或会话加载期间手动换页，也不能在迟到处理时重新绑定导航权。

新增/扩展主机检查已通过：

- `test_xiaolan_floating_geometry.sh`：边界、键盘、浮动键盘、空间不足、旋转、大字体、拖动、收起和位置归一化。
- `test_xiaolan_acknowledgement.sh`：精确短语、本地中文语音、真实开始回调、取消/停止/迟到回调，以及已取消请求不能停止新反馈；实际 AVFoundation 的 Swift 6 严格并发类型检查通过。
- `test_independent_voice_input.sh`：仅唤醒、同音词、单字指令、空转写、静音点击、直接唤醒与迟到 ASR 隔离。
- `test_xiaolan_voice.sh`：仅唤醒不调模型、反馈后直接等待及超时、指令接收反馈、反馈时关闭/暂停、静音、失败音频占用释放、换页后不抢回导航与后台不朗读；此前录音/会话/任务答复回归保持通过。
- `test_meeting_kws_capture.sh`、`test_meeting_wake_commands.sh`：独立语音及时断句、短指令和迟到 KWS 回放，会议默认等待行为保持。
- 修改 UI/输入代码的静态解析和 `git diff --check` 通过。

最终 `VoiceContextAgentDev` / `Debug-Dev` 的 generic iOS 签名构建通过，主应用＋4 个扩展、13 个嵌入框架/动态库签名及当前设备覆盖审计通过，融合产物/容器隔离审计通过。已通过 CoreDevice 安装到同一台 iPhone 15 Pro，安装回执 `outcome=success`，目标仅为 `YiJie.speech-note.dev`，没有卸载或清空容器。

本轮二进制 SHA-256：`32b6f92c17f2ad56722c44f33b2854626cbd834df0a05413f7b5cf10725667e8`。本地证据为 `build/xiaolan-voice/capsule-final-build.log`、`capsule-signing.json`、`capsule-fusion-audit.json`、`capsule-install.json` 及 `capsule-*-after.json`。

没有自动启动或运行 iOS App；胶囊真机触摸、原生菜单、VoiceOver 和实际播报时延仍待体验验收。主机检查不代替这些结果。更新后语音模式默认关闭，需要从「拓展 → 工具 → 语音模式」重新开启；靠边收起只影响控件，不表示麦克风关闭。

同日文案追加：胶囊和菜单状态标题统一为「待机、聆听、识别、处理、播报、暂停、我在、收到」八种两字短语，口头应答保持原文。本次仅修改显示文案；generic iOS 构建、主应用/扩展签名及设备覆盖审计通过，CoreDevice 安装成功（`short-status-build.log` / `short-status-signing.json` / `short-status-install.json`）。二进制 SHA-256：`e7f59ba9d6557f1b81e9bf854af6a12312bca866148cf11f79f0c79f86179310`。未运行 iOS App 或 Simulator。

## 同日追加：小蓝与 Yima 独立智能体

用户确认[职责与交付设计](../design/xiaolan-yima-agent-roles.md)：小蓝负责实时语音、App 导航和简短操作，Yima 负责复杂任务、资料处理与长期规划。小蓝新增 `agent-xiaolan` 身份、自己的 SOUL/记忆目录与会话；默认关闭其长期记忆。Yima 的配置、人格和历史保留。已有非小蓝所属语音记录不改写，为后续语音建立小蓝会话；没有新增专用前端。

提示词和补交付提醒明确要求实际调用 `answer_user`，仅传 `text`；答复、必要追问、失败说明和启动回执都遵守。模型普通文字不构成公开回复。两种语音模式的后台结果回合仅允许该答复工具，伪造业务/导航工具调用也在分派前拒绝。

复杂任务使用 `delegate_to_yima` 进入真实 Yima 主会话。固定收件人、真实会话归属、每请求一次投递、忙/归档/旧请求拒绝均由宿主校验。Yima 委派期间使用有界直接执行工具集合，不再嵌套异步智能体，不控制页面或自动发声。实际执行任务退出后才交付最终/失败/停止通知，等待期限不冒充终局；取消收尾、自动压缩和恢复都保留隔离。原有草稿和附件保留，不注入转交；任务结束后恢复普通 Yima 策略。

受托 Yima 可用 `deliver_to_xiaolan` 回交文字、图片、图表和单文件自包含 HTML。验证来源后独立保存到原小蓝会话，回执 `saved=true`、`displayed=false`；用户后续明确要求时，再按真实页面版本打开。文件仅允许 Yima 当前会话或真实直属子会话，拒绝跨会话与符号链接越界；导出后的内容可在供体删除后正常重开。

本轮主机检查通过：

| 检查 | 覆盖 |
|---|---|
| `test_xiaolan_agent.sh`、`test_xiaolan_identity.sh` | 并发幂等建档、归档/自定义设置保护、独立身份/人格/会话及模型记忆继承；普通身份文本与原实现逐字一致 |
| `test_xiaolan_yima.sh` | 生产私有 A2A 投递到真实 Yima 主会话、可信来源/任务标识、立即回执和后续通知、去重与忙/归档保护 |
| `test_xiaolan_delivery.sh` | 四类真实内容、源/目标路径和供体边界、符号链接、大小与类型校验、复制内容独立重开、没有页面操作 |
| `test_meeting_session_runner.sh` | 队列/压缩、忙与重试竞态、真实任务链、超过等待期限仍只交付真实终局、取消收尾隔离、草稿/附件保护、普通 Yima 恢复 |
| `test_meeting_tool_policy.sh` | 提示词与真实工具集合、后台仅答复、禁止嵌套异步/抢页/打开事项/脱离执行、直接执行和导出可用、普通 Yima 保持 |
| 答复与生命周期回归 | `test_meeting_answer_user.sh`、`test_meeting_answer_recovery.sh`、`test_meeting_execute.sh`、`test_meeting_async_reply.sh`、`test_meeting_speech_gate.sh`、`test_xiaolan_voice.sh`、`test_agent_relay_context.sh` 通过 |
| 展示、音频与互斥回归 | App 路由/产物/展示、独立输入、录音门禁、本地即时应答及胶囊几何检查通过；未调用真实音频或 iOS UI |

最终 `VoiceContextAgentDev` / `Debug-Dev` 的 `generic/platform=iOS` 签名构建通过，主应用＋4 个扩展、13 个嵌入框架/动态库签名及设备覆盖审计通过；融合审计的 `identityAndContainers`、`deviceProduct` 均为 `passed`。已通过 CoreDevice 安装到当前 iPhone 15 Pro，回执 `info.outcome=success`，安装目标 `YiJie.speech-note.dev`。

本轮二进制 SHA-256：`665f7388a92f917414ca8298bb7d5917b1f7bd6f6d1c37efc2adfac8ce8870b0`。证据：`build/xiaolan-voice/agent-roles-delivery-build.log`、`agent-roles-signing.json`、`agent-roles-fusion-audit.json`、`agent-roles-install.json`、`agent-roles-*-after.json`。

没有自动启动 iOS App 或使用 Simulator。真实模型选工具、端到端语音、长任务和产物打开仍需设备交互验收；主机逻辑检查、签名构建及成功安装分别记录，不混同为真机通过。PM 服务 `127.0.0.1:38080` 本轮不可用，设计和验收已保存，未伪造功能树/任务状态。

安装后精确查询通过：Yima Dev（`YiJie.speech-note.dev`）1.0 / build 7；生产版听记（`YiJie.speech-note`）1.0 / build 7 仍在。两次查询 `info.outcome=success`，未启动应用。

## 追加：共用运行时策略与 subagent notice（当前实现）

本节记录当前实现，以上各节保留为历史交付记录。用户确认小蓝与 Yima 的差异统一到配置和策略，复杂任务使用既有 `spawn_subagent`，由子任务 notice 二次唤醒原父会话。

通用引擎读取 `AgentRuntimePolicy`；应用启动注册 `VoiceAgentConfiguration`，提示词由 `VoiceAgentPrompt` 提供。身份、SOUL、历史、模型与记忆偏好仍归属各自 Agent。已移除 `delegate_to_yima`、`deliver_to_xiaolan` 工具及其专线执行状态；没有新增小蓝页面。普通聊天、executor 与语音入口共用模型调用、工具循环、持久化、压缩及通知机制。

主会话收到真实任务启动回执后通过 `answer_user` 回复并结束当前轮。子任务持久化真实终态，notice 经宿主预约与去重后唤醒原会话；该回合只允许 `answer_user`，不会重新派发业务或跳转页面。后台、关闭或无法交付时保留待处理通知。子任务策略关闭自动朗读，缓存重载后仍保持；记忆提示服从实际回合工具集合。

主机验证使用实际生产策略、调度器、执行器、notice 管理器及答复工具，存储和模型边界使用隔离 fixture，不启动 iOS App 或真实音频：

| 检查 | 覆盖与结果 |
|---|---|
| `test_agent_runtime_policy.sh` | 通过；任意第三身份/source 可使用同一引擎，配置选择提示词、工具、交付和生命周期；扫描共用引擎无产品角色判断或旧专线 |
| `test_subagent_notice_flow.sh` | 通过；真实 spawn 保留身份、父会话和模型继承，立即返回启动状态；真实终态经 notice 回原父会话并实际调用 `answer_user`；暂缓交付、重复通知及停止语义 |
| 策略、提示词与交付 | `test_meeting_tool_policy.sh`、`test_meeting_answer_user.sh`、`test_meeting_answer_recovery.sh` 通过；覆盖两种语音入口及任意第三入口、真实工具白名单、一次补交付、五个模型请求及 fallback 提示词 |
| 会话与通知生命周期 | `test_meeting_session_runner.sh`、`test_meeting_async_reply.sh`、`test_meeting_speech_gate.sh`、`test_agent_relay_context.sh` 通过；真实身份继承、草稿附件保护、忙时及异步边界重检、缓存重载、子任务静默和普通聊天保持 |
| 语音与原生能力 | `test_xiaolan_agent.sh`、`test_xiaolan_identity.sh`、`test_xiaolan_voice.sh`、`test_meeting_execute.sh`、`test_meeting_apple_native.sh`、`test_app_navigation.sh`、`test_app_presentation.sh` 通过；配置与自定义人格保护、普通身份文本一致、绑定能力和页面权限校验 |

最终复查补修子任务终态通知竞争：同一次执行的状态对账、正常收尾及停止使用稳定事件标识，并在异步存储前同步认领发布权，避免同 ID 覆盖已交付记录；追加指令会替换执行代次，旧收尾逐个异步边界重检，不能覆盖或取消新执行。`test_subagent_notice_flow.sh` 的确定性交错检查通过，覆盖收尾/状态查询、两个恢复对账、追加指令替换、旧超时回调及父答复尚未结束时子任务仍显示真实终态。

最终 `VoiceContextAgentDev` / `Debug-Dev` 的 `generic/platform=iOS` 签名构建通过，包含上述通知修复。主应用＋4 个扩展、13 个嵌入框架/动态库签名及当前设备覆盖审计通过；融合审计的 `identityAndContainers`、`deviceProduct` 均为 `passed`，静态解析与 `git diff --check` 通过。

已通过 CoreDevice 安装到当前连接的 iPhone 15 Pro，安装回执 `info.outcome=success`，目标为 `YiJie.speech-note.dev`。安装后精确查询确认 Yima Dev 1.0 / build 7；生产版听记（`YiJie.speech-note`）1.0 / build 7 仍在，两次查询均成功。没有卸载应用、清空容器或自动启动 App。

本轮最终二进制 SHA-256：`e6d111f3bdef8a38eda1d319e4f91eb91554439325a54fc4e1ef924ab496e357`。证据保存在 `build/xiaolan-voice/runtime-policy-notice-final-build.log`、`runtime-policy-signing.json`、`runtime-policy-fusion-audit.json`、`runtime-policy-install.json`、`runtime-policy-dev-after.json` 与 `runtime-policy-production-after.json`。

本轮未使用 Simulator；真实模型选工具、端到端语音、长任务二次唤醒与产物打开仍需设备交互验收。主机生产逻辑检查、签名构建和成功安装分别记录。PM 服务 `127.0.0.1:38080` 仍不可用，设计与验收已保存在仓库，未伪造项目项或功能树状态。
