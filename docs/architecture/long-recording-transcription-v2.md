# 长录音可靠转写与多人对话处理 v2 设计文档

## 文档信息

- 状态：P0–P2 已实现，定向真机测试已通过；一小时真实多人样本验收待完成
- Owner：Human product owner / Agent implementation
- 来源需求：复用 `#4`（本地 VAD、SenseVoice 与调度）、`#6`（说话人聚类）、`#49`（端到端稳定性验收）；本轮真机缺陷待 PM 看板服务恢复后补建 bug
- 对应功能模块：录音与本地数据 / 恢复与处理生命周期；本地语音智能 / SenseVoice 调度与说话人分离；开放文档与产品体验 / 处理状态
- 继承设计：`DESIGN.md`、`docs/architecture/recording-core.md`、`docs/architecture/incremental-transcription.md`
- 最后更新：2026-08-24

## 背景与问题

项目当前在 iPhone 15 Pro / iOS 26.5 使用 SenseVoice Small Q8_0、Silero VAD 和 CAM++。既有真机长录音表明，健康流水线处理一分钟音频约需 7.7–9.0 秒；但 2026-08-23 至 2026-08-24 的一次 51 分 48 秒真机样本恢复处理中，剩余 33 分 48 秒音频耗时 39 分 38 秒，约为每分钟音频 70.4 秒。

这次异常不是单纯的 ASR 模型速度问题，真机 journal 和容器快照显示：

- 恢复启动期间，同一批任务出现 `running → recovered pending` 竞态，后续多个任务的 running 区间相互重叠；
- 调度器只把 `recordingID` 交给执行器，执行器再查询“最后一个 running job”，执行目标并非由不可变 job 身份绑定；
- 每个 60 秒分片完成 ASR 后，都会读取整场说话人观察、从头全局聚类、重写文稿和说话人绑定，成本随会议增长；
- 52 个转写 job 已全部 completed，但 Recording 和 Transcript 仍停留在 processing，说明完成状态依赖易丢失的回调而没有权威对账；
- 当前 VAD 停顿边界同时影响 ASR utterance 与说话人窗口，多人对话中的停顿、换人和短暂插话没有独立建模。

目标场景已经明确：甲乙方需求沟通、访谈和有秩序的讨论为主，通常 2–6 人；轮流发言占主导，短暂插话常见，长时间重叠语音较少。

## 目标

- 任意时刻全局最多只有一个已获有效 lease 的转写执行；旧执行在取消、后台或恢复后不得提交迟到结果。
- App 进入后台、被系统终止或重新启动后，closed chunk / ProcessingRange 最终一定重新排队，不丢、不重、不永久卡在 processing。
- Recording、jobs 和 Transcript 的完成态可由持久化事实自动对账，不依赖某个内存回调恰好执行。
- 60 秒热路径只完成局部 VAD、ASR、embedding 和增量提交；全场说话人聚类与身份绑定改为录音结束后的独立最终化阶段。
- 建立可持久化的分阶段性能指标，能分别回答解码、VAD、ASR、embedding、文档提交和说话人最终化各耗时多少。
- 在可靠性与性能恢复后，引入适合 2–6 人的独立 speaker segmentation，并将其结果与 ASR 时间轴对齐。
- iOS 26+ 可选使用 continued background processing；iOS 18–25 保持“后台录音、前台推理”的可靠回退。

## 不做

- 本轮不替换 SenseVoice，不训练新的 ASR 或多人模型。
- 不实现单麦克风的多路语音分离；短暂重叠无法可靠归属时允许标记为重叠或未知。
- 不要求用户输入准确参与人数；2–6 人是聚类先验和验收范围，不是硬编码 speaker count。
- 不为了后台转写而滥用 audio background mode，也不承诺系统在所有温度、电量和资源条件下持续执行。
- 不自动重写全部历史转录；旧文档继续可读，用户主动重处理时才升级到新 pipeline version。
- 不在本设计阶段制作新原型或改变既有视觉风格。

## 用户、场景或调用方

### 核心用户场景

