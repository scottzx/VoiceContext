# 文稿 schema 与语义向量说明

日期：2026-10-03。**待评审提案，未冻结、未发布生产格式。** [文稿附录](../recording-ai-actions-transcript-contract.md) 的机器可校验草稿；仍依赖 D01/D02/D06 与 C00 评审。当前 Transcript@1、现有编辑/转写/store/回听与 Agent 入口是实施基线，不由这些文件替换。

## 文件与复用

- [transcript.schema.json](transcript.schema.json)：JSON Schema draft2020-12；主对象为 transcriptEvidence、preflight、candidate、adoption、history、deletion，其余 `$defs` 为组成部分。
- [transcript.cases.json](transcript.cases.json)：裸数组 `{name, definition, value, schemaValid, semanticValid, errorCode?, context?}`；definition 指向本文件 `$defs`。
- [参考业务校验器](../../../tools/integration/recording_ai_contract_transcript.py)：`validate(definition, value, context) -> list[str]`，只用于草案向量，先经过 schema 校验再调用。
- [common.schema.json](common.schema.json)：复用 UUID、sha256、source、dateTime、sourceRange、opaqueID；source 始终严格只有 recordingID/revision/sha256。citation 仍由 common 定义，文稿对象不另造引用格式。

新对象采用 `voice-context/recording-ai@1` 的 objectKind；它们不是 Transcript@1 的新必填字段。案例中的旧稿场景是将旧信息投影成 unknown，不是让新解码器直接读取 Transcript@1，也不代表迁移代码已存在。UUID 接受既有大小写，新生成使用小写；日期必须含显式 offset 或 Z。

## completeness 的嵌入结构

input/request 直接引用 `#/$defs/completeness`，不在内部重复 source。完整持久证据由外层 transcriptEvidence 绑定 source、evidenceID、createdAt；当前音频 audioAvailability 独立保存，不倒退已有历史识别证据。

completeness 必填 scope、domainFinalized、sampleRate=16000、rangeConvention=halfOpen、processingState、contentState、expectedRanges、observedRanges、captureGaps、legacyAnchors、warnings。scope=selection 时另必填 selectedSegmentIDs、recordingContentState。

`legacyAnchors[]` 为 `{segmentID, sourceKind, sourceID, sample}`，sample 非负，仅定位、不贡献覆盖。旧零长度 source range 不允许混入新 expected/observedRanges，不能补出到下句或片尾的虚构终点。输入的空 sourceRanges 必须由同一 segmentID 的 anchor 映射，录音原有 ID 与正文继续保留。

[input/request 契约](request.schema.json) 的 selectionMode 区分 all 与 segments：all 核对全部 canonical segmentIDs，可携带无文字范围的已知缺口；segments 只含所选完整段的正范围及精确旧点映射，decode/VAD/ASR 内部范围也必须裁切。该投影约束属于 input/request 校验，不能只凭 completeness 的 selectedSegmentIDs 证明。选区 complete 也不能升级 recordingContentState。

范围全部使用现有录音级 16 kHz 半开坐标，按 sourceKind + sourceID 分组求并集；相邻范围可连成覆盖，不同来源不能互相填补。new end 必须大于 start；比较、并集、覆盖、外部身份和 bytes 摘要不能由 JSON Schema 单独证明。sourceRanges 只保存 common 四字段；processingScope 使用 `{range, processingRangeID}`，导入任务必须保留该 ID，微录音为 null。

## 证据与推导顺序

observed row 明确 range、outcome、jobID/attemptID、segmentIDs 与 decode/VAD/ASR 证据。未记录执行身份允许 null 供已知历史失败迁移，但不能因此声称存在成功执行。failed 额外必填 stage=decode/vad/utterance/asr 与 reasonCode。

1. transcribed/silence/voicedEmpty 均须解码状态 complete，真实 decodedRanges 覆盖该声明范围；补零不证明实际覆盖。
2. silence 必须 VAD 成功、detectorVersion 可追溯、没有 speech ranges、没有识别文本，ASR 未执行。语义是未检测到语音，不承诺物理无声。
3. transcribed 必须检测到语音、ASR 有文字且处理全部 speech ranges；voicedEmpty 必须 ASR 确实执行并返回 empty，不能由 notRun 或 utterance 构造失败冒充。失败阶段与证据状态一致。
4. 已知 pending/failed/voicedEmpty/unreadable/missing/interrupted 或不可恢复捕获缺口为 partial，仍允许用户主动整理已有文字。
5. 没有已知负面范围，但域未闭合、旧点/开放缺口存在或预期范围没有可核对 outcome 证据则为 unknown。缺少旧阶段证据不能推断静音或失败；已知缺口优先 partial，其他未知项同时保留。
6. 只有闭合域全部由可信 transcribed/silence 覆盖且没有未处理语音/未知边界才为 complete。processingState 独立；terminal 和 `gaps=[]` 不是覆盖证据。

