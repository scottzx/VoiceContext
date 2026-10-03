# 录音 → ASR → AI 整理 → 系统待办：交付任务清单

- 文档日期：2026-10-02；状态：用户已授权登记的新草案。
- 需求依据：[PRD-recording-ai-actions.md](../PRD-recording-ai-actions.md)；视觉与交互依据：[DESIGN.md](../../DESIGN.md)。
- 这次授权用于制作 PRD 和登记任务，不代表新增流程已经评审通过或实现已经开始。
- 共 27 项：6 项交互设计、14 项代码开发、7 项测试验收；不指定负责人、排期日期或目标版本。文档日期不是任务排期。
- 新建工作项登记为 Backlog。T06 复用 TINGJI-22，T07 复用 TINGJI-21，保留各自原状态、父级和已有证据，增量补充验收内容。
- 按主要功能归口，跨功能关联在任务中列明；F03 复用 TINGJI-11，其余功能按同一 PRD 的稳定编号登记。不启用项目类型、模块或迭代。

## 范围与实施规则

沿用已完成的待办 CRUD、月/周日历、来源筛选、完成/恢复、删除确认及基础权限状态；新增工作围绕可信输入、可追溯产物、行动项确认和系统事项关联。系统提醒事项仍是完成状态的权威源，不创建另一套任务完成状态数据库。

交互任务必须交付可点击原型、完整状态文案和无障碍说明。视觉方向复用已经批准的 DESIGN.md；新增操作流程仍需评审，依赖该流程的实现只能在对应设计与数据契约明确后开始。导图首版采用折叠树及文字等价阅读，不要求自由画布或缩放。

C00 冻结输入、产物、引用、行动项、关联与 Reminder 契约，所有后续实现依赖 C00。兼容范围包含 Transcript@1、旧无 manifest 的生成产物和已有用户 Skill，不能按全新安装假设迁移。重转写必须先核验音频可用性，音频过期不能清旧稿；正常静音与有声识别为空分别处理。

真机验收必须取得用户对该次运行的明确授权，禁止创建、启动或使用 iOS Simulator。纯契约回归使用可控输入/服务替身，不读取本机私人提醒数据或申请本机权限。编译、安装和运行验收分别记证据。T06/T07 的 P0 门禁不依赖 P1 导图完成，后续导图用例单独注明 P1。

## 稳定功能编号

| 功能 | 范围 |
|---|---|
| F01 | 校对保护与完整性 |
| F02 | 固定输入版本 / 产物生命周期 / 统一 Skill 路径 |
| F03 | 会议整理入口 / 纪要语义 / 长文覆盖 |
| F04 | 结构化思维导图 |
| F05 | 行动项确认 |
| F06 | 会议 Reminder 双向关联 / 幂等 / 外部变更 |
| F07 | Reminder 工具与 UI 契约 |
| F08 | 保留删除隐私 |

## 阶段与依赖

| 阶段 | 交付与门禁 |
|---|---|
| S0 | D01、D02、D04、D05、D06 完成新流程评审；C00 冻结 schema、兼容迁移、状态和校验规则。 |
| S1 | 先保护旧稿、区分完整性、固定输入版本、统一整理路径，交付纪要、Reminder 契约和删除残留清理；执行对应非运行回归。 |
| S2 | 行动确认、关联幂等与外部状态核对就绪后，执行非运行回归及获授权的 P0 真机闭环。C13 单独交付新行动关联删除集成，T04/T07 验证该路径。 |
| S3 | 独立完成 P1 导图设计、结构和折叠树阅读；追加 P1 结构、真机阅读与无障碍用例，不追溯阻塞已完成的 P0 门禁。 |

C12/T02 在 S1 独立完成受管资料清理、防复活与版本兼容验收，不等待 C10/C13；C13 在 S2 依赖 C10 与 C12，单独完成来源删除与新行动关联集成，交由 T04/T07 检查。T03 的必需依赖只覆盖 P0 纪要，导图用例在 C07 就绪后追加。T06/T07 的硬依赖均不包含 P1 导图实现。

## 交互设计

### D01 · 文稿校对保护与完整性状态交互

- 优先级：P0；阶段：S0；主功能：F01；对应功能：F01、F02。
- 依赖：无任务依赖；依据 PRD 草案与 DESIGN.md。
- Plane：新建工作项登记为 Backlog。
- 产出：交互规格与可点击原型，包含重转写前音频预检、版本选择、缺口状态、状态文案和无障碍说明。
- PRD 来源章节：F01、F02。
- 实施锚点：[`DESIGN.md`](../../DESIGN.md)、[`speech_note/speech_note/Features/Recording/RecordingDetailView.swift`](../../speech_note/speech_note/Features/Recording/RecordingDetailView.swift)、[`speech_note/speech_note/Features/Documents/TranscriptDocumentEdits.swift`](../../speech_note/speech_note/Features/Documents/TranscriptDocumentEdits.swift)。

验收标准：

1. 区分处理中、部分可用、正常静音、有声识别为空、识别失败、已校对；状态不只依赖颜色。
2. 重新识别前说明输入音频可用性与人工修改影响；音频过期/缺失时说明原因并保留旧稿。
3. 明确选择覆盖或保留校对内容，提供取消路径；VoiceOver 顺序、状态读法和至少 44 pt 操作区完整。

### D02 · 会议整理入口与产物生命周期交互

- 优先级：P0；阶段：S0；主功能：F03；对应功能：F03、F02。
- 依赖：D01。
- Plane：新建工作项登记为 Backlog。
- 产出：会议整理入口、处理状态、纪要结果、输入版本/历史结果交互规格与可点击原型；包含文案和无障碍说明。
- PRD 来源章节：F03、F02。
- 实施锚点：[`DESIGN.md`](../../DESIGN.md)、[`Integration/App/VoiceContextRootView.swift`](../../Integration/App/VoiceContextRootView.swift)、[`Integration/App/RecordingAgentResults.swift`](../../Integration/App/RecordingAgentResults.swift)、[`speech_note/speech_note/Features/Recording/RecordingDetailView.swift`](../../speech_note/speech_note/Features/Recording/RecordingDetailView.swift)。

验收标准：

1. 用户可辨认本次使用哪版文稿、是否完整、产物是否失败/取消/过期以及恢复动作。
2. 缺模型、输入未就绪和部分文稿明确呈现，不将处理启动或文件出现视为完成。
3. 沿用原有音频先于文稿的层级；兼容旧无 manifest 产物的可读入口，不假定它有新元数据。

### D03 · 思维导图折叠树与文字阅读交互