- 2–6 人的甲乙方需求沟通、访谈、培训交流与有秩序的讨论。
- A 说完后 B 回答，或 B 用一句短话插入后 A 继续；真正同时长时间说话较少。
- 用户录完即离开 App，稍后回来仍期望文稿自动补齐并显示真实状态。
- 用户更在意音频和文字不丢，其次才是实时出现说话人标签。

### 系统调用方

- Capture 只生产权威 AudioChunk，不等待任何推理。
- Transcription scheduler 消费 AudioChunk / ProcessingRange，并持有唯一执行 lease。
- Transcript commit 层提交增量文字和局部观察。
- Speaker finalizer 在全部 ASR 完成后消费整场观察或原音频，生成最终 speaker turns。
- UI 只读取持久化进度投影，不自行推断完成状态。

## 产品流程 / 信息架构

```text
用户开始录音
  → 后台可持续保存 60 秒 AudioChunk
  → 前台调度器原子领取一个 TranscriptionJob lease
  → Decode → VAD → SenseVoice → 局部 embedding
  → 原子提交该分片文字、观察与阶段指标
  → job completed，领取下一项
用户停止录音
  → 最后 AudioChunk 关闭并入队，立即释放麦克风
全部 canonical transcription jobs completed
  → 创建一个 SpeakerFinalizationJob
  → speaker segmentation / 全场聚类 / 时间轴对齐
  → 一次性写入最终 speaker turns 和身份候选
  → CompletionReconciler 将 Recording 与 Transcript 收口为 complete
```

用户可见阶段限定为：

1. `正在转写 · 已完成 N/M`；
2. `正在整理说话人`；
3. `待回到前台后继续`、`后台转写中` 或明确失败原因；
4. `已完成`。

内部 job、lease、重试次数和分片文件名只进入诊断界面，不出现在普通详情页。

## UI/UX 风格确认（原型前门禁）

- 状态：已确认并复用；本轮不需要新原型。
- 一句话记忆点：录音不会丢，文字可以稍后追上，处理状态永远诚实。
- 风格关键词：安静、原生、精确、私密、耐用；反向关键词：伪实时、状态含糊、AI 炫技、装饰性进度。
- 原生与品牌：完整复用 `DESIGN.md` 的 quiet native utility，不新增品牌色或自定义视觉语言。
- 信息层级：正在录音 > 音频已安全保存 > 转写进度 > 说话人整理；处理状态不能覆盖停止入口。
- 视觉方向：沿用原生列表、状态文字和现有红/橙语义；后台系统链接才使用蓝色。
- 无障碍底线：VoiceOver 朗读阶段、已完成数、待处理数和是否需要回前台；状态不只靠颜色；动态字体下允许换行。
- 决策记录：继承 Human product owner 于 2026-08-03 批准的 `DESIGN.md`；本设计不偏离既有方向。
- 已确认：iOS 26 后台转写为设置页显式 opt-in，默认关闭；用户不授权时保持前台续跑与可恢复队列。

## 原型与 UI/UX

无需低保真或高保真原型。实现只更新既有状态矩阵和文案：

| 持久化事实 | 用户文案 | 允许操作 |
|---|---|---|
| 有 pending/running transcription job | 正在转写 · N/M | 稍后查看、停止全部处理 |
| ASR 完成、speaker finalization 未完成 | 正在整理说话人 | 阅读已有文字、稍后查看 |
| 后台且无 continued task | 音频已保存，转写待回到前台后继续 | 停止录音、返回 App |
| iOS 26 continued task 正在运行 | 后台转写中 · N/M | 查看系统进度、取消 |
| 有失败 job | 转写需要注意 · 已保留音频 | 重试、查看原因 |
| 所有 canonical jobs 完成且投影已对账 | 已完成 | 阅读、编辑、导出 |

不得因为 ASR job 全部完成但 speaker finalization 仍在运行而显示“已完成”；也不得因为 speaker finalization 失败而隐藏已成功产生的文字。

## 技术方案

### 1. 不可破坏的系统不变量