userPause 表示用户主动未录，原原因保留但不伪造损坏。捕获 gap 的 end 可为 null 或点事件；不能扩写精确时长。音频后来 expired 可以与既有完整转写证据共存；未处理音频已缺失则单独为缺口。

## 预检、候选与版本

preflight 的 requestedScopes 与 results 一一对应，避免两个可用/不可用列表漂移。结果保存声明数量、实际源长度、sourceStartSample、相对 decodeRange、decodedSampleCount 与文件身份；chunk 的解码起点为 `scope.startSample - sourceStartSample`，导入源的 sourceStartSample 固定 0。真实来源起点必须由 repository 核对，输入这些数字不证明已探测文件。

readable 必须覆盖整个本次范围；60 秒声明仅剩 10 秒即使 decoder 回了补零也不成立。使用可读前缀需另建显式范围，不静默裁切。unavailable 保留 expired/missing/truncated/decodeFailed/sourceNotClosed/unknown 原因。预检只描述 checkedAt 时点，实际执行仍需重新解码、检查来源/lease；不延长 7 天期限，不清旧文字。

candidate ready 只表示有可比较草稿，可包含仅部分成功的范围，不代表全部成功。草稿具有候选 draftID 和 ASR origin，不自动继承原 segment ID/校对 provenance；实际草稿不能超出 processed/requested scope，draftID 不能重复。

adoption 绑定 candidateID、候选原始 bytes hash、用户所见 expectedCurrentSource 与选择；默认保留校对，只接受稳定映射。replaceAll 需明确确认，committed 必须有 previousVersionID 与新的 resultSource；revision 只前进。历史 source hash 对原始 UTF-8 bytes 计算，重新编码的等价对象不能替代它。

这些静态比较不是生产 compare-and-set 或执行排斥。真正保存须在 store 的统一提交边界内完成版本/墓碑核对、保存历史及 canonical 替换；现有原子保护不等于候选、恢复或完整 C01 已实现。

## 墓碑与外部事实

deletion 必须 sourceRevoked=true；raw 策略只能 delete，systemItems 只能 keep。逐对象 kind 决定 dataClass；原文、输入、历史/候选、公开/共享镜像与可重建索引不能 kept。Daily 对应条目通过 rebuilt 完成，不能删除其他录音的整天文件。保留派生物必须匹配用户所选 minutes/mindmap，并清除完整原文附件；默认派生策略仍待 D06。

failed 对象留 lastErrorCode 并保持 deleting；completed 只允许 deleted/rebuilt/kept。墓碑在清理完成后持续撤销该 recordingID，不由文件消失解除。系统事项保留不等于仍可读取或已通知。

| context fixture | 参考校验的用途 | 仍需实际服务证明 |
|---|---|---|
| source / currentSource / planSource | 核对绑定来源、预检/采纳冲突 | 同一次读取和提交时的权威身份；跨 actor await 后再次比较不能替代互斥 |
| candidateSha256 / candidate / manuallyEditedSegmentIDs | 核对候选身份/hash、选择及默认校对/映射保护 | 从固定候选 bytes 计算摘要、核对最新全部校对段和跨边界映射 |
| canonicalBytesUTF8 / parentSource | 核对历史源 bytes 与 parent | 实际不可变文件、原子历史保存与恢复 |
| recordingContentState | 选区不能改整条结论 | 对匹配 evidence 的投影与选区隐私范围 |
| tombstoned | 预检/候选/采纳/历史拒绝已删来源 | 持久墓碑、统一提交排斥、防迟到回调复活 |
| requiredObjectIDs / activeProducerIDs / rawArchiveObjectIDs | 核对删除清单、未停止生产者、保留物原文附件 | 真实库存、取消/停止、文件清理、共享/iCloud 发布与重启恢复 |

context 缺失时参考校验器不凭空读取环境；返回无错误只表示所提供值自洽，不代表不存在 tombstone、已完成 ASR、没有原文残留或具有提交授权。代码不会调用音频解码、Agent、EventKit、文件删除或锁，也不复制录音状态机。

## 已执行验证的边界

执行 `python3 tools/integration/verify_recording_ai_contract.py --area transcript`：检查 draft2020-12 schema、离线 `$ref`、shape 与业务正反向量及独立 errorCode。另做 Python 编译与差异空白检查。案例均为虚构 fixture；不能算生产 C01/C02/C03/C12、真实迁移、并发/删除恢复、iOS 或无障碍通过。
