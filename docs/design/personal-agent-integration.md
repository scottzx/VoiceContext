# VoiceContext 个人智能体融合设计

## 文档信息与决策状态

- 来源需求：PM #85，`1d69da489db80b32c0e35ab65ed68f0b`。
- 日期：2026-09-29；产品决策人：Human。
- 状态：已按确认方案实现首轮融合，完成真机签名编译、同身份覆盖安装、启动闪退修复和启动验证；完整功能、升级及设计验收仍待完成。
- 本轮产出：`VoiceContextAgent.xcworkspace`、完整 iOS 源码快照、录音 framework、四 Tab、系统提醒事项、统一音频协调、文稿与产物接线。工程事实、能力清单、构建及待验收项见 [融合工程说明](../../Integration/README.md)。已在用户授权的 scottxz 真机启动，持续运行超过两分钟且无新增崩溃报告。
- 适用关系：本设计是下一阶段产品增补。仅对融合版本取代 v1 的单一录音首页、不内置 LLM、不提供分享扩展等范围限制；保留历史 v1 文档和验收事实。

## 背景与目标

沿用已发布的 voice_type / VoiceContext 产品，将录音上下文系统与 1agents_phone 的完整 iOS Agent 平台融合为个人智能体。用户可以记录会议和个人想法，在聊天中使用文稿、Skills、shell 和浏览器完成任务，并在系统提醒事项中跟进。

产品身份、用户数据和录音可靠性以 voice_type 为主；整体代码框架与平台装配以 1agents_phone 为底座。完整迁移是能力目标，不要求将 Android、macOS 源码编入 iOS，也不以重写独立 Runtime SDK 为前提。

## 已确认的产品决定

| 决定 | 约束 |
|---|---|
| 延续原产品 | 主 Bundle ID 保持 `YiJie.speech-note`；保持已有录音、文稿和附件路径，承接购买权益与 Keychain 访问 |
| 仓库与工程 | 在 voice_type 仓库内建立融合 target，以 phone 完整工程装配为基础 |
| 完整 Agent 能力 | shell/iSH、Skills、浏览器必须同时纳入，其他已有 iOS Agent 能力按清单迁移，不以最小循环内核代替 |
| 四 Tab | 固定顺序：聊天、会议、待办事项、拓展 |
| 设置归属 | 现有我的、设置进入拓展 Tab |
| 录音优先 | 统一协调 AVAudioSession；录音连续性优先于聊天语音输入、播报和后台音频 |
| 待办权威源 | 使用 iPhone 系统提醒事项，App 内展示和管理；Agent 读写同一数据源 |

## 产品流程与信息架构

| Tab | 主职责 | 复用来源及边界 |
|---|---|---|
| 聊天 | 与个人智能体对话、提交任务、查看工具执行及结果 | 复用 phone 的聊天、会话、模型和 Agent 能力；会话列表与直接进入对话的首屏形式待细化 |
| 会议 | 录音、转写、回听、文稿及相关资料 | 复用 voice_type 的现有业务。暂按承接所有已有 Recording 设计，个人记录的筛选和呈现待细化，不因 Tab 名称改写历史记录类型 |
| 待办事项 | 查看、新增、修改、完成系统提醒事项 | 系统提醒事项为权威源；显示哪些列表及默认写入列表待确定 |
| 拓展 | 发现和配置能力、访问我的与设置 | 建议集中 Skills、模型、工具/浏览器配置、记忆管理及原有设置；分组与排列待设计 |

导航边界：四 Tab 共用同一个 App 级录音服务、Agent 服务及数据服务；切换页面不重建它们。聊天使用“语音输入”，会议使用“录音”，状态与文案必须可区分。录音中的全局状态与停止入口跨 Tab 可达；Widget 和深链直接进入相应录音流程，不因聊天位于第一项而绕行。