1. 全局最多一个有效 `JobExecutionLease` 可以进入 SenseVoice / Metal。
2. 执行器接收不可变的 job target，禁止通过 `recordingID` 二次查询“某个 running job”。
3. 所有结果提交必须验证 `jobID + executionToken + pipelineVersion`；失效 lease 的迟到结果只能丢弃。
4. job 状态由 scheduler 单点写入；执行器不得自行选择或改写其他 job。
5. Recording/Transcript complete 是持久化事实的投影，不依赖 outcome handler 是否仍在内存。
6. 说话人最终化失败不能回滚或删除已完成 ASR 文字。

### 2. 原子领取与执行 lease

将 scheduler executor 从：

```text
execute(recordingID)
```

改为：

```text
execute(JobExecutionLease(jobID, recordingID, sourceTarget, executionToken, pipelineVersion))
```

`sourceTarget` 必须在领取时固定为 `audioChunk(chunkID)` 或 `processingRange(rangeID)`。Repository 通过单个事务执行 compare-and-swap：

- 当前 job 必须仍是 pending；
- 数据库中不存在另一个有效 running transcription job；
- 成功后写入 running、attempt count、execution token 和 started time；
- 更新行数不是 1 时，调用方不执行模型。

数据库增加全局 running guard 或等价事务约束，防止多个 `RecordingCoreModel`、恢复任务或未来后台 task 同时领取。

进入后台、expiration、用户停止或冷启动恢复时，scheduler 使当前 token 失效并等待旧 drain 真正退出；只有旧执行已不可提交后才允许新 drain。旧 task 即使晚返回，也无法写文稿或把 job 标 completed。

### 3. 启动恢复屏障

冷启动按固定顺序执行：

```text
关闭 scheduler admission
  → replay journal / repair index
  → 将无有效 lease 的 running job 原子恢复为 pending
  → 按稳定 target key 去重 canonical jobs
  → 对账 Recording / Transcript 投影
  → 注册 outcome observer
  → 打开 admission，只启动一个 drain generation
```

恢复期间，创建缺失历史 job 只能写 pending，不得隐式启动 drain。`resumePendingJobs` 不再与 enqueue/backfill 并发启动模型。

### 4. 文字热路径与说话人最终化解耦

每个 60 秒 TranscriptionJob 只执行：

```text
局部解码 → Silero VAD → SenseVoice → utterance embedding
→ 幂等写入 segments / observations / attempt metrics
→ job completed
```

明确移出热路径：

- 整场 agglomerative reclustering；
- 整场 speaker-turn 重建；
- MeetingSpeakerBinding 全量生成；
- 因说话人变化触发的重复公共文档全量发布。

录音停止且全部 transcription jobs completed 后，只创建一个稳定的 `SpeakerFinalizationJob(recordingID, diarizationPipelineVersion)`。该任务读取整场观察或音频，执行一次全局说话人处理并提交一个最终 revision。

录音过程中如需临时说话人标签，只允许使用内存中的增量 centroid；它是 provisional UI，不作为最终身份事实，也不能阻塞文字提交。

### 5. 观察与绑定存储

将整场 `SpeakerObservations/<recording>.json` 的读改写改为私有 SQLite 行或按 chunk 分片的不可变记录。推荐 SQLite：

- observation ID 由 recording、绝对样本范围、模型和 pipeline version 稳定派生；
- embedding 使用定长 Float32 BLOB，不以 JSON 数组重复保存；
- 相同 observation 重试为 upsert，不追加重复值；
- 最终绑定只保存 speaker、证据 observation IDs、候选身份和置信信息，不复制全部 embedding。

公开 transcript JSON/Markdown 仍不包含原始声纹 embedding。

### 6. Transcript 提交与完成对账

增加单一 `TranscriptCommitCoordinator`：

- 串行处理 read-modify-write；
- 每次提交校验 execution lease；
- 以稳定 segment ID / source ranges 替换，不重复追加；
- 文稿写入、搜索索引和公共文档发布失败必须形成可重试的投影错误，不能使用 `try?` 静默吞掉；
- 公共 MD/JSON 与日时间线允许 debounce，但私有 canonical transcript 每个成功分片都要落盘。

`CompletionReconciler` 在每次 job 状态变化和冷启动后执行：

- capture 已结束且存在 pending/running transcription → processing；
- transcription 全完成但 speaker finalization 未完成 → processing / finalizingSpeakers；
- 所有 canonical jobs 完成 → Recording 与 Transcript complete；
- 任一必要 job failed → needsAttention，同时保留已完成文字；
- 投影文件缺失或状态落后 → 从数据库事实修复。

