# 0.2.0 分钟级增量转写设计文档

## 文档信息

- 状态：已确认
- Owner：Human product owner / Agent implementation
- 来源需求：`#3`、`#4`、`#5`、`#52`，继承顶层 `#1`
- 对应功能模块：录音与本地数据 / 60 秒录音分片与前后台生命周期、录音与处理正交生命周期；本地语音智能 / VAD、跨分片 carry 与 utterance 组装、SenseVoice 分钟级增量转写调度；开放文档与产品体验 / TranscriptDocumentV1、source_ranges 与 Markdown
- 最后更新：2026-08-12

## 背景与问题

现有基线只在用户停止整条 Recording 后创建转写任务，并以 Recording 为处理与麦克风会话的共同生命周期。这会造成两个问题：录音中没有分钟级增量文稿；旧 Recording 转写时会继续占用“活跃录音”身份，阻止新录音。

产品负责人已确认采用可靠性优先的分钟级增量方案：一条用户可见 Recording 内部由默认 60 秒 AudioChunk 组成；每个 chunk 关闭后立即创建处理检查点，同时继续采集下一 chunk。普通文件边界不是语言边界，尾部未完成语音通过 carry 与后续连续 chunk 重组为 utterance。

## 目标

- 新录音默认每 60 秒形成一个可独立校验、恢复和处理的 closed AudioChunk。
- AudioChunk 关闭后立即排队处理，不等待整条 Recording 停止。
- 下一 AudioChunk 的采集与上一 AudioChunk 的 VAD/转写并行；处理积压、失败或锁定不阻塞麦克风。
- speech span 组成目标约 3–15 秒、最长 25 秒的 utterance；有效短语音保留。
- utterance 可跨越任意数量连续 AudioChunk，并保存精确 `source_ranges`；遇到 gap、暂停或系统中断时不得跨越。
- 前台正常、无积压时，最终文稿延迟目标不超过一个 60 秒分片周期加本地处理时间。
- 后台继续录音、VAD、分片落盘和任务排队，但不提交新的 Metal 工作；回前台幂等续跑。

## 不做

- 不实现逐字流式模型，不承诺词级实时刷新。
- v1 不从云端转写，不在后台提交 SenseVoice Metal command buffer。
- 不为了转写而移动、复制、重叠或重新编码麦克风录音的权威 AAC 音频；Files 导入只复制一份完整源文件到私有目录，不默认重切为 60 秒文件。
- 不把内部 AudioChunk 暴露为用户可见的多条录音。
- 本阶段不承诺 salvage 未关闭 AAC；只有 closed chunk 是权威恢复检查点。
- 不新增视觉风格或原型方向；沿用已确认设计系统。

## 用户、场景或调用方

- 用户连续录制个人口述或长会议时，每分钟逐步看到文稿和待处理状态，无需等到停止。
- 用户停止当前 Recording 后可以立即开始下一条；旧 Recording 的剩余转写继续排队。
- 录音页面与全局录音条同时展示采集状态、最后已转写位置和待处理数量。
- `RecordingSessionCoordinator` 只拥有麦克风采集；增量调度器消费 closed chunks 和 carry。
- Transcript、说话人、试用额度和导出模块消费稳定 utterance/segment 结果，不直接推断文件边界。

## 产品流程 / 信息架构

```text
用户开始 Recording
  → Capture 写 AudioChunk N（默认最长 60 秒）
  → N 在绝对样本边界关闭并写入 journal/index
  → 立即继续写 AudioChunk N+1
  → 为 N 创建幂等 ChunkProcessingJob
      → VAD 形成 speech spans
      → 完整 utterance 进入前台 SenseVoice 队列
      → 未完成尾部保存为 OpenUtteranceCarry
  → N+1 关闭后先消费 carry，再处理其余 utterance
  → transcript segment 增量提交并更新“已转写至”
用户停止
  → 关闭不足 60 秒的最后 chunk
  → flush carry 与最后任务
  → 立即释放麦克风
  → 剩余处理继续，不阻止下一条 Recording
```