核心路径：会议录音 → 文稿与资料就绪 → 在聊天中引用该记录并发起任务 → Agent 按需使用资料、shell、Skills、浏览器 → 结果保存并关联来源 → 提醒事项进入第三 Tab 跟进。用户也可从聊天直接执行与会议无关的通用任务。

“待办事项”代表用户需要跟进的事项；已有转写任务中心仍表示技术处理进度，不自动将 ASR job 或 Agent 每个工具调用写入系统提醒事项。

## UI/UX 风格确认

- 状态：复用已确认的现有风格；四 Tab 信息架构由 Human 于 2026-09-29 明确确认。页面细节尚未设计，不视为已验收原型。
- 依据：`DESIGN.md`，2026-08-03 原生录音工具风格及 2026-09-29 导航增补；复用 Aesthetic Direction、Typography、Color、Spacing、Layout、Motion and Haptics、Accessibility、Prohibited Patterns。
- 记忆点：可靠、安静、能执行任务的个人工具；录音时状态清晰且随时可控。
- 关键词：原生、克制、内容优先、可靠；反向：装饰性渐变、卡片堆叠、彩色光效、桌面布局照搬。
- 平台感优先；系统字体、黑白灰、语义色、舒适紧凑的信息密度不变。红色继续用于录音及破坏性动作。
- 参考 Apple Voice Memos 的录音层级与克制，不直接沿用 phone 中与本项目规范冲突的视觉。
- 深色模式、Dynamic Type、44 pt 点击目标、VoiceOver、Reduce Motion 继续作为验收要求。

后续原型必须覆盖四 Tab、跨页录音状态、聊天工具执行、会议引用、提醒事项权限和拓展设置。先完成关键流程与状态原型，再制作高保真与实现标注；任何新视觉风格偏离需另行确认。

## 技术方案与实现依据

### 完整工程接入

以 phone 的构建依赖、启动链路和平台初始化为模板建立融合 target，接入 voice_type 的业务源码与资源。只保留一个 App 启动入口，处理重名类型、资源目录、桥接头、Swift 编译设置和生命周期钩子；目录隔离不等于 Swift 模块隔离。

源码使用 `Vendor/Phone` 冻结快照与 SHA256 清单维护；融合 target 为 `VoiceContextAgent`，原录音代码编入 `VoiceRecording.framework`，保留独立 Swift 模块边界。共享包拆分和大规模重构后置。

完整能力清单必须覆盖：Providers/认证、聊天与会话持久化、Memory、Skills、MCP、shell/iSH/Alpine、浏览器、文件工作区、Native Offloads、AgentKit、现有后台/通知能力、同步、分享/Widget/FileProvider 等 iOS 集成。逐项记录源路径、初始化、依赖、权限、资源、当前完成程度和验证方式；已有占位功能不能记作已完成能力。

已有 FlavorRootView/FlavorConfig 可复用装配思路，新增融合导航。RolePackInstaller 当前声明的 skills 导入仍为延后实现，不能假设仅放入 Pack 就能安装；保留现有 SkillStore 运行链路，并补齐 VoiceContext Skill 的实际安装接线。

两个 target 使用同一正式 Bundle ID 时是同一个安装身份，不能并排保留为两个 App；只有融合 target 进入新版本发布链路。测试覆盖安装前需备份并取得真机运行授权。

### 产品身份、容器与升级

- 主 Bundle ID：`YiJie.speech-note`。
- 现有录音 Widget 身份：`YiJie.speech-note.RecordWidget`。
- 现有文档容器：`iCloud.YiJie.speech-note`。
- 现有 Keychain 组：`$(AppIdentifierPrefix)com.yijie.shared_entitlements`。
- 保留现有 StoreKit 产品标识和购买恢复行为，不在融合中重置权益。
- 新 Agent 容器与扩展身份另列签名映射表，不照搬 `group.com.1agents.phone` / `iCloud.com.1agents.phone`，避免与原 phone App 意外共享数据。
- 原录音和文稿不迁入 Agent App Group。通过受控文件桥接或服务访问；分享、FileProvider 和 Widget 的共享范围逐项定义。
- PublicDocumentContainer 已显式优先原文稿容器；融合构建中原容器不可用时留在本地，不退到 Agent 容器。
- 继续以现有 iOS 18 兼容为检查基线；phone 各 target 的 deployment target 不一致，尚未完成 API/依赖兼容审计，不承诺仅修改版本号即可融合。

