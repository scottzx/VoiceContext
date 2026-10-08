# 录音 AI 行动闭环：C00 契约评审稿

2026-10-06 范围变更：本契约对 Yima 自有事项的系统唯一权威限制由[自有日程/待办设计](./yima-owned-calendar-reminders.md)替代。确认意图、来源版本、幂等和结果不明恢复继续适用；事项目标、权限、身份映射、回执与可选系统同步需重新评审。本契约尚不能作为新增本地事项或同步协议已冻结的依据。

- 日期：2026-10-03；状态：待评审，未冻结、未发布存储格式。
- 依据：[PRD](../PRD-recording-ai-actions.md) §4、§7、§8、§10；[交付清单](recording-ai-actions-delivery.md) C00。
- 前置：D01、D02、D04、D05、D06 的交互评审；P1 导图不阻塞 P0。
- 配套：[交互规格](recording-ai-actions-interaction.md)。以下技术选择供评审，不将字段提案当成现有实现。

## 现有实现的接入约束

以 [现有产品基线](recording-ai-actions-existing-product.md) 和其中源码快照为实现起点。`RecordingDetailScreen` 保留四内容 Tab、更多菜单、单句编辑及底部播放器；`VoiceContextRootView` / `ContentView` 保留现有草稿与发送；`RecordingAgentResults` 保留产物 Sheet、文件列表与 QuickLook；`SystemRemindersView` 保留日历/筛选/CRUD，`ReminderEditor` 已有按列表 ID 选择、due 与独立 alarm。新的状态和服务接入这些入口，不以本稿替换既有通用 UI 或录音/聊天调度。

现有通知仅传 recordingID，草稿仅预填文字，桥接 Source 会刷新；它们尚不能证明固定输入或真实运行。新增请求关联沿现有草稿 ID → `.sessionDidCreate` 后真实 session ID → 实际发送的 user message / 执行生命周期建立，不另起通用运行器。当前 `AIChatViewModel` / `AgentRunEngine` 没有整理业务的独立持久 run ID；新的 runID 是 attempt 关联提案，必须绑定 triggerMessageID、实际开始/结束事件与 inputSha256。流中可变化的 assistant `runMsgId`、会话 ID 或工具批次 ID 均不能代替它。

待办 UI 已具备的字段不重复从零实现。C11 的缺口是工具参数与 UI 采用同一业务契约、执行点权限、实际回执和可核对失败；C10 再接具体确认、持久独占与关联。二者均不得用另存的完成状态替代 EventKit。

## 权威与兼容

Recording repository 管音频与任务，TranscriptDocumentStore 管 canonical 文稿，现有 ChatStore 管会话/消息、聊天执行器管执行，EventKit 管系统事项。AgentKit 的 AgentStore 不是持久运行日志。新记录只补整理 attempt 关联、来源、确认意图和产物索引，不创建另一份系统事项内容/完成状态权威。

`voice-context/transcript@1` 保持可读，不把新字段设成旧文稿的必填字段。完整性放在请求快照的伴随元数据中；缺少证据时是 `unknown`，不能由 `state=complete` 或 `gaps=[]` 自动推断 `complete`。后续如升级 canonical schema，另做版本迁移和旧数据回归。

旧 Generated 文件继续按“历史文件，来源/运行状态未记录”读取；不自动伪造成功 manifest。旧会议 `generated/` 文件仅在来源头可核对时建立历史索引；读取旧路径不授权写入 Source。已有用户 Skill/模板保持原文，默认能力采用新适配器或可辨别升级，不能覆盖用户修改。

## 标识、版本与路径

所有 request、artifact、action 和 confirmation 标识为 UUID。来源标识用现有 recordingID；source revision 为正整数。内容摘要为 SHA-256 小写十六进制。

source.sha256 针对创建时 canonical JSON 的 UTF-8 字节，用于来源版本核对；inputSha256 针对实际发送快照字节，不针对后来重新编码的等价对象。先读取 canonical JSON 并核对 recordingID/revision，再按所选 segmentIDs 制作 `voice-context/recording-input@1` 输入，原子保存一次并绑定 inputSha256。输入只含所选文字、来源范围与明确选用的元数据/模板，不把未选原文隐藏在其他字段。时间范围按完整段选择，核对页显示实际覆盖边界。一次运行只读这份输入；canonical 更新后只能新建请求，旧结果保留并显示来源已更新。

提案：权威请求、写入意图和删除记录保存在应用私有、仅本机的受管目录；本轮不默认同步到 iCloud。模型只得到本次选定文稿的工作副本、明确选用的模板和元数据。共享目录的副本可编辑，因此提交必须重新核对私有权威输入，不能把共享副本当安全只读挂载。