- 优先级：P1；阶段：S3；主功能：F04；对应功能：F04。
- 依赖：C00。
- Plane：新建工作项登记为 Backlog。
- 产出：以折叠树为首版的导图交互规格、文字等价视图与可点击原型；包含来源导航、P1 导出形式与交互、文案和无障碍说明。
- PRD 来源章节：F04。
- 实施锚点：[`DESIGN.md`](../../DESIGN.md)、[`Integration/App/RecordingAgentResults.swift`](../../Integration/App/RecordingAgentResults.swift)。

验收标准：

1. 首版提供节点展开/收起和文字等价阅读，不要求自由画布或缩放。
2. 小屏、Dynamic Type 和 VoiceOver 能读取完整节点层级；节点来源可定位。
3. 空/无效结构可解释，图形不可用时文字内容仍可阅读；新流程原型评审通过后开发。
4. P1 明确 Markdown 与一种约定图形/图描述格式的导出交互；导出保留节点层级和来源，具体格式经评审确定。

### D04 · 行动项确认与会议待办关联交互

- 优先级：P0；阶段：S0；主功能：F05；对应功能：F05、F06。
- 依赖：D02。
- Plane：新建工作项登记为 Backlog。
- 产出：行动项逐项编辑/勾选、创建确认、部分失败、来源回跳和关联失效交互规格与可点击原型；包含文案和无障碍说明。
- PRD 来源章节：F05、F06。
- 实施锚点：[`DESIGN.md`](../../DESIGN.md)、[`Integration/App/RecordingAgentResults.swift`](../../Integration/App/RecordingAgentResults.swift)、[`Integration/App/SystemRemindersView.swift`](../../Integration/App/SystemRemindersView.swift)。

验收标准：

1. 建议与已创建系统事项清楚区分；未明确日期/负责人显示待确认，不默认推断。
2. 批量部分成功可逐项处理，不要求再次创建成功项；创建无日期事项后可直接找到。
3. 会议关联区与待办来源入口可操作；已完成、已删除、暂不可读、结果待核对等状态不混淆。

### D05 · 提醒写入目标与时间契约交互

- 优先级：P0；阶段：S0；主功能：F07；对应功能：F07。
- 依赖：D04。
- Plane：新建工作项登记为 Backlog。
- 产出：提醒写入确认与回执局部原型，包含账户/列表、到期/通知、权限、只读和非法参数文案与无障碍说明。
- PRD 来源章节：F07。
- 实施锚点：[`DESIGN.md`](../../DESIGN.md)、[`Integration/App/SystemRemindersView.swift`](../../Integration/App/SystemRemindersView.swift)、[`Integration/App/ReminderDateEditing.swift`](../../Integration/App/ReminderDateEditing.swift)、[`Vendor/Phone/src/ios/NativeOffloads/RemindersOffload.m`](../../Vendor/Phone/src/ios/NativeOffloads/RemindersOffload.m)。

验收标准：

1. 确认页展示明确目标账户和列表；到期日期/时间与定时通知分开。
2. 失效或不可写目标据实失败，不悄悄改写到默认列表。
3. 回执呈现实际保存设置；权限拒绝、只读、无效日期、结果待核对各有可理解的恢复动作。

### D06 · 保留删除与模型发送范围交互

- 优先级：P0；阶段：S0；主功能：F08；对应功能：F08。
- 依赖：无任务依赖；依据 PRD 草案与 DESIGN.md。
- Plane：新建工作项登记为 Backlog。
- 产出：源录音/文稿、快照、生成产物、关联的保留/删除选项与模型发送说明交互规格、局部原型、文案和无障碍说明。
- PRD 来源章节：F08。
- 实施锚点：[`DESIGN.md`](../../DESIGN.md)、[`Integration/App/MeetingWorkspaceBridge.swift`](../../Integration/App/MeetingWorkspaceBridge.swift)、[`Integration/App/RecordingAgentResults.swift`](../../Integration/App/RecordingAgentResults.swift)、[`speech_note/speech_note/Features/Recording/RecordingDetailView.swift`](../../speech_note/speech_note/Features/Recording/RecordingDetailView.swift)。

验收标准：

1. 说明每个删除动作具体影响哪些数据，支持取消；音频到期与删除整条记录分开表达。
2. 删除录音不默认删除系统提醒事项；关联如何处理有清楚说明。
3. 调用模型前能理解将发送哪些文字/附件；不默认扩展原音频保留或上传范围。

## 代码开发

### C00 · 冻结会议输入、产物、引用、行动项与 Reminder 数据契约

- 优先级：P0；阶段：S0；主功能：F02；对应功能：F02、F01、F03、F04、F05、F06、F07、F08。
- 依赖：D01、D02、D04、D05、D06。
- Plane：新建工作项登记为 Backlog。
- 产出：可供实现与测试复用的 schema、状态/校验规则、接口契约及兼容迁移说明，冻结输入 revision、完整性、产物 manifest、来源引用、行动项、关联和 Reminder 回执。
- PRD 来源章节：F02、F01、F03、F04、F05、F06、F07、F08。
- 实施锚点：[`docs/PRD-recording-ai-actions.md`](../../docs/PRD-recording-ai-actions.md)、[`speech_note/speech_note/Features/Documents/TranscriptDocumentV1.swift`](../../speech_note/speech_note/Features/Documents/TranscriptDocumentV1.swift)、[`Integration/App/MeetingWorkspaceBridge.swift`](../../Integration/App/MeetingWorkspaceBridge.swift)、[`Integration/App/RecordingAgentResults.swift`](../../Integration/App/RecordingAgentResults.swift)、[`Integration/App/SystemRemindersView.swift`](../../Integration/App/SystemRemindersView.swift)、[`Vendor/Phone/src/ios/NativeOffloads/CalendarOffload.m`](../../Vendor/Phone/src/ios/NativeOffloads/CalendarOffload.m)。

验收标准：

1. 定义稳定标识、必填/可空字段、来源范围、状态转换及非法输入的失败语义；记录完成状态仍以 EventKit 为准。
2. 明确 Transcript@1、旧无 manifest 产物和已有用户 Skill 的向后兼容/升级策略，不假定新安装才能使用。
3. 定义日期/时间/时区与通知分离、列表 ID、实际写入回执、幂等恢复、来源删除规则；所有后续实现采用同一契约。

### C01 · 人工校对保护与重转写音频预检

- 优先级：P0；阶段：S1；主功能：F01；对应功能：F01。
- 依赖：D01、C00。
- Plane：新建工作项登记为 Backlog。
- 产出：人工校对版本保护、重新识别前音频可用性预检、覆盖/保留选择及并发回调处理。
- PRD 来源章节：F01。
- 实施锚点：[`speech_note/speech_note/Features/Recording/RecordingCoreModel.swift`](../../speech_note/speech_note/Features/Recording/RecordingCoreModel.swift)、[`speech_note/speech_note/Features/Recording/RecordingSessionCoordinator.swift`](../../speech_note/speech_note/Features/Recording/RecordingSessionCoordinator.swift)、[`speech_note/speech_note/Features/Documents/TranscriptDocumentV1.swift`](../../speech_note/speech_note/Features/Documents/TranscriptDocumentV1.swift)、[`speech_note/speech_note/Features/Documents/TranscriptDocumentEdits.swift`](../../speech_note/speech_note/Features/Documents/TranscriptDocumentEdits.swift)。