用户始终看到一条 Recording、一个总时长、一条连续时间轴和一个播放器。内部文件数量只用于诊断、恢复和按需导出。

## UI/UX 风格确认（原型前门禁）

- 状态：已确认并复用，当前架构调整无需新增原型。
- 一句话记忆点：录音像系统工具一样可信；文字可以稍后追上，但录音不会被处理打断。
- 风格关键词：安静、原生、精确、私密、耐用；反向关键词：伪实时、状态含糊、AI 炫技、装饰性进度。
- 原生与品牌：完整复用 `DESIGN.md`；录音红色状态始终优先，处理使用明确文字和克制的次级状态。
- 信息密度与层级：正在录音 > 已转写至 > 待处理数 > 处理阶段。处理状态不能覆盖停止入口。
- 视觉方向：不新增 token；复用全局录音条、状态文字和 VoiceOver 顺序。
- 参考与反例：参考 Apple Voice Memos 的可靠录音心智；拒绝逐字跳动、把“排队”显示成“实时识别”、或用模型加载阻塞录音按钮。
- 无障碍底线：VoiceOver 读出正在录音、已录时长、已转写至和待处理数；状态不只依赖颜色；Reduce Motion 下不做逐字动画。
- 决策记录：Human product owner，2026-08-07；适用于 v1 iPhone。
- 既有规范：`DESIGN.md`、`docs/design/v1/design-system.md`、`docs/design/v1/state-matrix.md`。

## 原型与 UI/UX

无需新增低保真或高保真原型。既有录音页、全局录音条、处理中和详情页结构保持不变；后续 UI 实现任务只需把旧的“停止后处理”语义改为分钟级增量状态，并新增“已转写至 +MM:SS / 待处理 N 项”的诚实反馈。内部 AudioChunk 数量和文件边界不向用户展示。设计走查继续由既有 `#41` 负责。

## 技术方案

### 三条独立边界

| 对象 | 边界来源 | 职责 |
|---|---|---|
| `Recording` | 用户显式开始/停止 | 用户可见的一次录音或会议 |
| `AudioChunk` | 默认每 960,000 个 16 kHz 输出样本；停止/暂停/中断可提前关闭 | 权威音频、恢复与处理检查点 |
| `Utterance` | VAD 停顿与 25 秒硬上限 | SenseVoice 模型输入和 transcript segment 来源 |

三者不得 1:1 绑定。一个 Recording 有多个 AudioChunk；一个 AudioChunk 可产生多个 utterance；一个 utterance 可跨多个连续 AudioChunk。

### Files 导入：完整源文件 + 逻辑处理范围

物理 `AudioChunk` 是麦克风录音的可靠落盘策略，不是导入音频的默认存储格式。Files 导入采用下列模型：

| 对象 | 责任 | 是否为独立媒体文件 |
|---|---|---|
| `ImportedAudioAsset` | 私有目录中唯一的完整源文件副本；用于播放、重新处理和媒体导出 | 是，且默认仅一份 |
| `ProcessingRange` | 以 `sequence`、起止时间或起止采样点表示的 60 秒处理单元 | 否，只是持久化元数据 |
| VAD utterance | 在处理范围内按需解码后得到的 3–25 秒可推理语音段 | 否 |

- 导入完成后读取媒体元数据，再连续建立 60 秒 `ProcessingRange`；最后一个范围可短于 60 秒。
- 执行范围任务时，只从 `ImportedAudioAsset` 读取所需样本并在内存中规范化为 16 kHz、单声道 PCM；不得一次性把完整导入文件送入模型。
- 范围末尾有未闭合语音时，沿用 `OpenUtteranceCarry`：下一范围与必要尾部上下文联合推理，成功后清除续接标记。
- 播放始终读取完整源文件（或唯一标准化资产），以全局时间轴定位；逻辑处理范围绝不暴露成播放器片段列表。
- 仅当原始编码无法稳定随机读取或解码时，允许生成**一份**标准化私有资产；仍以逻辑范围处理，不切出多个 60 秒 AAC/PCM 文件。