### 统一音频协调

phone 已有 `Providers/Voice/AudioSessionCoordinator.swift`，采用 capture/mediaAttachment/replyTTS/backgroundKeepAlive intent；voice_type 的录音器与播放器仍有直接会话调用。优先扩展现有协调机制，最终确保全应用只有一处负责会话 category/active 切换。

已实现的音频策略（仍待真机压力验收）：

1. 会议/个人持续录音独占采集所有权；聊天语音输入不能再次启动麦克风或改变录音配置。
2. 录音期间推迟或抑制 Agent 播报、附件音频、后台静音音轨，聊天文本、非音频工具继续可用；Agent 并发的进一步限制待真机压力测试决定，当前未新增自适应限流。
3. 以所有者标识管理申请与释放，区分持续录音和聊天采集；不能让一个模块结束 capture 时释放另一个模块仍持有的录音会话。
4. 会话激活成功后才启动采集；停止录音先关闭和落盘分片，再交还音频所有权。既有录音参数和分片边界保持不变。
5. 电话、系统中断、路由变化继续沿既有 journal/gap/恢复机制处理；“录音优先”不承诺消除系统强制中断。
6. 不因录音存在就假设 Agent 可无限后台执行；按真实系统生命周期保存运行状态并提供恢复入口。

### 文稿与 Agent 文件桥接

录音仓库与公开文稿仍是原资料权威源，Agent Store 保存会话和运行数据。首轮以草稿中的 recordingID/revision 和 `Generated/<recordingID>/` 目录关联产物，详情可预览；尚未建立额外 session/运行/产物关联数据库。

shell/Skills 使用稳定的来宾工作区路径访问选定资料；录音中的文稿只暴露一致快照，不能读取原子写入中的半文件。原文读写通过已有业务服务保证 revision、索引与镜像一致；生成文件单独保存，避免任意 shell 写入绕过文稿状态机。

Agent 查阅文稿不等于自动读取或上传原音频。原音频、凭据、数据库及敏感目录不作为默认文稿挂载范围。用户明确提供的其他文件仍可通过通用 Agent 文件工作区使用。

### 系统提醒事项

通过 EventKit/现有 Reminders 原生工具接入系统提醒事项，页面与 Agent 共享同一访问和写入规则。复用 phone 的 RemindersOffload 语义，核对它的容器、权限与写入回报，避免 UI 与工具各自持有冲突的待办状态。

App 仅保存来源关联及必要的可重建缓存，不维护另一份独立的任务完成状态。系统提醒事项被外部编辑、完成或删除后，页面刷新相应状态；来源记录删除时只处理关联，不默认删除系统待办。

Agent 提取的建议事项与已经写入的提醒事项必须区分。只有写入成功才报告“已创建”；对写入结果不确定的重试需防重复。列表无写权限、授权撤销、目标删除及标识失效均需诚实呈现。

## 状态、隐私与兼容边界

- 无网络或无模型配置：录音、本地转写、回听和已有本地资料仍可用；聊天说明实际限制，不强制先配置 Agent 才能录音。
- 提醒事项未授权/被撤销：待办页显示权限状态，不冒充空列表，也不影响会议功能。
- 工具失败/取消/等待恢复：保留已产生的文件和可追溯执行状态，不把取消当成功或盲目重做外部写入。
- 模型联网请求需说明将发送哪些文字或附件；录音/ASR 继续本地执行，不沿用覆盖整个 App 的“100% 离线”宣传。
- 原有保留、删除、iCloud 文档和声纹边界延续；会话引用不暗中延长原音频保留期。
- 仓库标注许可证分别为 MIT 与 GPLv3，迁移时维护来源及许可清单；发布条款处理另列交付，不在本设计中推断已解决。

