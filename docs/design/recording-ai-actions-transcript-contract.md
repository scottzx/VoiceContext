# 文稿契约评审附录：现有版本、完整性与撤销边界

日期：2026-10-03。状态：**待评审；未冻结，未发布新 schema**。本附录只补 [C00 评审稿](recording-ai-actions-contract.md) 尚未具体化的文稿规则；不另建录音、聊天或任务状态机，不修改生产代码。

依据：[PRD](../PRD-recording-ai-actions.md) F01/F02/F08、[交付清单](recording-ai-actions-delivery.md) C00/C01/C02/C03/C12，以及当前工作树的实际实现。[现有产品基线](recording-ai-actions-existing-product.md) 已说明整体导航，本附录只列文稿契约的接入点。新交互须先得到 D01/D02/D06 评审结论；字段与目录在 C00 冻结时再确认。

## 1. 现有实现与最小接入点

| 现有入口或服务 | 可直接复用 | 必须补齐的边界 |
|---|---|---|
| `RecordingDetailScreen.topBarTrailingMenu` 与两处失败重试提示 | 三处均调用 `retryTranscription`；保留四个内容 Tab、底部播放器、原有返回路径 | 接入同一预检计划与候选查看，不再分别定义重转写语义；本轮后端通知尚不是可比较、可采纳的候选 |
| `EditSegmentTextSheet` / `saveSingleSegmentText` | 保存失败时保留 `textInput`，显示错误且不关闭；store 内合并最新文稿，旧 ID 消失会明确冲突 | 候选比较仍用当前保存版本；用户再次校对后原候选失效或重新比较，不能把旧输入默认为已保存 |
| 逐字稿进度区、失败任务提示、空稿占位 | 已基于持久 jobs 与文稿显示排队/失败；捕获与处理已有分离模型 | 在现有区域加入内容完整性及原因，不能把 job 数量或 recording.state 当完整性证据 |
| 时间定位、`scrollToSegmentID`、`RecordingAudioTimelinePlayer` | 使用既有 segment ID、样本范围与回听控制 | 引用先定位固定版本；只有来源范围仍可核对时回听。旧 ID 在新版不存在不能跳到相似句冒充原引用 |
| `TranscriptionCenter` 的单任务/失败项重试 | 复用 `retryTranscriptionJob`、`retryRecordingProcessing` 与现有 scheduler | 这些路径尚未共享本轮整条重转写预检；C01 必须覆盖它们，继续使用原队列，不另起调度器 |
| 「交给智能体」→现有聊天草稿 | 配置检查、桥接、`.newChatRequested` 和用户发送均已存在 | 草稿创建时准备固定输入，绑定真正 run/session；刷新 Source 不能改变已准备输入 |
| 「智能体产物」→`RecordingAgentResults` | 保留现有 Sheet、刷新、QuickLook、UUID/路径安全检查 | 正式项从已提交 manifest 读取；原目录文件继续作为历史文件查看，不能由文件存在推出已完成 |

当前代码来源：[详情与编辑](../../speech_note/speech_note/Features/Recording/RecordingDetailView.swift)、[CoreModel](../../speech_note/speech_note/Features/Recording/RecordingCoreModel.swift)、[文稿/store](../../speech_note/speech_note/Features/Documents/TranscriptDocumentV1.swift)、[桥接](../../Integration/App/MeetingWorkspaceBridge.swift)、[Agent 入口](../../Integration/App/VoiceContextRootView.swift)、[产物入口](../../Integration/App/RecordingAgentResults.swift)。当前主目录与工作树存在页面漂移，接入前按现有产品基线重新核对，不将旧截图作为生产布局证据。

现有编辑文案承诺「永久锁定防覆盖」，但没有旧稿恢复/候选采纳能力；不得把本轮保护修复解释为已实现这套交互。现有「已校对」徽标使用蓝色，与 [DESIGN.md](../../DESIGN.md) 蓝色仅用于系统/外部链接的规则不符，列入 UI 走查项，本附录不改样式。