共享布局提案：`VoiceContext/Requests/<requestID>/input.json` 与 `request.json`；输出先在 `Generated/<recordingID>/.staging/<artifactID>/`，校验成功后发布到 `Generated/<recordingID>/<artifactID>/`。manifest 的路径只允许相对于该 artifact 目录，拒绝绝对路径、空路径、`.`/`..`、反斜线、符号链接或解析后越界；每个 ID 必须先解析成 UUID，禁止直接将任意输入拼路径。

## 最小对象

以下为新格式 `voice-context/recording-ai@1` 的对象提案，未用于生产读写。实现时使用严格解码器和业务校验，不只检查 JSON 语法。

| 对象 | 必填 | 可空/可选 | 业务校验 |
|---|---|---|---|
| source | recordingID、revision、sha256 | 无 | ID/revision/hash 与权威快照相同；段 ID 与范围在 citation 中绑定 |
| request | schema/objectKind、requestID、source、recordingContext、selectionMode、inputPath、inputSha256、selectedSegmentIDs、resultTypes、typeOutcomes、state、runAssociations、createdAt/updatedAt、completeness、可空 modelBindingID | recordingEvidenceRef；模板在固定 input 内 | recordingContext 对应既有 kind/started_at/timezone，未知保留 null；不保存凭据；无文字失败；无模型不转为运行中；实际输入仅含所选段 |
| completeness | processingState、contentState、ranges、warnings | 每个范围的失败原因 | processing 为 capturing/processing/terminal；content 为 complete/partial/unknown；静音和有声空识别使用不同范围原因 |
| artifact | schema/objectKind、artifactID、requestID、runID/sessionID/triggerMessageID、inputSha256、source、type、status、files、coverage、citations、createdAt、data | template、warnings；minutes.data 必填 summaryClass/reason | type 为 minutes/mindmap/actions/export；files 每项含 relativePath/mediaType/sha256；正式 manifest 必须有实际执行关联；发布只接受 validated 后的 committed |
| citation | source、segmentIDs | start/end sample、excerpt | 至少一个 segment；范围非负且起点小于终点；不凭当前新版 segment 假装定位旧版 |
| action | actionID、artifactID、source、title、citations、status | ownerFact、ownerUncertainty、due、alarm、listID、notes | 未知日期/负责人保留空值；title 非空；candidate 不具备写入权限 |
| confirmation | confirmationID、actionID、artifactID、source、citations、payload、payloadHash、state、createdAt | reminderID、receipt、error | payload 是用户所见的已确认值；hash 对 actionID/artifactID/source/citations/payload 的确切 canonical bytes，见附录；同 ID 改内容拒绝 |
| deletion | recordingID、startedAt、policy、objects、state | 各对象 error、retry 时间 | policy 对受管原文始终 delete；系统事项始终 keep；对象逐项记录进度 |

completeness 范围以已有 job/source range 的样本坐标记录。每段 outcome 为 pending/transcribed/silence/voicedEmpty/unreadable/missing/failed/interrupted；failed 附 stage（decode/vad/utterance/asr）与 reasonCode，不能把旧错误名直接迁成 silence。无可靠声音证据不能将空结果标为 silence。`complete` 需要闭合判定域内全部输入由可核对证据覆盖且没有 unresolved 范围；`partial` 包含已知缺口，`unknown` 表示旧数据不足以判定。两者都允许用户主动整理已有文字，必须带警告。

范围必须带现有 source kind（audio chunk 或 imported asset）、source ID 与 16 kHz 的半开样本区间，不能仅以 segmentIDs 表达：静音、损坏和有声空识别可以没有文字段。旧零长度引用继续可读，但不能作为已覆盖非空区间的证据。完整性判定同时记录本次所选范围与整条录音的已知处理边界，不能用局部覆盖宣称整条录音完整。

机器草案显式区分 selectionMode=all/segments：all 必须包含该版本全部文字段，可携全录音无文字范围的已知证据；segments 的范围、声音证据、警告与定位点仅投影所选段。两种模式均核对旧零范围 anchor 的确切 segment/source/sample，不把定位点扩写为覆盖。公开输入只有 scope=selection 的投影和 recordingContentState 摘要，完整录音伴随证据留在私有域。

请求另绑定来源 kind、录音发生时间与原时区（对应已有 `kind`、`started_at`、`timezone`）；缺失时保留 unknown/null，不以 request.createdAt 或生成时设备时区补齐。“下周”等解释记录原表达、依据和待确认结果；未知依据时不计算成事实。产物持久化 `summaryClass`（formal / withMissingContent / preliminary / completenessUnknown）及原因；个人录音或处理未终结为 preliminary，已终结且有缺口为 withMissingContent，旧数据不足则明确完整性未知，不能由当前页面场景动态把旧结果升级为 formal。