验收标准：

1. 重转写在清理旧文字或进入不可逆状态前确认所需音频可读；音频过期/缺失/不可解码不清旧稿。
2. 迟到识别回调或重跑不静默覆盖人工修改；显式替换保留可恢复版本。
3. 人工编辑与识别并发得到契约约定的冲突结果，取消不丢已保存内容。

### C02 · 文稿完整性与空识别状态快照

- 优先级：P0；阶段：S1；主功能：F01；对应功能：F01。
- 依赖：D01、C00。
- Plane：新建工作项登记为 Backlog。
- 产出：可供页面与 AI 输入读取的片段覆盖、失败/缺口、正常静音和有声空识别完整性快照。
- PRD 来源章节：F01。
- 实施锚点：[`speech_note/speech_note/Features/Transcription/ForegroundTranscriptionScheduler.swift`](../../speech_note/speech_note/Features/Transcription/ForegroundTranscriptionScheduler.swift)、[`speech_note/speech_note/Features/Documents/TranscriptDocumentV1.swift`](../../speech_note/speech_note/Features/Documents/TranscriptDocumentV1.swift)、[`speech_note/speech_note/Features/Recording/RecordingCoreModel.swift`](../../speech_note/speech_note/Features/Recording/RecordingCoreModel.swift)。

验收标准：

1. 完成只在真实处理完成时成立，部分文稿及失败/缺失范围可机器读取。
2. 正常静音与有声却识别为空分开记录，不能把后者当正常完成或用空稿覆盖旧稿。
3. 整理输入携带可核对的完整性信息，重试成功后按实际覆盖更新。

### C03 · 固定输入版本与产物生命周期兼容

- 优先级：P0；阶段：S1；主功能：F02；对应功能：F02。
- 依赖：D01、D02、C00。
- Plane：新建工作项登记为 Backlog。
- 产出：固定输入 revision、产物 manifest/状态、来源引用与旧数据读取升级实现。
- PRD 来源章节：F02。
- 实施锚点：[`Integration/App/MeetingWorkspaceBridge.swift`](../../Integration/App/MeetingWorkspaceBridge.swift)、[`Integration/App/RecordingAgentResults.swift`](../../Integration/App/RecordingAgentResults.swift)、[`speech_note/speech_note/Features/Documents/TranscriptDocumentV1.swift`](../../speech_note/speech_note/Features/Documents/TranscriptDocumentV1.swift)、[`speech_note/speech_note/Features/Documents/PublicDocumentPublisher.swift`](../../speech_note/speech_note/Features/Documents/PublicDocumentPublisher.swift)。

验收标准：

1. 同一整理运行引用确定输入版本；产物记录来源、类型、运行状态和覆盖范围，原文更新可识别旧结果。
2. 失败/取消/未完成文件不发布为完整结果；重启可恢复可核对的状态。
3. Transcript@1 可读并按契约兼容升级；旧无 manifest 产物继续可读、明确元数据未知，不编造 revision 或成功状态；已有用户 Skill 不被迁移覆盖。

### C04 · 统一整理 Skill 与模板调用路径

- 优先级：P0；阶段：S1；主功能：F02；对应功能：F02。
- 依赖：C00、C03。
- Plane：新建工作项登记为 Backlog。
- 产出：统一各整理入口的 Skill/模板调用、输入/输出约定和配置缺失处理。
- PRD 来源章节：F02。
- 实施锚点：[`Integration/App/MeetingWorkspaceBridge.swift`](../../Integration/App/MeetingWorkspaceBridge.swift)、[`Integration/App/VoiceContextRootView.swift`](../../Integration/App/VoiceContextRootView.swift)、[`docs/features/generate-meeting-minutes-skill.md`](../../docs/features/generate-meeting-minutes-skill.md)、[`tools/VoiceContext/Templates/default-meeting-minutes.md`](../../tools/VoiceContext/Templates/default-meeting-minutes.md)、[`speech_note/Supporting/VoiceContextPack/Templates/default-meeting-minutes.md`](../../speech_note/Supporting/VoiceContextPack/Templates/default-meeting-minutes.md)。

验收标准：

1. 各入口执行同一已选整理能力与输入/输出约定，不因入口产生不同来源和产物规则。
2. 新安装、升级和已有用户自定义 Skill 按契约兼容，用户内容不静默覆盖。
3. 缺少配置/能力时明确失败或进入现有配置入口，不冒充已开始/已生成。

### C05 · 纪要语义与长文覆盖处理

- 优先级：P0；阶段：S1；主功能：F03；对应功能：F03。
- 依赖：C00、C02、C03、C04。
- Plane：新建工作项登记为 Backlog。
- 产出：会议纪要结构、决定/建议区分、长文分段覆盖及可核对来源生成流程。
- PRD 来源章节：F03。
- 实施锚点：[`docs/features/generate-meeting-minutes-skill.md`](../../docs/features/generate-meeting-minutes-skill.md)、[`tools/VoiceContext/Templates/default-meeting-minutes.md`](../../tools/VoiceContext/Templates/default-meeting-minutes.md)、[`speech_note/Supporting/VoiceContextPack/Templates/default-meeting-minutes.md`](../../speech_note/Supporting/VoiceContextPack/Templates/default-meeting-minutes.md)、[`Integration/App/MeetingWorkspaceBridge.swift`](../../Integration/App/MeetingWorkspaceBridge.swift)。

验收标准：

1. 纪要包含摘要、讨论、决定、行动项、未决问题，决定不混同建议或模型推断。
2. 长文覆盖可追踪，跨段行动/决定能汇总；失败、截断和缺口不冒充完整。
3. 关键结论保留来源，无法证实的日期/负责人不补成事实。

### C06 · 会议整理入口与纪要结果页面接入

- 优先级：P0；阶段：S1；主功能：F03；对应功能：F03。
- 依赖：D02、C00、C03、C04、C05。
- Plane：新建工作项登记为 Backlog。
- 产出：接入批准的整理入口、运行状态、纪要结果及来源导航页面，复用既有录音/聊天/结果能力。
- PRD 来源章节：F03。
- 实施锚点：[`Integration/App/VoiceContextRootView.swift`](../../Integration/App/VoiceContextRootView.swift)、[`Integration/App/RecordingAgentResults.swift`](../../Integration/App/RecordingAgentResults.swift)、[`speech_note/speech_note/Features/Recording/RecordingDetailView.swift`](../../speech_note/speech_note/Features/Recording/RecordingDetailView.swift)。