## 2. 尚未覆盖的 requirement

| requirement | 已有事实 | 未覆盖部分与归口 |
|---|---|---|
| F01-AC01 / C01 | 已保存人工文字、旧 ID/来源范围受保护；用户保存、ASR 与最终化合并最新稿 | 成功重转写仍自动更新目标未校对段；无持久候选、比较/采纳、显式整份替换后的可恢复历史。不能声称 AC01 完整通过 |
| F01-AC02 / C01 | 整条重转写先核对真实长度并执行范围解码；全不可读不清稿，部分可读只排对应来源 | 预检只有临时 Plan 和计数通知，未持久保存实际范围/具体原因，单任务重试尚未统一接入 |
| F01-AC03 / C02 | 处理队列可以结束；显式预检不可用任务保留 failed | 普通 `unreadableAudioSkipped` 仍可终结为 completed；无结构化静音/有声空识别/缺口证据，公开文稿与 AI 输入未携带完整性 |
| F01-AC04 / C01 | 空/失败结果不清旧稿；部分成功只替换实际非空覆盖，保留非目标、校对、跨范围旧段 | 候选采纳后的范围映射、历史恢复与证据更新尚未定义和实现；现有保护是前置修复 |
| F02-AC01 / C03 | Source 独立副本和 canonical revision 已存在 | Source 随刷新覆盖；草稿只有 recordingID 提示，没有绑定实际 bytes/hash/完整性/选定范围 |
| F02-AC02/04 / C03 | 产物入口已有 UUID、符号链接与目录边界检查 | 无权威 request/manifest、验证提交与恢复；任何安全路径内文件仍可被列为产物 |
| F02-AC03 / C03/C04 | 融合 Skill、公开纪要 Skill、用户模板及旧 generated 路径可读 | 统一输入/输出适配与历史索引尚未实现；旧 Skill 的 `state=complete` 门槛没有内容完整性语义 |
| F08-AC02/03/06 / C12 | 有单删/批删、公开副本、Daily 与 bridge 文件清单 | 无持久 tombstone、统一提交排斥和逐对象恢复；跨 actor 检查后 await 仍存在删除竞态，历史/候选/输入也待纳入 |

本轮已执行的 9 组主机回归仅证明保护修复，详见 [开发验证记录](../testing/recording-ai-actions-development-2026-10-03.md)；不代替 C00 冻结、C02/C03/C12 或真机验收。

## 3. 样本范围与判定域

沿用 Transcript@1 的录音级 16 kHz 样本坐标和半开范围 `[startSample, endSample)`。微录音 chunk 的解码坐标从文件 0 开始，提交与引用必须换回 `chunk.startSample` 起的录音坐标；导入文件按现有 asset/range 坐标解码。不得混用墙钟时间、毫秒、源文件采样率和 16 kHz 范围。

范围标识提案为 `{sourceKind, sourceID, startSample, endSample}`；导入任务另保留既有 `processingRangeID`，执行证据保留 `jobID`/attempt 标识。一个 imported asset 可有多个任务范围，不能仅按 assetID 判定“整份已重试”。跨 chunk 的段落保留全部 `sourceRanges`，段落最小/最大样本的包络不证明中间都已读取。

每份完整性快照明确判定域：

- `scope=recording`：repository 中本次已知输入来源及捕获缺口；`domainFinalized` 只有捕获已终止、来源清单和缺口已核对才为 true。捕获中只说明已知前缀，不能对未来内容承诺完整。
- `scope=selection`：本请求实际所选 segmentIDs 及其范围；另保留录音级结论与选区关联警告。选区完整不能把整条录音标签变成完整，完整录音也不证明模型读过全部选区。
- `expectedRanges` 是声明应处理的范围，`observedRanges` 是有持久解码/VAD/ASR 证据的范围；二者均按同一来源身份分区、排序、去重。不按最后一句时间或完成 job 数量补齐覆盖。