重转写预检、候选版本与采纳、完整性伴随元数据和删除提交门禁在 [文稿契约附录](recording-ai-actions-transcript-contract.md) 定义；确认 payload、实际回执、统一接口与中断恢复在 [Reminder 契约附录](recording-ai-actions-reminder-contract.md) 定义。附录仍是评审提案，没有新生产读写或批准记录。

## 运行与提交

请求主路径：`prepared → running → validating → committed`；prepared 只表示输入已准备。失败为 failed，用户停止为 cancelled，进程中断为 interrupted；恢复必须核对真实 Agent run，不把创建草稿或发现文件当成运行/完成证据。重试新建运行关联，保留已提交产物。

resultTypes 多选时，typeOutcomes 按所选类型独立记录 pending/running/validating/committed/failed/cancelled/interrupted、已提交 artifactIDs 与错误。只有本次所选全部类型都已提交才为整体 committed；所有类型均已终结且至少一类提交、另一类失败/取消/中断，则整体 partiallyCommitted 并列出未提交类型。尚有类型处理中时不能因首个文件提交而显示整请求完成。停止/中断保留已提交类型及原状态证据；不将其变为失败临时文件。无成功产物的请求才可整体 failed/cancelled/interrupted，不能把“无产物”与“部分已提交”混同。

提交顺序：核对来源未删除 → 核对私有快照摘要 → 校验产物格式/所有引用/覆盖 → 核对每个文件的相对路径、mediaType 与原始 bytes 的 sha256 → 原子完成文件 → 原子发布 manifest。UI 只发布 committed manifest 对应的文件；读取时重新核对文件摘要，已提交字节被修改或缺失则显示损坏/不可用，不继续当作已验证正式内容。目录里无 manifest 的新临时文件不能成为正式结果；旧历史文件通过独立兼容入口阅读。多文件发布中断按 manifest 判定，不推断全部完成。

纪要 coverage 保存本次已读 segmentIDs 与缺失 segmentIDs，以及没有文字段的未解决来源范围。尾段未读或处理缺口必须显式记录；模板不能绕过决定/建议区分、未定字段空值和来源引用。字段结构合法不证明模型确实阅读全文，C05 还需用实际输入传递/分页读取证据核对覆盖，不能只信模型自行列出的已读 ID。取消或失败不覆盖已有成功版本。

P1 导图提案：一个根节点，节点 ID 全图唯一、无环，children 构成单父树；最多 12 层、1,000 节点、单节点正文 8,000 字符。超过边界拒绝正式导图提交，可保留安全文字降级。Markdown 与 Mermaid 为导出提案，格式随 D03 评审确认，不阻塞 P0。

## Reminder 写入、回执与恢复

新确认服务用精确 listID；失效、只读、无权限或未明确选择时失败，禁止回退另一列表。现有 CLI `--list` 名称要求唯一全名匹配；`--list-id` 和独立 `--alarm` 是后续参数提案，待 D05/C00 通过后统一接入，不能把当前工具宣称为已支持。

due 提案为 `{date: YYYY-MM-DD, time: HH:mm|null, timezone: IANA}`，纯日期不隐式变成午夜通知；新增有时间 due 在所选时区为不存在/重复的本地时间时拒绝，供用户改选无歧义值，不依赖自动归一化。alarm 独立为 `{at: RFC3339, timezone: IANA}` 或 null。相对日期先依据录音发生时间/时区解释并显示确认，不能按生成当天猜。复杂重复/位置/多 alarm 在不支持时诚实拒绝或保留既有字段，禁止部分降级后声称全部成功。已有事项的 IANA、offset 或 floating 设置按实际值读取，不能为采用新确认输入格式而改写。

回执来自保存后的 EventKit 对象：reminderID、title、listID/listName/account、实际 due components/timezone、实际 alarms、confirmationID。没有 absolute 或 relative 时间 alarm 不能宣称“已设置定时提醒”；位置 alarm 单独说明。存在设置也不能宣称通知已到达。既有 CLI 回执可增补读取字段，保留旧字段兼容。

确认主路径为 `confirmed → saving → saved`；完整状态与允许转换以 Reminder 附录为准，包括 prepared、failedBeforeSave、savedWithDifferences、needsReconciliation、cancelled。UI 与 Agent 必须经过同一写入服务，按 confirmationID 持有独占锁，并以当前状态/版本作 compare-and-set 预留，跨进程调用也不得绕过预留。原子写文件本身不能防止两个执行者各创建一次。预留成功后，先持久保存已确认 payloadHash 和 saving 意图，再调用 EventKit；保存成功读取实际对象，再写关联和回执。保存已有对象但要求有差异仍属于已创建，不能当失败再建。任何 saving 后中断/无法读取回执均为 needsReconciliation；未尝试保存的失败才可重试。