导入记录在用户界面、`TranscriptDocument` 和全局播放时间轴中与麦克风记录保持统一，但其数据关系为 `ImportedAudioAsset + ProcessingRange`，而非物理 `AudioChunk` 序列。

### 分钟级流水线

```text
Capture（最高优先级、持续）
AudioChunk A ── AudioChunk B ── AudioChunk C ── Tail
          │               │               │
          ▼               ▼               ▼
Queue   Process A       Process B       Process C/Tail
          │               │
          ▼               ▼
ASR     utterances      carry + utterances
```

- writer 在精确样本边界关闭 A 并立即继续 B，不等待数据库、VAD 或模型。
- chunkClosed 事件落 journal/index 后创建幂等 `ChunkProcessingJob(recordingID, chunkID, sequence, pipelineVersion)`。
- 同一 Recording 的 chunk job 按 sequence 处理；全局 SenseVoice Metal 最多一个并发。
- `ChunkProcessingJob` 是持久化调度/恢复单位；每个 utterance 是实际模型调用单位。
- 录音和处理使用不同 actor/队列及状态；推理取消、失败或积压不能停止 capture。

### 跨 AudioChunk carry

普通文件边界处 VAD 不 flush。若 AudioChunk A 结束时仍有 open speech：

1. A 中已结束的 utterance 正常提交。
2. 未结束尾部保存 `OpenUtteranceCarry`，只记录绝对样本、speech spans 和来源范围，不修改 A 文件。
3. B 关闭并分析后，若 B 头部与 carry 连续、间隔不超过合并阈值、且中间没有 gap，则形成跨 chunk utterance。
4. 按半开区间 `[startSample, endSample)` 从 A 尾部与 B 头部解码 PCM，校验 cursor 连续后在内存中顺序拼接。
5. 若总长度达到 25 秒，在最近可用停顿或低能量点切分；找不到时执行硬切，公开来源范围仍无重叠。
6. 若遇暂停、中断、缺失/损坏 chunk 或显式 gap，则关闭或失败当前 carry，绝不静默补零并伪装连续。

示例：60 秒边界为样本 960,000；utterance 为 `[950400, 979200)`，其来源是 A `[950400, 960000)` 与 B `[960000, 979200)`。两个范围拼接后形成一次 1.8 秒模型输入，权威 AAC 本身不移动、不复制。

### 延迟语义

可靠性优先阶段只从已关闭 AudioChunk 建立 canonical 处理任务，不新增实时 PCM spool。因此：

- 同一 chunk 内已结束 utterance 在该 chunk 关闭后处理。
- 跨边界 carry 在所需后续 chunk 关闭后处理。
- 前台正常、无积压时，从 utterance 结束到最终文稿可见的目标延迟为 0–60 秒加本地处理时间。
- 后台、热暂停、内存压力、试用锁定或队列积压时不适用该目标，UI 必须显示实际待处理数量。

## 数据与接口

### `AudioChunk`

- `id`、`recordingID`、`sequence`、`relativePath`
- `startSample`、`endSample`、`startedAt`、`endedAt`
- `state`、保留/pin 信息

读取端必须按实际范围工作。历史约 5 分钟或任意长度 chunk 与新 60 秒 chunk 可以共存。

### `ImportedAudioAsset` 与 `ProcessingRange`

- `ImportedAudioAsset`：`recordingID`、私有 URL、原始文件名、UTType、时长和导入时间。
- `ProcessingRange`：`recordingID`、`sequence`、起止时间/采样点、状态、续接标记和重试信息；它不拥有媒体文件。
- 导入范围任务的稳定幂等键：`recordingID + processingRangeID + pipelineVersion`。

### `ChunkProcessingJob`

- 稳定幂等键：`recordingID + chunkID + pipelineVersion`
- `sequence`、`state`、`attemptCount`、`lastError`
- `pending/running/completed/failed/deferredUntilForeground/lockedPendingPurchase`