### 7. 独立 speaker segmentation

可靠性与性能达标后，再对以下候选做离线 benchmark：

- 基线：当前 Silero VAD + CAM++ + 一次性全局聚类；
- 首选候选：sherpa-onnx offline diarization，使用独立 speaker segmentation + 现有 CAM++ + 不固定人数聚类；
- 对照候选：支持目标设备的其他端到端 diarization；固定最多 4 人的模型不能作为覆盖 2–6 人场景的唯一正式方案。

ASR 与 diarization 分别产出时间轴：

- ASR utterance 保留文字与 source ranges；
- diarization 输出 speaker activity、turn boundary 和 overlap/unknown；
- 对齐器按时间重叠占比为 utterance 分配 speaker；
- 一个 utterance 被多位 speaker 显著覆盖时标记 mixed/unknown，不强行归属；
- 短插话优先保留文字，再追求说话人标签准确；
- 模型选择前不训练，先用真实 2–6 人评测集决定是否需要微调。

### 8. iOS 26 continued background processing

后台能力是可靠队列之上的执行策略，不是新的数据真相：

- iOS 26+ 且设备支持 GPU：用户选择后提交 `BGContinuedProcessingTask`，使用同一 lease、指标和 expiration 路径；
- expiration 或系统拒绝：当前 lease 失效，job 回 pending，音频和已完成文字不变；
- iOS 18–25：后台只录音和排队，回前台继续；
- 无论是否允许后台转写，都不得改变录音可靠性和最终可恢复性。

用户可在设置中显式选择“允许后台继续转写”，并可随时关闭。产品决策已确认默认关闭；不开启时，队列在回到 App 后自动恢复。

## 数据与接口

### RecordingJob 增量字段

- `pipeline_version`
- `execution_token`（pending/completed 时为空）
- `started_at`
- `termination_reason`

稳定 target 仍为 `chunkID` 或 `processingRangeID` 二选一。迁移时保留既有 job ID；重复 target 只保留 canonical job，其他记录为 superseded，不能直接物理删除审计历史。

### ProcessingAttempt

每次领取生成独立 attempt：

- `id`、`jobID`、`executionToken`、`pipelineVersion`
- `queuedAt`、`startedAt`、`endedAt`
- `audioDurationMs`
- `decodeMs`、`vadMs`、`asrMs`、`embeddingMs`、`commitMs`
- `thermalStart`、`thermalEnd`
- `outcome`、`terminationReason`

指标不保存原始音频或转录正文，可在诊断导出时聚合为每分钟耗时、P50/P90、实时率和暂停原因。

### SpeakerObservation

- 稳定 ID、Recording ID、source range / segment ID
- `startSample`、`endSample`
- embedding BLOB、维度、模型 ID、pipeline version
- 音量/质量/重叠 exclusion flags
- 创建时间和最后验证时间

### TranscriptDocument

保持 `voice-context/transcript@1` 向后兼容。已有 `segments`、`speakers` 和 `speaker_turns` 继续使用；可加法增加 speaker processing state / pipeline version，但旧读者必须能忽略。

## 状态、错误与恢复

| 事件 | 必须发生 | 禁止发生 |
|---|---|---|
| App 进入后台 | 使不支持后台的 lease 失效，job 回 pending | 继续提交未授权 Metal；把 job 标 failed |
| App 被终止 | closed 音频与已提交结果保留 | running 永久卡住 |
| 冷启动 | 先恢复屏障，再启动唯一 drain | backfill 与 resume 同时启动 drain |
| 旧 task 迟到 | token 校验失败并丢弃结果 | 覆盖新 revision 或完成错误 job |
| ASR 成功、说话人失败 | 文字可读，speaker finalization 可重试 | 删除文字或回滚 ASR job |
| 所有 job 完成、回调丢失 | reconciler 自动修复 complete | Recording/Transcript 长期 processing |
| 热状态 serious/critical | 在边界暂停并记录原因 | 用异常长 job 时长伪装模型速度 |
| 模型或投影写入失败 | 保留音频、错误和重试入口 | `try?` 后显示成功 |