## 验收标准

- [ ] 从旧版同身份升级后，历史录音、文稿、附件、Widget 深链和购买恢复可用，既有路径不被改写。
- [ ] 四 Tab 顺序及我的/设置归属符合已确认决定；切换 Tab 不终止录音或重建 Agent 运行。
- [ ] 完整 iOS 能力清单逐项验证，shell、Skill 加载执行、浏览器操作均有真实链路，未完成功能单独标注。
- [ ] 长录音中切换四 Tab、触发聊天语音/播报/后台音频不会由 App 主动打断采集；系统中断可恢复且记录 gap。
- [ ] 会议引用能串起 Agent 文件读取、shell/Skills/浏览器及产物保存；结果能追溯 recordingID 和 revision，原文不被覆盖。
- [ ] App、Agent 与系统提醒事项对同一待办的新增、修改、完成、外部删除结果一致，权限与失败状态真实。
- [ ] 深色模式、动态字体、VoiceOver、Reduce Motion、跨 Tab 录音状态经过设计与无障碍验收。
- [x] 禁止模拟器；真机运行已获用户明确授权，完成启动验证，其余功能验收仍待完成。

## 后续交付与待细化

工程清单、融合构建、容器映射、音频协调、资料桥接和提醒事项已实现首轮，签名配置、同身份覆盖安装和真机启动验证已完成。后续仍需：完整升级验收、完整能力运行验证、关键流程真机验证、设计和无障碍走查及发布材料。源码与编译不能代替这些验收。

建议依赖顺序：流程与构建/能力清单 → 融合 target 与身份映射 → 音频协调和数据桥接 → 四 Tab 与提醒事项整合 → 完整能力及升级验收。设计与技术清单可独立推进；本轮不创建会自动派发的实施任务。

首轮采用 phone 会话首屏、原 Recording 会议列表；提醒事项展示全部系统列表、默认系统写入列表并可选择可写列表；拓展采用原生分组列表。容器命名及源码更新方式见工程说明。部署基线保持 iOS 18，但尚未完成最低版本真机兼容验收。发布日期、目标版本和产能未提供，不编造排期。

## 静态检查依据

本轮检查的 voice_type HEAD：`d08124c6bbe45517bdfbc73a15186c50f8a3fcff`；1agents_phone HEAD：`02956e269857e32335b16b4d5e6af999ff14c6e1`。phone 工作树另有未提交改动；导入仅取已提交 SHA，不带入这些源码改动。iSH 与子模块来源及本机缓存指纹单独记录，详见融合工程说明。

主要代码锚点：本仓库 `speech_note/speech_note/App/speech_noteApp.swift`、`speech_note/speech_note/Features/Recording/RecordingSessionCoordinator.swift`、`speech_note/speech_note/Features/Recording/AACSegmentRecorder.swift`、`speech_note/speech_note/Features/Documents/PublicDocumentContainer.swift`；来源仓库 `src/ios/MinisApp.swift`、`src/ios/FlavorKit/FlavorRootView.swift`、`src/ios/Providers/Voice/AudioSessionCoordinator.swift`、`src/ios/NativeOffloads/RemindersOffload.m`、`src/ios/Agent/ISH/MinisFsRouter.swift`。

## PM 追踪

- 来源需求：#85。
- 功能蓝图：模块「个人智能体融合」（`3114d74731317f37d9e2eb6990695b8d`）下包含产品身份与完整 Agent 装配、四 Tab 导航与拓展入口、录音优先的统一音频、会议上下文与 Agent 工作区、系统提醒事项待办、完整能力与升级验收；六个功能点均以 #85 为 source。
- 工程工作已在当前任务内实施；#85 保持 open，待真机及升级验收后关闭。未新建会自动派发的 PM task，也未编造版本日期。