验收标准：

1. 能选择产物并跟踪具体运行；缺模型、输入未就绪、取消和失败据实说明并提供恢复入口。
2. 结果可回看固定来源版本；旧产物仍可访问。
3. 保持现有录音和回听入口可达，不重建已完成的待办管理页面。

### C07 · 结构化导图生成与校验

- 优先级：P1；阶段：S3；主功能：F04；对应功能：F04。
- 依赖：C00、C03、C04。
- Plane：新建工作项登记为 Backlog。
- 产出：稳定节点 ID、父子关系、内容与来源的导图模型、生成流程和校验。
- PRD 来源章节：F04。
- 实施锚点：[`Integration/App/MeetingWorkspaceBridge.swift`](../../Integration/App/MeetingWorkspaceBridge.swift)、[`Integration/App/RecordingAgentResults.swift`](../../Integration/App/RecordingAgentResults.swift)。

验收标准：

1. 验证无环、父引用有效、节点可达及来源合法，非法结构不标成功。
2. 节点保留来源；无原文依据的推断明确标记。
3. 长文导图遵循输入/覆盖契约，可生成文字等价结构供渲染失败时使用。

### C08 · 导图折叠树阅读与来源跳转

- 优先级：P1；阶段：S3；主功能：F04；对应功能：F04。
- 依赖：D03、C00、C07。
- Plane：新建工作项登记为 Backlog。
- 产出：折叠树导图阅读、文字等价视图、来源导航与 P1 导出实现。
- PRD 来源章节：F04。
- 实施锚点：[`Integration/App/RecordingAgentResults.swift`](../../Integration/App/RecordingAgentResults.swift)、[`speech_note/speech_note/Features/Recording/RecordingDetailView.swift`](../../speech_note/speech_note/Features/Recording/RecordingDetailView.swift)。

验收标准：

1. 节点展开/收起和阅读状态稳定，完整层级可通过文字与 VoiceOver 阅读。
2. 空/无效结果有可理解恢复入口；节点可定位来源。
3. 复用结构化数据，首版不实现自由画布或缩放。
4. 支持 Markdown 及评审约定的图形/图描述格式导出，保留节点层级与绑定来源；导出属于 P1，不影响 P0 纪要闭环。

### C09 · 行动建议结构化与逐项确认

- 优先级：P0；阶段：S2；主功能：F05；对应功能：F05。
- 依赖：D04、C00、C03。
- Plane：新建工作项登记为 Backlog。
- 产出：结构化行动建议的持久化、逐项编辑/勾选/确认与待创建状态。
- PRD 来源章节：F05。
- 实施锚点：[`Integration/App/RecordingAgentResults.swift`](../../Integration/App/RecordingAgentResults.swift)、[`Integration/App/VoiceContextRootView.swift`](../../Integration/App/VoiceContextRootView.swift)、[`Integration/App/MeetingWorkspaceBridge.swift`](../../Integration/App/MeetingWorkspaceBridge.swift)。

验收标准：

1. 行动项具有稳定 ID、标题、负责人原文、日期明确性与来源；不明确字段保留待确认。
2. 未明确确认具体事项不写系统；取消不产生新事项。
3. 批量确认可表达逐项结果，不把建议或待创建状态显示成已创建。

### C10 · 会议 Reminder 双向关联与幂等恢复

- 优先级：P0；阶段：S2；主功能：F06；对应功能：F06。
- 依赖：D04、C00、C09、C11。
- Plane：新建工作项登记为 Backlog。
- 产出：轻量来源关联索引、创建意图/回执恢复、重复提交防护、外部状态核对及双向导航。
- PRD 来源章节：F06。
- 实施锚点：[`Integration/App/RecordingAgentResults.swift`](../../Integration/App/RecordingAgentResults.swift)、[`Integration/App/SystemRemindersView.swift`](../../Integration/App/SystemRemindersView.swift)、[`Integration/App/VoiceContextRootView.swift`](../../Integration/App/VoiceContextRootView.swift)、[`Integration/App/MeetingWorkspaceBridge.swift`](../../Integration/App/MeetingWorkspaceBridge.swift)。

验收标准：

1. 同一行动项重复确认、回执丢失、写入后中断和重试不重复创建；结果不明先核对。
2. 会议与提醒互相导航，外部完成、移动、删除反映实际状态；权限失效不当删除。
3. 关联失效不自动重建；应用不维护第二份任务完成状态；接入 C12 已定义的源删除/解除关联规则。

### C11 · Reminder 工具与 UI 契约统一

- 优先级：P0；阶段：S1；主功能：F07；对应功能：F07。
- 依赖：D05、C00。
- Plane：新建工作项登记为 Backlog。
- 产出：统一 Reminder 写入/查询参数、实际回执、列表 ID、日期/通知语义及真实执行点权限校验。
- PRD 来源章节：F07。
- 实施锚点：[`Integration/App/SystemRemindersView.swift`](../../Integration/App/SystemRemindersView.swift)、[`Integration/App/ReminderDateEditing.swift`](../../Integration/App/ReminderDateEditing.swift)、[`Vendor/Phone/src/ios/NativeOffloads/RemindersOffload.m`](../../Vendor/Phone/src/ios/NativeOffloads/RemindersOffload.m)、[`Vendor/Phone/src/ios/NativeOffloads/CalendarOffload.m`](../../Vendor/Phone/src/ios/NativeOffloads/CalendarOffload.m)、[`Vendor/Phone/src/ios/Agent/Offload/OffloadPermissionManager.swift`](../../Vendor/Phone/src/ios/Agent/Offload/OffloadPermissionManager.swift)。

验收标准：

1. 支持明确列表 ID、日期/是否含时间/时区、独立定时提醒，回执返回实际列表和时间/通知设置。
2. 非法日期、失效/只读列表明确失败且不产生半配置写入，指定列表失败不能回退默认。
3. 查询可以核对实际设置；直接或间接工具调用在真实执行点遵守同一权限规则；复用现有 CRUD。

### C12 · 受管资料残留清理与迟到回调防复活

- 优先级：P0；阶段：S1；主功能：F08；对应功能：F08、F02、F01。
- 依赖：D06、C00、C01、C03。
- Plane：新建工作项登记为 Backlog。
- 产出：S1 受管原文、不可变输入快照、旧校对版本/重转写候选、公开副本和生成物的保留/删除/发送范围控制，以及 AI/ASR 迟到回调防复活；不包含新行动关联集成。
- PRD 来源章节：F08、F02、F01。
- 实施锚点：[`Integration/App/MeetingWorkspaceBridge.swift`](../../Integration/App/MeetingWorkspaceBridge.swift)、[`Integration/App/RecordingAgentResults.swift`](../../Integration/App/RecordingAgentResults.swift)、[`speech_note/speech_note/Features/Recording/Persistence/RecordingRepository.swift`](../../speech_note/speech_note/Features/Recording/Persistence/RecordingRepository.swift)、[`speech_note/speech_note/Features/Documents/PublicDocumentPublisher.swift`](../../speech_note/speech_note/Features/Documents/PublicDocumentPublisher.swift)。