## 隐私、安全与合规

- 所有音频、attempt 指标和 speaker embedding 仍只保存在 App 私有本地容器。
- 公开 VoiceContext 文档不得包含 embedding、设备路径、execution token 或内部错误堆栈。
- 后台转写选择必须说明本地处理、耗电和系统可能中止；不得包装成不存在的系统永久授权。
- 新 speaker segmentation 模型在进入 App 前必须完成许可、模型来源、哈希、包体和隐私审核。
- 诊断导出默认只包含聚合时长、状态和匿名稳定 ID；包含正文或声纹数据必须另行显式授权。

## 验收标准

### 可靠性

- [ ] 任意自动化、真机和恢复压力测试中，全局有效 running transcription lease 始终 `<= 1`。
- [ ] 失效 execution token 的迟到结果不能修改 transcript、speaker observations、试用额度或 job 完成态。
- [ ] 连续执行前后台切换、强制终止和重启后，canonical job、segment、source range 和扣费均不重复。
- [ ] capture 已结束且全部 canonical jobs 完成后，Recording 与 Transcript 在 2 秒内由 reconciler 收口为 complete，即使 outcome handler 未执行。
- [ ] 一小时录音恢复 10 次后仍能完成；不存在永久 running/processing，失败均有明确原因和重试入口。

### 性能与可观测性

- [ ] iPhone 15 Pro、nominal/fair、持续前台、60 分钟 2–6 人样本：ASR 阶段不超过 12 分钟，总处理含一次 speaker finalization 不超过 15 分钟。
- [ ] 60 秒 job 的端到端 P50 不超过 12 秒、P90 不超过 20 秒；后台、热暂停单独记账，不混入 active processing。
- [ ] 每个 attempt 可读取 decode/VAD/ASR/embedding/commit 分阶段时长、音频时长、热状态和终止原因。
- [ ] 每个分片提交只写新增 observation/segment；不存在每分钟重写整场 embedding 或重建完整 bindings。
- [ ] 10、30、60 分钟样本的热路径耗时随新增音频近似线性增长，不因历史 observation 数量出现数量级跳升。

### 多人对话

- [ ] 评测集覆盖 2、3–4、5–6 人，包含短插话、不同距离、办公室噪声和少量重叠语音。
- [ ] 模型对比独立报告 CER/WER、DER、说话人数误差、speaker-attributed CER/WER、RTF、内存、发热和包体。
- [ ] 最终候选相对当前基线降低 DER，且不降低文字完整性；正式发布阈值在锁定评测集基线后确认。
- [ ] 2–6 人不要求用户输入准确人数；重叠或证据不足时允许 mixed/unknown，不伪造身份。
- [ ] speaker finalization 失败时 ASR 文稿仍可阅读、编辑、导出和重试说话人处理。

### 后台与 UI

- [ ] iOS 18–25 后台不提交新 Metal，回前台按唯一 lease 有序续跑。
- [ ] iOS 26 continued task expiration 后 job 回 pending，已完成结果不丢不重。
- [ ] UI 和 VoiceOver 区分“正在转写”“正在整理说话人”“后台转写中”“待回前台”“需要注意”和“已完成”。
- [ ] 用户选择不允许后台转写时，录音、排队、恢复和最终完成能力不受影响。

## 实施阶段与依赖

### Phase 0：基准与失败复现

- 固化本次匿名真机证据为本地测试口径，不把用户录音正文、声纹或设备容器副本提交进仓库。
- 增加 ProcessingAttempt 指标和一小时测试报告格式。
- 构造可重复的恢复竞态测试：backfill、resume、scene active 同时发生。

### Phase 1：P0 调度与完成态修复

- 不可变 JobExecutionLease、原子 claim、单 drain generation。
- 启动恢复屏障与迟到结果拒绝。
- TranscriptCommitCoordinator 与 CompletionReconciler。
- 先用现有模型证明无重叠执行、无永久 processing。

### Phase 2：P1 长录音性能

- speaker observations 增量存储。
- 全场聚类和 bindings 移出分钟热路径，只在最终化执行一次。
- 公共文档发布节流，私有 canonical transcript 仍逐分片可靠落盘。
- 达成 60 分钟总处理性能预算。