`RecordingGap` 的 `userPause` 表示用户主动未录，不能宣称该时间有原文，也不自动当损坏；仍供纪要说明录音范围。systemInterruption/writeFailure 等保留原原因。缺口 `endSample=null` 或点事件不能扩写为精确时长，应记录未知边界。

旧 `source_chunk_id` 缺 `end_sample` 会解码为零长度定位点；继续支持阅读、保守保护和回听起点，不将它扩成“到下句/片尾”的已覆盖范围。新证据范围要求非负且 `end > start`；旧点只存为 `legacyAnchors`，不能通过严格范围校验后贡献完整性。

## 4. 完整性伴随对象提案

沿用 C00 的 `voice-context/recording-ai@1` 对象族。建议增加 `objectKind=transcriptEvidence` 的私有伴随对象，公开文稿导出脱敏、同版本的完整性副本；不把新字段设为 Transcript@1 必填，不把 repository jobs 迁成第二套任务表。目录/编码命名尚待冻结。

| 字段 | 提案类型 / 规则 |
|---|---|
| schema / objectKind | 固定字符串；严格区分 evidence、candidate、version、deletion 对象 |
| source | C00 的 recordingID/revision/sha256，精确对应保存的 canonical 原始 UTF-8 bytes；不以重新编码替代 |
| evidenceID / createdAt | UUID / RFC3339；同一证据对象不可原地修改，后续产生新证据对象 |
| scope / domainFinalized | recording 或 selection / Bool；selection 另含实际 selectedSegmentIDs |
| processingState | 沿用 capturing/processing/terminal，从既有 capture/jobs 投影，不能替代原录音状态 |
| contentState | complete/partial/unknown，按下述证据规则推导，不由模型自行声明 |
| expectedRanges / observedRanges | 来源身份及 16 kHz 范围；observed row 另含 outcome、jobID/attemptID、segmentIDs、reasonCode、证据字段 |
| evidence | decode 覆盖边界、VAD 是否成功及检测到的 speech ranges、ASR 是否执行/成功；只留统计与范围，不留 PCM/embedding/凭据 |
| captureGaps / legacyAnchors / warnings | 原缺口原因/可空终点、旧定位点、明确未知项；不把 warning 文案当机器状态 |
| audioAvailability | checkedAt 及逐来源 available/expired/missing/unreadable/unknown；是当前回听/重试能力，独立于历史文本完整性 |

主稿 outcome 需补一个通用 `failed`，并以 `stage=decode/vad/utterance/asr` + reasonCode 表达失败位置；现有列表不能将模型运行错误塞入 silence。各 outcome 的最低证据：

| outcome | 最低证据与覆盖效果 |
|---|---|
| transcribed | 全部声明处理范围真实解码，VAD 成功，该范围内全部应识别的 speech spans 有非空 ASR 文本；segment 范围不能独自证明整窗完成，人工补文另保留 provenance |
| silence | 全范围真实解码、VAD 成功且未检测到语音。含义是“未检测到语音”，不承诺物理无声音；检测器版本/配置可追溯 |
| voicedEmpty | 有有效 speech spans、ASR 确实执行并完成，但该语音范围无可采用文字；不能视作正常静音或完整 |
| unreadable / missing | 分别有解码失败或来源确实缺失的证据；保留实际范围与原因，不伪造文本 |
| failed | VAD、utterance 构造或 ASR 失败，保留 stage/reason；已有语音但未执行 ASR 不伪装成“ASR 空结果” |
| interrupted / pending | 处理被中断或尚未处理，不能贡献已完成覆盖；捕获中断另见 captureGaps |

当前 `SpeechAnalysisService.noSpeechDetected` 同时用于无 VAD spans 和有 spans 但无可用 utterances；`SenseVoice.isSkippableEmptyChunk` 同时含 emptyTranscript/unreadableAudio。因此迁移时不能仅用错误名字反推 silence，必须在相应阶段持久保存证据。相关源码：[语音分析](../../speech_note/speech_note/Features/Transcription/SpeechAnalysisService.swift)、[推理错误](../../speech_note/speech_note/Infrastructure/Inference/SenseVoiceInferenceService.swift)、[普通不可读终结](../../speech_note/speech_note/Features/Transcription/CompletionReconciler.swift)。