验收标准：

1. 按已冻结规则覆盖受管原文、F02 不可变输入快照、F01 旧校对版本/重转写候选、公开副本、生成物和可重建缓存；区分音频到期与删除整条记录。
2. 删除完成后迟到的 AI/ASR 回调、重启恢复和残留任务不能重新发布已删除记录的文稿、快照或产物，删除失败据实报告。
3. 保留与模型发送范围可核对，不扩大原音频保留/上传范围；仅处理应用管理的数据，不擅自删除用户自行复制或外部系统事项。
4. C12 在 S1 按本范围验收完成，不等待 C10/C13；新行动关联删除由 C13 单独交付。

### C13 · 来源删除与新行动关联集成

- 优先级：P0；阶段：S2；主功能：F08；对应功能：F08、F06、F05。
- 依赖：C00、C10、C12、D06。
- Plane：新建工作项登记为 Backlog。
- 产出：S2 来源删除与新行动建议/系统提醒关联的集成处理，包含已创建事项保留、未确认建议终止、映射清理或来源删除状态，以及外部失败分类。
- PRD 来源章节：F08、F06、F05。
- 实施锚点：[`Integration/App/RecordingAgentResults.swift`](../../Integration/App/RecordingAgentResults.swift)、[`Integration/App/SystemRemindersView.swift`](../../Integration/App/SystemRemindersView.swift)、[`Integration/App/MeetingWorkspaceBridge.swift`](../../Integration/App/MeetingWorkspaceBridge.swift)、[`speech_note/speech_note/Features/Recording/Persistence/RecordingRepository.swift`](../../speech_note/speech_note/Features/Recording/Persistence/RecordingRepository.swift)。

验收标准：

1. 来源记录删除时已创建的系统提醒事项默认保留，不以解除来源关联作为系统事项删除授权。
2. 尚未确认的行动建议不能因来源删除、恢复或迟到结果产生新系统事项；已确认写入结果不明时按 C10 幂等恢复规则核对，不能盲目补建。
3. 按契约清理映射或标记来源已删除，关联页面显示真实状态；系统事项完成状态仍由 EventKit 提供。
4. 权限撤销、暂不可读取、外部系统事项已删除和删除失败分别处理，不能混同；C12 受管资料防复活规则在新关联路径持续成立。

## 测试验收

### T01 · 校对保护与音频完整性非运行回归

- 优先级：P0；阶段：S1；主功能：F01；对应功能：F01。
- 依赖：C01、C02。
- Plane：新建工作项登记为 Backlog。
- 产出：使用可控输入与回调的非 iOS 运行回归和结果记录，覆盖校对、音频预检、完整性与空识别。
- PRD 来源章节：F01。
- 实施锚点：[`speech_note/speech_note/Features/Documents/TranscriptDocumentV1.swift`](../../speech_note/speech_note/Features/Documents/TranscriptDocumentV1.swift)、[`speech_note/speech_note/Features/Documents/TranscriptDocumentEdits.swift`](../../speech_note/speech_note/Features/Documents/TranscriptDocumentEdits.swift)、[`speech_note/speech_note/Features/Recording/RecordingSessionCoordinator.swift`](../../speech_note/speech_note/Features/Recording/RecordingSessionCoordinator.swift)、[`speech_note/speech_note/Features/Transcription/ForegroundTranscriptionScheduler.swift`](../../speech_note/speech_note/Features/Transcription/ForegroundTranscriptionScheduler.swift)。

验收标准：

1. 音频过期、缺失、不可解码时重转写预检失败且旧文稿/校对内容完整保留。
2. 迟到回调、重复处理、人工编辑并发和失败片段均不静默丢失校对或冒充完整。
3. 正常静音与有声识别为空分别验收，后者不能作为正常静音/完整成功处理。

### T02 · 版本兼容与受管资料删除非运行回归

- 优先级：P0；阶段：S1；主功能：F02；对应功能：F02、F08、F01。
- 依赖：C03、C04、C12。
- Plane：新建工作项登记为 Backlog。
- 产出：S1 非运行契约回归与证据，覆盖固定输入版本、产物生命周期、旧数据/Skill 兼容、受管资料清理及迟到回调；不包含新行动关联删除。
- PRD 来源章节：F02、F08、F01。
- 实施锚点：[`Integration/App/MeetingWorkspaceBridge.swift`](../../Integration/App/MeetingWorkspaceBridge.swift)、[`Integration/App/RecordingAgentResults.swift`](../../Integration/App/RecordingAgentResults.swift)、[`speech_note/speech_note/Features/Documents/TranscriptDocumentV1.swift`](../../speech_note/speech_note/Features/Documents/TranscriptDocumentV1.swift)、[`speech_note/speech_note/Features/Recording/Persistence/RecordingRepository.swift`](../../speech_note/speech_note/Features/Recording/Persistence/RecordingRepository.swift)。

验收标准：

1. 验证原文更新、取消、失败、重启恢复及旧残留清理；生成结果状态不虚报。
2. Transcript@1、旧无 manifest 产物和已有用户 Skill 升级后继续可用，未知元数据不被编造，用户内容不覆盖。
3. 受管原文、不可变输入快照、旧校对版本/重转写候选、公开副本和生成物按规则删除；AI/ASR 迟到回调或残留任务不复活已删除资料。
4. T02 在 S1 按本范围独立验收，不依赖 C13；新行动关联删除交由 T04 检查。

### T03 · 纪要长文语义与导图结构验收样本

- 优先级：P0；阶段：S1；主功能：F03；对应功能：F03、F04。
- 依赖：C05。
- Plane：新建工作项登记为 Backlog。
- 产出：纪要 P0 样本/来源覆盖回归与人工内容评审记录；另附导图 P1 结构用例。
- PRD 来源章节：F03、F04。
- 实施锚点：[`docs/features/generate-meeting-minutes-skill.md`](../../docs/features/generate-meeting-minutes-skill.md)、[`tools/VoiceContext/Templates/default-meeting-minutes.md`](../../tools/VoiceContext/Templates/default-meeting-minutes.md)、[`Integration/App/RecordingAgentResults.swift`](../../Integration/App/RecordingAgentResults.swift)。

验收标准：