### Phase 3：P1 多人 diarization 评测与接入

- 建立匿名、经同意的 2–6 人锁定评测集。
- 对比当前基线与独立 speaker segmentation 候选。
- 选择模型、完成许可与真机资源验证，再接入 SpeakerFinalizationJob。

### Phase 4：P2 iOS 26 后台继续处理

- 产品负责人确认 opt-in 时机和默认值。
- 接入 BGContinuedProcessingTask / GPU capability 与系统进度。
- 验证取消、expiration、锁屏、发热和 iOS 18–25 回退。

依赖顺序：Phase 0 → Phase 1 → Phase 2；Phase 3 的离线模型 benchmark 可与 Phase 2 并行，但正式接入依赖 Phase 1/2；Phase 4 依赖 Phase 1 的 lease 与恢复语义。

## 2026-08-24 实现与真机验证记录

- P0 已接入不可变 `JobExecutionLease`、SQLite 原子全局 claim/token CAS、单 drain generation、恢复屏障与 `CompletionReconciler`。
- P1 已将 observation 改为 chunk/range 分片，把整场 recluster/binding/public publish 移出分钟级热路径，并增加持久化 `speakerFinalization` job 与分阶段指标。
- P1 已接入 `pyannote-segmentation-3-int8` + CAM++ 的 sherpa-onnx 真实说话人分离；manifest SHA-256 校验、许可链接和 CAM++ 失败回退均已接入。Sherpa 按 60 秒窗口处理并复用同一模型 session，局部 speaker ID 由全局 CAM++ label 对齐。
- P2 已接入 iOS 26 `BGContinuedProcessingTask`、GPU resource、系统 `Progress`、expiration 失效 lease 和前台回退；默认关闭，只在用户明确发起转写时提交。
- 真机：iPhone 15 Pro，iOS 26.5。本轮不使用 Simulator；不在仓库文档中保存设备名称或设备 ID。
- 真机测试：原子 claim/迟到完成拒绝、完成对账与回调丢失修复 2 项通过；speaker finalization 和后台偏好/进度 10 项通过。
- 真机 Sherpa 验证：17.485 秒打包音频成功产生 speaker/turns；最终 60 秒窗口版用时 4.862 秒。早期线程对比为 1 线程 3.704–6.957 秒、2 线程 4.042 秒、4 线程 7.336 秒，当前选用 2 线程。
- 说话人最终化的 Swift PCM 峰值已改为有界：导入音频约 3.66 MiB，麦克风 chunk 拼窗最坏约 7.32 MiB，不再随录音总时长增长（不含 Sherpa native runtime）。
- 真机 Debug app 已完成 build、codesign 验证、安装和启动。专用 provisioning profile 已签入 Background GPU Access 与 iCloud entitlement。
- 待完成：一小时真实 2–6 人样本的 DER/总耗时/Sherpa native 峰值内存验收；以及真实待处理队列下的锁屏、系统取消和 expiration 验收。

## 待确认项

1. 是否确认性能预算：一小时 ASR `<= 12 分钟`，含说话人最终化总计 `<= 15 分钟`。
2. 录音过程中是否还需要展示 provisional speaker，还是只在停止后提供最终 speaker turns；推荐保留轻量临时标签，但不阻塞文字。
3. iOS 26 后台转写已确认为设置页显式 opt-in，默认关闭；后续只需验证首次说明文案是否足够清楚。
4. 多人模型正式选择前，真实评测音频由谁负责取得参与者同意和人工标注；未确认前只做技术样本，不进入训练。
5. PM 看板服务恢复后，新建本次恢复竞态与永久 processing 的 bug，并决定目标 patch/minor 里程碑。

## PM 追踪关系

- 来源 requirement / task：`#4`、`#6`、`#49`；新 bug 待看板服务恢复后补建
- 功能蓝图：录音与本地数据 / 恢复与处理生命周期；本地语音智能 / SenseVoice 调度、说话人聚类；开放文档与产品体验 / 处理状态
- 交付任务：待本设计确认且 PM 看板可用后创建
- 目标里程碑：待任务清单成形后确认，不编造日期