判定顺序提案：有确定未覆盖、失败、voicedEmpty 或不可恢复捕获缺口为 `partial`，即使另有未知项也同时保留 warnings；没有已知缺口但判定域未闭合、范围/阶段证据不足则为 `unknown`；只有闭合判定域全部由 transcribed/silence 证据覆盖、没有未处理语音及未知边界才为 `complete`。`terminal + partial/unknown` 仍允许用户主动整理已有文字，标签依据 D01/D02，不永久阻断。

音频在有充分转写证据之后到期，不倒退历史文本完整性；availability 变为 expired。未处理范围的音频已清理则是不可恢复缺口；旧数据只有文字而无证据仍为 unknown，不能靠“曾经到期前可读”补齐。人工补文可以标记已提供文字与不确定性，不能替代缺失音频的解码/VAD 证据。

## 5. 校对版本与候选采纳提案

保持现有 canonical `Transcripts/<recordingID>.json` 为当前阅读权威，`TranscriptDocumentStore.update` 为原子文字合并入口。新对象仅在现有 store/任务链旁保存版本与候选，不重建原捕获/排队状态。

| 对象 | 最小新增字段与规则 |
|---|---|
| transcriptVersion | versionID、source、canonicalPath、createdAt、reason、parentSource（可空）。存原始 JSON bytes，按 recordingID/revision/hash 去重；旧 Markdown 由该版本生成，不混读另一版公开副本 |
| transcriptionCandidate | candidateID、attemptID、baseSource、requestedScopes、actuallyProcessedScopes、evidenceID、drafts、status、createdAt、failure（可空）。draft 保留来源/范围和候选身份，不默认取得 canonical segment ID 或人工校对标记 |
| adoption | adoptionID、candidateID、expectedCurrentSource、mode、每段/范围选择、createdAt、resultSource（提交后）。mode 为保留校对的合并或显式整份替换；选择是用户实际所见候选的快照 |

candidate 状态仅表示该次重识别结果：running → ready 或 failed/cancelled/interrupted；ready → adopted/discarded。ready 只表示存在可比较的内容，部分成功仍可 ready 并携带缺口，不等于全部范围成功。复用 jobID/执行 lease 防迟到结果加入错误 attempt。候选本身不修改 canonical state/revision/文字；原始捕获与增量转写仍沿用既有投影语义，候选进度从本次 jobs 展示。

采纳在同一文稿提交入口核对 `expectedCurrentSource` 的 revision 与 hash，并检查 tombstone/执行身份。任何用户校对、元信息/说话人修改或增量 ASR 使当前版本改变，返回冲突，保留编辑输入与候选；重新比较才生成新 adoption，不自动强写。不因当前文字“看起来一样”绕过完整来源核对。

默认合并只采纳完整属于选定目标范围、能稳定映射且未校对的内容。未选范围、校对段、跨目标边界的不可拆旧段保持原 ID/sourceRanges；无法映射的段明确待核对。精确来源与样本范围相同才可沿用原 ID，校对 provenance 不继承给新 ASR；整份替换须明确包含校对影响，先保存可恢复旧版本，再提交新 canonical。空/失败候选不能成为“清空文稿”的采纳。

版本写入先于 canonical 替换，canonical JSON 原子替换是当前文字的提交点。候选/历史/证据都绑定来源 hash；单个 Markdown 或 sidecar 原子写入不等于多文件事务完成。重启处理未引用候选/暂存，不将它们当已采纳；恢复旧版本也走 compare-and-set 并产生新的当前 revision，不能把 revision 倒退。

现有 revision 会在处理状态、音频可用性、说话人及元信息等变更时递增，不只是文字采纳。本轮不得重新定义其含义或把旧 revision 重编号；以现有 revision + bytes hash 绑定来源。历史留存的最小保证是重转写开始前和任何显式替换前保存旧稿，以及请求所用版本；是否保存每次校对/状态变化的全部历史、容量与清理策略另行评审，不默认无限存档。