1. P0 门禁验证明确决定/建议、未决项、缺口与跨段行动样本，检查结构、覆盖和来源，不把模型质量伪装为精确字串测试。
2. P0 验收不依赖 C07/C08；纪要覆盖与异常结果可独立交付。
3. P1 用例在 C07 就绪后验证导图环、孤立/非法父引用、非法来源；该附加用例不是 P0 门禁。
4. P1 导出用例在 C08 就绪后验证 Markdown 及约定图形/图描述格式可用、节点层级与来源保持一致；导出验收不得阻塞 P0 纪要门禁。

### T04 · 行动确认幂等与外部状态非运行回归

- 优先级：P0；阶段：S2；主功能：F06；对应功能：F06、F05、F08。
- 依赖：C09、C10、C11、C13。
- Plane：新建工作项登记为 Backlog。
- 产出：采用可控提醒服务替身的行动确认、写入恢复、关联、外部状态和来源删除集成契约回归。
- PRD 来源章节：F06、F05、F08。
- 实施锚点：[`Integration/App/RecordingAgentResults.swift`](../../Integration/App/RecordingAgentResults.swift)、[`Integration/App/SystemRemindersView.swift`](../../Integration/App/SystemRemindersView.swift)、[`Vendor/Phone/src/ios/NativeOffloads/CalendarOffload.m`](../../Vendor/Phone/src/ios/NativeOffloads/CalendarOffload.m)。

验收标准：

1. 未确认零写入；回执丢失、写入后中断、部分成功与连续重试只产生应有事项。
2. 外部完成、改名、移动、删除和权限撤销分别得到正确关联状态，不能自动重建。
3. 实际完成状态只读取提醒服务；源引用与系统 ID 可核对，批量成功项不重复提交。
4. 来源删除后已创建系统事项默认保留，未确认建议不新增；映射清理或来源删除标记符合契约，迟到结果不恢复已删除来源。
5. 区分外部权限失效、暂不可读取、系统事项已删除和删除失败；不以权限失效推断系统事项删除，不盲目补建。

### T05 · Reminder 参数回执与权限非运行回归

- 优先级：P0；阶段：S1；主功能：F07；对应功能：F07。
- 依赖：C11。
- Plane：新建工作项登记为 Backlog。
- 产出：Reminder 参数、实际回执与权限契约回归，复用既有日期测试并补覆盖缺口。
- PRD 来源章节：F07。
- 实施锚点：[`tools/integration/test_reminder_dates.swift`](../../tools/integration/test_reminder_dates.swift)、[`Integration/App/ReminderDateEditing.swift`](../../Integration/App/ReminderDateEditing.swift)、[`Vendor/Phone/src/ios/NativeOffloads/CalendarOffload.m`](../../Vendor/Phone/src/ios/NativeOffloads/CalendarOffload.m)、[`Vendor/Phone/src/ios/Agent/Offload/OffloadPermissionManager.swift`](../../Vendor/Phone/src/ios/Agent/Offload/OffloadPermissionManager.swift)。

验收标准：

1. 无日期、仅日期、带时间/时区、独立提醒与非法日期符合约定，不产生半配置事项。
2. 同名、失效、只读列表按 ID 与写权限处理，指定目标不回退默认。
3. 回执可核对实际日期/通知设置；直接及间接调用权限一致；纯模型/契约回归不读取本机提醒或申请权限。

### T06 · 录音 AI 行动事项真机闭环验收

- 优先级：P0；阶段：S2；主功能：F03；对应功能：F03、F01、F05、F06、F07、F04。
- 依赖：C06、C10、T01、T02、T03、T04、T05。
- Plane：复用 TINGJI-22，保持原状态、父级与已有证据。
- 产出：在原 TINGJI-22 中增量补充专用系统测试列表的真机 E2E 用例与记录，不覆盖原状态、父级或已有证据。
- PRD 来源章节：F03、F01、F05、F06、F07、F04。
- 实施锚点：[`docs/testing/yima-minimum-iteration.md`](../../docs/testing/yima-minimum-iteration.md)、[`docs/testing/todo-overview.md`](../../docs/testing/todo-overview.md)、[`Integration/App/VoiceContextRootView.swift`](../../Integration/App/VoiceContextRootView.swift)、[`Integration/App/RecordingAgentResults.swift`](../../Integration/App/RecordingAgentResults.swift)、[`Integration/App/SystemRemindersView.swift`](../../Integration/App/SystemRemindersView.swift)。

验收标准：

1. 执行前取得用户对该次真机运行的明确授权，禁止模拟器；只操作专用测试数据。
2. P0 验证录音→ASR→校对→纪要→行动确认→系统提醒→来源回跳；App/系统同一事项，重试无重复，部分失败和外部变更符合约定，记录来源 revision 和系统 ID。
3. P0 门禁不依赖 D03/C07/C08；结构化导图的真机用例在 P1 完成后附加记录，不能因尚未实施 P1 阻塞 P0 验收。
4. 保留 TINGJI-22 原状态、父级和证据；未执行/失败/通过分别记录，编译不作为运行通过。

### T07 · 权限生命周期通知与录音连续性真机验收

- 优先级：P0；阶段：S2；主功能：F07；对应功能：F07、F02、F08、F04。
- 依赖：C06、C10、C11、C12、C13、T02、T05。
- Plane：复用 TINGJI-21，保持原状态、父级与已有证据。
- 产出：在原 TINGJI-21 中增量补充权限、通知、生命周期、隐私和录音连续性矩阵，不覆盖原状态、父级或已有证据。
- PRD 来源章节：F07、F02、F08、F04。
- 实施锚点：[`docs/testing/yima-minimum-iteration.md`](../../docs/testing/yima-minimum-iteration.md)、[`docs/testing/todo-overview.md`](../../docs/testing/todo-overview.md)、[`Integration/App/SystemRemindersView.swift`](../../Integration/App/SystemRemindersView.swift)、[`Integration/App/MeetingWorkspaceBridge.swift`](../../Integration/App/MeetingWorkspaceBridge.swift)、[`Integration/App/VoiceContextRootView.swift`](../../Integration/App/VoiceContextRootView.swift)。

验收标准：

1. 执行前取得用户对该次真机运行的明确授权，禁止模拟器；首次允许/拒绝/撤销/恢复据实记录。
2. P0 单独核验定时通知真实到达、跨 Tab/权限与编辑 Sheet 的实际录音连续性，以及删除/发送范围；仅保存成功不算通知到达。
3. P0 页面覆盖中英文、深浅色、Dynamic Type 至 accessibility3、VoiceOver 和 Reduce Motion；保留 TINGJI-21 原状态、父级和证据。
4. P0 验证来源删除后的受管资料清理与新关联状态：已创建系统事项默认保留、未确认不新增，权限失效与实际系统删除/删除失败分别呈现。
5. P0 门禁不依赖 P1 导图；导图无障碍/阅读用例在 C08 就绪后作为独立 P1 附加用例记录。

## 登记与验证记录