导入范围任务使用同一调度语义，但其稳定幂等键为 `recordingID + processingRangeID + pipelineVersion`；`chunkID` 与 `processingRangeID` 只能二选一，不能为导入记录补造物理 `AudioChunk`。

### `OpenUtteranceCarry`

- `recordingID`、稳定 ID、`startSample`、当前 `endSample`
- speech span IDs、`sourceRanges`
- `originChunkSequence`、`state`、`pipelineVersion`

carry 可作为独立持久化实体，或由可幂等重建的 chunk 分析检查点表达；无论采用哪种存储形式，崩溃后都不能重复生成或遗漏跨 chunk segment。

### `SourceRange`

```json
{
  "source_kind": "audio_chunk",
  "source_id": "UUID",
  "start_sample": 950400,
  "end_sample": 960000
}
```

Transcript segment 使用 `source_ranges: [SourceRange]`，不再以单一 `source_chunk_id` 作为完整来源。麦克风记录的 `source_kind` 为 `audio_chunk`；Files 导入为 `imported_asset`，`source_id` 指向 `ImportedAudioAsset`。为兼容已存在的 `voice-context/transcript@1` 本地文件，迁移读取器需接受旧 `chunk_id` 单值并规范化为一个 range；写出策略及是否升级 schema version 由文档契约任务明确，不能静默破坏旧文件。

### 处理进度

至少暴露：`lastCapturedSample`、`lastClosedChunkSequence`、`lastFinalizedTranscriptSample`、pending/running/failed 数量。UI 由这些权威值派生“已转写至 +MM:SS”和待处理数，不从动画或本地计时器伪造。

## 状态、错误与恢复

### 正交状态

- Capture：`idle/preparing/recording/paused/interrupted/stopping`。
- Processing：`idle/processing/deferredUntilForeground/lockedPendingPurchase/needsAttention/complete`。

同一 Recording 可以同时为 Capture `recording`、Processing `processing`。旧 Recording 可以 Processing `processing`，同时新 Recording 为 Capture `recording`。停止只释放 capture，不等待 processing complete。

### 幂等与恢复

- chunkClosed 事件使用稳定 event ID；重复恢复不得重复创建 job。
- utterance/segment ID 由 Recording、绝对样本范围和 pipeline version 稳定派生，重复执行覆盖同一结果而不是追加重复文字。
- App 进入后台时取消或暂停正在运行的 Metal 工作，将 job 恢复为 pending/deferred；capture 与 CPU VAD/排队继续。
- App 被终止后只信任 closed chunks 和已提交 journal；running job 回 pending，carry 从持久化状态或相邻 closed chunks 幂等重建。
- 未关闭 AAC 单独诊断为 orphan/active tail，不静默标记 closed，也不与后续录音拼接。
- 停止后最后不足 60 秒 chunk 立即关闭、入队并释放麦克风。

### 错误隔离

- AAC 写盘失败：优先保护 capture 状态并记录 gap；不能归因成 ASR 失败。
- VAD/ASR 失败：保留音频、job、carry/source ranges 与错误；允许重试，不生成空文本完成态。
- 单个 utterance 失败：不删除同 chunk 其他成功结果；是否按子任务或幂等重跑整个 chunk 由实现选择，但公开结果不得重复。
- 热、内存或低电量：暂停推理并保留队列；不得降低录音 writer 优先级。
- 试用耗尽：新 utterance 进入 locked 状态，音频与 carry 继续保存；解锁后按绝对时间续跑且重试不重复计费。

## 隐私、安全与合规

- AudioChunk、ImportedAudioAsset、临时 PCM（若未来引入）、carry 和 source ranges 都是本地敏感录音数据，不进入公开 iCloud Drive。
- 当前可靠性优先方案不新增临时 utterance 音频副本；ASR 在内存中拼接所需 PCM，并在任务结束后释放。
- 原始音频保留与删除规则以 Recording 及其 `AudioChunk` 或 `ImportedAudioAsset` 为准；删除音频不删除 transcript，但必须更新来源可用状态。
- 试用额度按首次成功提交的 canonical ASR 音频时长累计；幂等重试不得重复扣减。