## 6. 固定输入与证据一致性

C00 的两个摘要继续独立：source.sha256 核对完整 canonical 原始 bytes，inputSha256 核对实际所选输入 bytes。模型输入不得包含未选正文；私有历史版本可以含完整旧稿，但属于受管原文，删除时必须清理。

建议新增 store 的只读 `prepareInput` 业务入口：在 actor 内一次读取 canonical bytes、解析身份及当前匹配的 evidence；制作仅所选文字/范围/明确元数据与模板的输入，将 source tuple、evidenceID/其摘要、inputSha256 放入私有 request。若 sidecar 的 source tuple 不匹配，不能拼接成已知完整；返回 unknown 的明确证据缺失说明或重新生成一致证据。request 原子提交后才交给现有聊天草稿。

JSON 和 Markdown 当前分别原子写入，Meetings/Daily/Source 又独立刷新，不能作为“同一次读”的组合源。AI 单次运行只读 approved request 的固定输入；分页读取、恢复和最后引用校验均使用相同 input hash。共享 Requests 是工作副本，正式提交核对私有输入，Source 仍承担旧浏览/Skill 兼容用途。

录音级完整性和选区完整性分开保存；公开选区输入仅带选区关联缺口及整条来源的结论摘要，不附带其他段落、说话人敏感资料或未选内容。生成 coverage 另记录 `selected/read/cited/missing segmentIDs`，全部在请求快照内核对；“输入完整”不能证明模型读取尾段。读过与未读来自适配器/运行记录，无法验证时标未知，不能相信模型单方声称覆盖。

## 7. 音频预检契约

[现有预检](../../speech_note/speech_note/Features/Transcription/TranscriptionRetryPreflight.swift) 已拒绝超过 `AVAudioFile.length / sampleRate` 的范围，并执行该范围解码；解码器补零不能充当实际覆盖。它是当前范围的可用性探测，不保证推理一定成功、文件今后可读或历史正文完整。

建议 Plan 补 `planID/baseSource/checkedAt/requestedScopes/readableScopes/unavailableScopes`。每个 unavailable row 明确 expired、missing、truncated、decodeFailed、sourceNotClosed 或 unknown 原因；每个 readable row 保存来源 ID、声明/真实长度、解码边界及文件身份核对值，不含音频正文。chunk 使用绝对提交范围与相对解码范围；导入来源使用 assetID + processingRangeID。

整个声明范围可读才进入本次可执行范围；60 秒声明仅剩 10 秒不能靠 padding 排成 60 秒可读。若产品要利用可读前缀，应产生新的明确子范围计划，而非静默裁切；当前实现保守拒绝整个不完整任务范围。实际执行仍重新解码、验证来源存在/lease，并按成功处理范围写 evidence，不能从旧 Plan 推断最终成功。

全部来源的 pending/failed 行须在首次 drain 前登记，沿用本轮 repository reset 与一次挂齐 callbacks 的实现。预检不更改现有 7 天期限或长期保留设置；删除整条录音的撤销优先于任何计划。所有既有重试入口后续使用同一计划与候选服务，错误继续经现有 notice/Sheet 呈现。

## 8. 删除墓碑与提交排斥

C00 已规定删除范围，本节补并发保障。建议 `objectKind=deletion` 的私有持久 tombstone 最少包含 recordingID、deletionID、startedAt、policy、state、objects；不含文稿正文、摘录、音频、凭据。recordingID 不复用；墓碑即使清理完成也保持来源不可提交，不因目录消失或用户选保留派生物而移除。

| 字段 | 提案规则 |
|---|---|
| policy | raw=delete、derived=delete 或保留经用户选择的类型、systemItems=keep；默认派生策略仍待 D06 |
| state | deleting/completed；部分失败仍为 deleting，不能报告删除全部成功 |
| objects[] | 受管类型/安全相对 locator、pending/deleted/kept/failed、attempts、lastErrorCode、updatedAt、retryAt（可空）；Daily 使用重建状态而非删除其他录音的整天文件 |