来源标记提案为系统事项 URL `voicecontext://recording/<recordingID>?confirmation=<confirmationID>`，Dev 使用现有 `voicecontext-dev` scheme；保留用户已有 notes 和 URL。新事项 URL 未占用时才采用此载体；如用户已有 URL，需选择经说明并确认的其他标记载体，否则保存前失败，不静默覆盖。URL 可被用户编辑，只是查找线索，不能替代私有确认日志或作为写入授权凭证。

同一确认重试先查映射，再核对完整成功查询中的同一标记与真实对象。一个标记多对象、权限不足、读取失败都转 needsReconciliation；saving 后零匹配也不自动补建，因为未保存、外部删除或用户修改标记无法据此区分。已 saved 的确认身份持续保留，系统事项删除不使它回到可创建状态。只有用户明确另建才生成新 actionID 和 confirmationID。

EventKit 的 calendarItemIdentifier 在完整同步后可能变化，单次按 ID 读取失败不等于系统事项已删除；恢复须核对完整查询与来源标记，必要时修复映射。无法确定时保持待核实。[Apple 标识说明](https://developer.apple.com/documentation/eventkit/ekcalendaritem/calendaritemidentifier)

写入 due/start 使用 Gregorian calendar；iOS 有 due 时必须同时有 start。新写入采用所选时区；实际读取允许 nil/floating 或固定 offset，不强制将系统已有值补成 IANA 时区。无日期回执保持 null。[Apple 日期组件约束](https://developer.apple.com/documentation/eventkit/ekreminder/duedatecomponents)

外部刷新读 EventKit，读取状态统一为 available/deleted/unreadable/permissionDenied/identityUnresolved；完成由 available 对象的实际 isCompleted 字段表达，不作为独立读取状态。不可读、权限变化和单次 ID 失效不等于 deleted。本地映射仅保存 ID 与来源，不缓存第二套完成状态。未确认/未选择候选为零写入，取消确认也是零写入。批量逐项记状态，saved 项不参与重试。

## 删除与保留提案

提案默认删除整条录音及全部受管原文、历史校对/候选、输入快照、公开 Meetings 文稿、Daily 对应条目、Agent Source；派生结果默认删除，确认页可显式改为保留摘要/导图。保留派生结果不能保留原文附件/完整摘录或不可变输入快照；保留结果标记来源已删除。系统提醒事项保留。

删除必须先写私有 tombstone 并撤销来源提交，再取消相关任务、逐对象清理、重建 Daily、清理共享副本。墓碑提交与文稿/公开副本/AI 正式发布共享同一提交排斥边界；仅在写前检查、再跨 actor await 写入仍不足以防竞态。墓碑清理完成后继续阻止同 recordingID 提交；恢复时先执行未完成清理，再准备桥接。失败逐对象记录，部分失败不报告全成功；单删和批删共用同一规则。旧残留按 canonical recordingID 核对，不按文件存在推断来源仍有效。

音频到期遵守已有 7 天规则，只清音频、不清文稿/产物/系统事项；不新增自动延期。删除记录保留最小 ID/进度/策略，不保存文稿正文或凭据。对第三方已导出文件不承诺撤回。

## 验收与冻结条件

冻结前核对 D01/D02/D04/D05/D06：采纳布局、发送范围说明、派生结果默认策略与本机保存边界。技术评审核对实际 Agent run 接口、EventKit URL 标记、跨进程权限、路径边界及失败恢复；契约冻结记录批准版本和差异，不修改已保存的 PRD 快照 hash 来伪装同步。

实施回归必须用真实服务的纯业务入口和可控替身，覆盖 F01-AC01–04、F02-AC01–04、F03-AC01–04、F05-AC01–03、F06-AC01–04、F07-AC01–03、F08-AC01–06、COMMON-AC01。P1 F04-AC01–03 的树 schema、引用与导出语义单列，待导图实现后补结构/阅读证据；不阻塞 P0。静态编译、主机逻辑测试、真机运行/通知观察分别记证据；F07-AC04 与 T06/T07 没有本次真机授权不得执行。

本稿配套 [机器 schema、测试向量与参考校验](recording-ai-actions-schema/README.md)。它们仍是待评审材料，不是生产解码器或已冻结格式；参考产物入口已组合严格输入/真实运行观察/结构文件与 renderer fixture，完整 request 状态与原子提交、实际存储迁移/渲染器、复杂 recurrence 的完整 wire、真实 Swift/Objective-C 服务接入与中断恢复尚需完成。结构/业务向量通过不能代替流程批准、C00 冻结或后续 C/T 任务验收。