## 验收标准

- [ ] 新录音默认每 960,000 个 16 kHz 输出样本关闭一个 AudioChunk；两小时形成 120 个连续完整 chunk 加可选尾段，跨输入包无重复或缺失样本。
- [ ] 历史非 60 秒 chunk 保持可读、可播放、可转写和可导出。
- [ ] 每个 closed chunk 在 journal/index 提交后立即创建且只创建一个处理 job；下一 chunk 采集不等待该 job。
- [ ] 同一 Recording 的 jobs 按 sequence 幂等执行；全局 SenseVoice Metal 最多一个并发。
- [ ] 3–15 秒目标、有效短语音、25 秒硬上限、自然停顿和跨 chunk carry 测试通过。
- [ ] 跨 chunk utterance 的 PCM、绝对时间和 `source_ranges` 连续无重叠；显式 gap 不被跨越。
- [ ] 前台正常无积压时，文稿延迟不超过一个分片周期加本地处理时间；后台零新增 Metal，回前台补齐。
- [ ] processing、failed、locked 或旧 Recording 积压都不阻止当前或下一条 Recording 开始、继续和停止。
- [ ] 停止后最终尾段立即关闭入队，麦克风无需等待转写完成即可复用。
- [ ] 强制终止恢复不重复 job、carry、utterance、segment 或试用扣费；未关闭 chunk 行为如实记录。
- [ ] UI 与 VoiceOver 能区分正在录音、已转写至、待处理、后台暂停、热暂停、锁定和失败。
- [ ] 导入音频默认只保存一份完整私有媒体资产，并以 60 秒逻辑处理范围恢复转写；长文件不会一次性读入内存，也不会默认生成多个 60 秒媒体文件。

## 待确认项

- ~~`source_ranges` 是在 `voice-context/transcript@1` 内做向后兼容扩展，还是升级为新 schema version~~：**已确认（`#47`）**——保持 `voice-context/transcript@1`，以加法字段 `source_ranges` / `start_sample` / `end_sample` 扩展；读取器将旧 `source_chunk_id` 规范化为单 range；写出时 dual-write `source_chunk_id`（取首个 `audio_chunk` range）以便 rollback 读者不破。
- 60 秒延迟目标需在 iPhone 15 / iOS 18 真机以长录音、跨边界连续说话、后台积压和发热场景验证；无真机证据前不能宣称为硬 SLA。
- 当前 active AAC 的 salvage 策略仍不在本阶段范围；发布前需决定是清理孤儿文件还是提供显式恢复尝试。

## PM 追踪关系

- 来源 requirement：`#3`、`#4`、`#5`、`#52`
- 功能蓝图：录音与本地数据 / 60 秒录音分片与前后台生命周期、录音与处理正交生命周期；本地语音智能 / VAD、跨分片 carry 与 utterance 组装、SenseVoice 分钟级增量转写调度；开放文档与产品体验 / TranscriptDocumentV1、source_ranges 与 Markdown
- 既有基线任务：`#16`（5 分钟 AAC 分片）、`#17`（录音状态机）、`#18`（恢复）、`#20`（基础 utterance 组装）、`#21`（前台 Metal 调度）、`#23`（TranscriptDocumentV1）、`#42`（录音 UI）
- 本轮增量任务：`#43`（60 秒分片与历史兼容）、`#44`（正交生命周期）、`#45`（跨 chunk carry）、`#46`（分钟级调度）、`#47`（多 source_ranges）、`#48`（双状态 UI）、`#49`（端到端稳定性验收）
- 导入功能蓝图：`Files 音频导入与本地转写`（需求 `#52`）；实现任务待该需求进入开发阶段后按本架构拆解。
- 目标里程碑：`0.1.0`（60 秒可靠分片）与 `0.2.0`（增量转写、carry、文档与体验）