每条录音只有一个提交排斥边界，tombstone 持久化和 ASR/store、候选采纳、输入准备、公开发布、bridge、AI 正式提交按该边界串行。核对后跨 actor await 再写仍会竞态；实现必须令“核对仍有效 + 发布/替换”与“墓碑提交”互斥，不能靠多次检查掩盖 TOCTOU。复用既有执行 lease、store actor 与文件锁能力实现最小协调；Agent 只能写暂存，不能自行发布私有 manifest。跨进程写入若参与正式发布，必须同样经过协调。

写墓碑后先撤销输入/公开来源资格，再停止相关生产者并清理 canonical、音频、版本、候选、request 输入、公开 Meetings/Daily、Source、受管生成物、索引和可重建缓存。已有可选 iCloud 公开镜像也在受管清单中，失败保留进度；本附录不新增历史/请求上云。保留派生物时清除整份原文附件/输入/历史及引用全文，只保留经确认的摘要/导图和失效来源标识。

桥接与启动恢复先查私有墓碑与活的 repository/canonical 清单，再枚举公开目录；`source-files.json` 只是副本清单，不能撤销 tombstone 或授权旧残留重新桥接。删除中未能停止的生产者应记待清理失败，不能宣布完成；迟到暂存可清理但不得恢复 Source/正式产物。对已发送给外部服务或用户自行导出的数据不承诺撤回，系统事项继续按 C00 保留。

## 9. 兼容迁移与冻结前验证

| 旧数据或流程 | 提案迁移规则 |
|---|---|
| Transcript@1 无 evidence | 保持原文件可读；完整性 unknown。可从持久、可核对的 job/source 证据导入已知失败，但成功状态 alone 不补完整 |
| 旧人工标记缺失 | 当前 decoder 默认 false 仅为兼容行为，不证明从未校对；历史 provenance 标 unknown，不批量标记“机器原稿”。无法稳定核对的替换需人工选择 |
| legacy 零长度来源、任意旧 segment ID | 保留原 ID/点和旧双写字段；不生成虚构终点、不重算 ID、不伪装整段覆盖 |
| 现有较新未校对稿的自动增量合并 | 保持当前行为作为可靠性基线；完整候选流程获批后按一次迁移接入，不能让部分入口走候选、其他入口悄悄自动替换 |
| 无 manifest 的 Generated / 旧会议 generated | 独立历史索引，来源不明保持未知；头部 recordingID/revision 可核对也不伪造 hash、run 成功或完成状态 |
| 公开 Skill 与用户模板 | 新适配器接受固定输入/evidence、写受管暂存并索引结果；保留旧只读调用。迁移不可覆盖用户 Skill/模板；Markdown fallback 的 `gaps=[]` 不视作完整性证据 |
| 重复迁移/中断恢复 | 按 recordingID/revision/hash 与候选/请求 ID 去重；先 tombstone 再恢复；不改原文 bytes 以匹配预设摘要 |

冻结前需补可控主机回归：完整域的 silence、voicedEmpty、failed 与混合缺口；旧 complete/gaps=[] → unknown；旧点不能贡献覆盖；音频到期不抹去既有完整证据；选区与整条判定分离；校对后候选 CAS 冲突、显式替换可恢复且 revision 单调；JSON/Markdown/sidecar 漂移不能混读；分页尾段 coverage；生成中断无正式项；双删/迟到回调/重启墓碑与失败恢复；保留派生结果仍清全量原文副本。分别对应 T01/T02，不把文档例子算作测试通过。

待 Human 决定的仍是现有入口上的预检/比较呈现、逐段与整份采纳布局、历史容量/保留说明、派生默认删除策略；待技术评审的是 evidence 来源与持久时机、sidecar 与 canonical 一致读取、范围映射、共享生产者停止和跨进程提交互斥。批准后记录 C00 版本/差异再实施，本附录不产生冻结或完成状态。