本清单与本机忽略目录中的 `build/recording-ai-actions-plane-plan.json` 使用相同的稳定任务编号；JSON 用于同步工具输入，不提交仓库。其 `version` 是中间数据格式版本，不是产品版本，`date` 是草案日期，不是任务排期。任务源章节使用 F01～F08 稳定编号；功能主归口取 `features` 的第一项，其他项在正文保留。

27 项任务的标识、类别、优先级、阶段、依赖和对应功能可静态校验；所有依赖必须指向本清单已有任务且无循环。新增任务使用交互设计、代码开发、测试验收三类标签。既有 TINGJI-21/22 只增量补充范围和证据，不自动改成 Backlog、不改变父级、不抹去已有验收记录。没有真实执行的用例不得登记为通过。

## Plane 同步结果（2026-10-02）

[完整 PRD 总览 TINGJI-23](http://100.125.201.118:8082/yijie/projects/b6458d01-ae80-4836-b0d8-d791fefd9775/issues/a9532895-8e2c-470f-a2d4-d423c316ea86/)已保存全文并回读核对。沿用「听记 / TINGJI」，8 个功能与 27 项任务共关联 36 个工作项；新增 33 项，复用 TINGJI-11、21、22。新增项均为 Backlog，复用项保留原状态、父级、名称和历史正文；未安排负责人、日期或目标版本。

交互设计 6 项、代码开发 14 项、测试验收 7 项均使用对应标签；每项正文包含来源功能、交付物、验收标准及实际前置编号。P0 不依赖 P1 导图；登记结果不代表实施或验收通过。

| 功能 | Plane 需求 |
| --- | --- |
| F01 | [TINGJI-24 · 重转写保护与文稿完整性](http://100.125.201.118:8082/yijie/projects/b6458d01-ae80-4836-b0d8-d791fefd9775/issues/236fdd12-c8e3-4374-a41a-7b80a0580a9d/) |
| F02 | [TINGJI-25 · 固定来源版本、统一产物协议与 Skill 兼容](http://100.125.201.118:8082/yijie/projects/b6458d01-ae80-4836-b0d8-d791fefd9775/issues/5a69e1a3-c893-4f66-848c-edbdd6616a24/) |
| F03 | [TINGJI-11 · 提供对白整理与自动会议纪要两种输出](http://100.125.201.118:8082/yijie/projects/b6458d01-ae80-4836-b0d8-d791fefd9775/issues/41c11aa9-b011-4b4b-bee7-470e8a1ef5f1/) |
| F04 | [TINGJI-26 · 思维导图树与节点来源](http://100.125.201.118:8082/yijie/projects/b6458d01-ae80-4836-b0d8-d791fefd9775/issues/a335113a-849f-474e-a51d-f15d890c312c/) |
| F05 | [TINGJI-27 · 行动建议的具体确认](http://100.125.201.118:8082/yijie/projects/b6458d01-ae80-4836-b0d8-d791fefd9775/issues/5893d0ae-2cf9-4f84-922c-bb26c1ccf941/) |
| F06 | [TINGJI-28 · 录音与系统事项的来源关联及幂等](http://100.125.201.118:8082/yijie/projects/b6458d01-ae80-4836-b0d8-d791fefd9775/issues/64e8a139-bf07-486f-a211-6f4f3ad10d19/) |
| F07 | [TINGJI-29 · UI 与提醒工具的统一契约](http://100.125.201.118:8082/yijie/projects/b6458d01-ae80-4836-b0d8-d791fefd9775/issues/c766f277-fd10-4f49-aeb7-496cd1c06dd0/) |
| F08 | [TINGJI-30 · 音频保留、删除一致性与输入隐私](http://100.125.201.118:8082/yijie/projects/b6458d01-ae80-4836-b0d8-d791fefd9775/issues/33b4636b-8aa1-4d98-8600-821508a49627/) |

| 任务 | 类别 | Plane | 前置任务 |
| --- | --- | --- | --- |
| D01 | 交互设计 | [TINGJI-31](http://100.125.201.118:8082/yijie/projects/b6458d01-ae80-4836-b0d8-d791fefd9775/issues/92c14ab1-2589-4496-8670-ef77aaf40677/) | 无任务前置 |
| D02 | 交互设计 | [TINGJI-32](http://100.125.201.118:8082/yijie/projects/b6458d01-ae80-4836-b0d8-d791fefd9775/issues/a1dcbc35-c614-4c3c-89b1-22da9c1d77cd/) | D01 / TINGJI-31 |
| D03 | 交互设计 | [TINGJI-37](http://100.125.201.118:8082/yijie/projects/b6458d01-ae80-4836-b0d8-d791fefd9775/issues/82587bb2-cf85-43c3-9243-ec88dcd896f4/) | C00 / TINGJI-36 |
| D04 | 交互设计 | [TINGJI-33](http://100.125.201.118:8082/yijie/projects/b6458d01-ae80-4836-b0d8-d791fefd9775/issues/ef047657-4bea-4eae-ba9e-718d2735f429/) | D02 / TINGJI-32 |
| D05 | 交互设计 | [TINGJI-34](http://100.125.201.118:8082/yijie/projects/b6458d01-ae80-4836-b0d8-d791fefd9775/issues/98cc2975-6ca8-45a2-817e-0bafb03c391c/) | D04 / TINGJI-33 |
| D06 | 交互设计 | [TINGJI-35](http://100.125.201.118:8082/yijie/projects/b6458d01-ae80-4836-b0d8-d791fefd9775/issues/4087b698-72e7-43b4-b3bf-180ad3ce5a7e/) | 无任务前置 |
| C00 | 代码开发 | [TINGJI-36](http://100.125.201.118:8082/yijie/projects/b6458d01-ae80-4836-b0d8-d791fefd9775/issues/ddf94670-2224-4153-8644-02de3153fe1b/) | D01 / TINGJI-31、D02 / TINGJI-32、D04 / TINGJI-33、D05 / TINGJI-34、D06 / TINGJI-35 |
| C01 | 代码开发 | [TINGJI-38](http://100.125.201.118:8082/yijie/projects/b6458d01-ae80-4836-b0d8-d791fefd9775/issues/f3aec09f-90c9-42e5-a642-4df55e996831/) | D01 / TINGJI-31、C00 / TINGJI-36 |
| C02 | 代码开发 | [TINGJI-39](http://100.125.201.118:8082/yijie/projects/b6458d01-ae80-4836-b0d8-d791fefd9775/issues/c5a7fc38-adb4-4ef1-87ae-937a83839ed7/) | D01 / TINGJI-31、C00 / TINGJI-36 |
| C03 | 代码开发 | [TINGJI-40](http://100.125.201.118:8082/yijie/projects/b6458d01-ae80-4836-b0d8-d791fefd9775/issues/140c53a9-ac43-448c-a554-ed3fad5e3374/) | D01 / TINGJI-31、D02 / TINGJI-32、C00 / TINGJI-36 |
| C04 | 代码开发 | [TINGJI-41](http://100.125.201.118:8082/yijie/projects/b6458d01-ae80-4836-b0d8-d791fefd9775/issues/f50c4415-d400-4f73-ba09-847c539742d2/) | C00 / TINGJI-36、C03 / TINGJI-40 |
| C05 | 代码开发 | [TINGJI-42](http://100.125.201.118:8082/yijie/projects/b6458d01-ae80-4836-b0d8-d791fefd9775/issues/8835b4d8-172b-4832-8987-2fcab264ddc1/) | C00 / TINGJI-36、C02 / TINGJI-39、C03 / TINGJI-40、C04 / TINGJI-41 |
| C06 | 代码开发 | [TINGJI-43](http://100.125.201.118:8082/yijie/projects/b6458d01-ae80-4836-b0d8-d791fefd9775/issues/cd176f92-fef8-4027-8cd4-0d5fa341a94f/) | D02 / TINGJI-32、C00 / TINGJI-36、C03 / TINGJI-40、C04 / TINGJI-41、C05 / TINGJI-42 |
| C07 | 代码开发 | [TINGJI-44](http://100.125.201.118:8082/yijie/projects/b6458d01-ae80-4836-b0d8-d791fefd9775/issues/041ddca3-21f5-43a8-bead-30879c8d5d42/) | C00 / TINGJI-36、C03 / TINGJI-40、C04 / TINGJI-41 |
| C08 | 代码开发 | [TINGJI-45](http://100.125.201.118:8082/yijie/projects/b6458d01-ae80-4836-b0d8-d791fefd9775/issues/3aca72ea-9544-4b86-9227-09febedc2657/) | D03 / TINGJI-37、C00 / TINGJI-36、C07 / TINGJI-44 |
| C09 | 代码开发 | [TINGJI-46](http://100.125.201.118:8082/yijie/projects/b6458d01-ae80-4836-b0d8-d791fefd9775/issues/0cd6aa1a-abd2-4e77-8148-49d704d78fb7/) | D04 / TINGJI-33、C00 / TINGJI-36、C03 / TINGJI-40 |
| C10 | 代码开发 | [TINGJI-48](http://100.125.201.118:8082/yijie/projects/b6458d01-ae80-4836-b0d8-d791fefd9775/issues/f00d6cd3-59e3-48d3-b3ab-9cc3123411c0/) | D04 / TINGJI-33、C00 / TINGJI-36、C09 / TINGJI-46、C11 / TINGJI-47 |
| C11 | 代码开发 | [TINGJI-47](http://100.125.201.118:8082/yijie/projects/b6458d01-ae80-4836-b0d8-d791fefd9775/issues/aae1f769-03b5-429b-a693-e2ef3aeb64e9/) | D05 / TINGJI-34、C00 / TINGJI-36 |
| C12 | 代码开发 | [TINGJI-49](http://100.125.201.118:8082/yijie/projects/b6458d01-ae80-4836-b0d8-d791fefd9775/issues/66f75fce-9500-40bd-8cdd-6ec2966b9213/) | D06 / TINGJI-35、C00 / TINGJI-36、C01 / TINGJI-38、C03 / TINGJI-40 |
| C13 | 代码开发 | [TINGJI-50](http://100.125.201.118:8082/yijie/projects/b6458d01-ae80-4836-b0d8-d791fefd9775/issues/8d706aae-0979-44c1-91ed-3ac9f8fc8e23/) | C00 / TINGJI-36、C10 / TINGJI-48、C12 / TINGJI-49、D06 / TINGJI-35 |
| T01 | 测试验收 | [TINGJI-51](http://100.125.201.118:8082/yijie/projects/b6458d01-ae80-4836-b0d8-d791fefd9775/issues/76ab8e0e-2466-49b3-b315-4d3f09ee29b2/) | C01 / TINGJI-38、C02 / TINGJI-39 |
| T02 | 测试验收 | [TINGJI-52](http://100.125.201.118:8082/yijie/projects/b6458d01-ae80-4836-b0d8-d791fefd9775/issues/7241445b-8a9e-408c-9479-5b0d0c47c488/) | C03 / TINGJI-40、C04 / TINGJI-41、C12 / TINGJI-49 |
| T03 | 测试验收 | [TINGJI-53](http://100.125.201.118:8082/yijie/projects/b6458d01-ae80-4836-b0d8-d791fefd9775/issues/16f10a95-ce2f-4de8-828d-0abf9ce5f9a1/) | C05 / TINGJI-42 |
| T04 | 测试验收 | [TINGJI-54](http://100.125.201.118:8082/yijie/projects/b6458d01-ae80-4836-b0d8-d791fefd9775/issues/506a8d57-7fbb-4190-a9f9-498722e62757/) | C09 / TINGJI-46、C10 / TINGJI-48、C11 / TINGJI-47、C13 / TINGJI-50 |
| T05 | 测试验收 | [TINGJI-55](http://100.125.201.118:8082/yijie/projects/b6458d01-ae80-4836-b0d8-d791fefd9775/issues/f7b19597-7a9e-47c9-896e-dbc40f4ae834/) | C11 / TINGJI-47 |
| T06 | 测试验收 | [TINGJI-22](http://100.125.201.118:8082/yijie/projects/b6458d01-ae80-4836-b0d8-d791fefd9775/issues/6d80bb3e-c0f2-4e2f-9d5c-440092b723a0/)（复用） | C06 / TINGJI-43、C10 / TINGJI-48、T01 / TINGJI-51、T02 / TINGJI-52、T03 / TINGJI-53、T04 / TINGJI-54、T05 / TINGJI-55 |
| T07 | 测试验收 | [TINGJI-21](http://100.125.201.118:8082/yijie/projects/b6458d01-ae80-4836-b0d8-d791fefd9775/issues/0b8a44fa-294c-4b1b-a4e3-a939a0a2b88a/)（复用） | C06 / TINGJI-43、C10 / TINGJI-48、C11 / TINGJI-47、C12 / TINGJI-49、C13 / TINGJI-50、T02 / TINGJI-52、T05 / TINGJI-55 |

当前部署不支持 Pages API，完整 PRD 保存在总览正文；原生依赖接口返回 404，故未创建原生阻塞关系，前置关系按稳定编号与真实 Plane 编号保存在本文及任务正文。新建父子层级已登记，复用项保留原父级。

逐项回读 36 个关联工作项，核对全文、35 个验收案例、名称、优先级、标签、状态、父级、依赖引用及历史内容；项目说明保留原文后追加本轮索引。完整 ID、链接、文档 SHA-256 与核验记录见 [同步回执](./recording-ai-actions-plane-sync.json)。
