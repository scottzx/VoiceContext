# 固定输入与现有聊天关联：机器草案边界

2026-10-03，待评审、未冻结、未接入生产。依据 [主契约](../recording-ai-actions-contract.md)、[实际已有产品](../recording-ai-actions-existing-product.md) 和 [文稿附录](../recording-ai-actions-transcript-contract.md)。

[request.schema.json](request.schema.json) 约束 input/request/runAssociation/typeOutcome 的字段、null、状态、版本和引用。新输入不替代 Transcript@1；`schema=voice-context/recording-input@1` 只是此次提案。历史文稿继续由实际 TranscriptDocumentV1 解码。

现有 ChatStore 持久会话与消息，聊天执行器负责发送与执行；AgentKit AgentStore 管 Agent 定义，不是运行权威。新的 attempt UUID 需沿现有草稿、真实 `.sessionDidCreate`、用户发送消息与执行事件建立关联。assistant 流消息 `runMsgId` 可以变化，不能当持久整理 run ID。这里的 executionRecords 是独立 fixture 的观察记录，尚未实现生产回调或重启恢复。

## 输入与兼容规则

- source hash 对完整 canonical 的原始 UTF-8 bytes；input hash 对实际发送的 bytes。等价 JSON 重编码也不得替代它们。实际 input bytes 再严格解码，拒绝重复键、非法常量、未知字段和与请求不一致的内容。
- selectionMode=all 必须包含该版本全部文字，允许投影整录音没有文字的声音/缺口证据；segments 仅携所选正文及其确切来源范围、证据、警告和 anchor。选区的 expectedRanges 不得引入未选段，observed 的段 ID 和内部样本范围也受相同边界约束。
- 旧 `source_chunk_id` 按现有解码器投影：start_sample 缺失则 offset_milliseconds×16，end_sample 缺失则为同一点。零范围在新 input 的 sourceRanges 留空，通过 completeness.legacyAnchors 精确定位；两种 selectionMode 都要核对 canonical 的 source ID/sample。没有证据仍是 unknown，不按旧 complete/gaps=[] 升级。
- metadata/title、speakerLabel 与 template 必须来自明确选用值，不能藏其他原文。主机 context 的 approved* 是受控 fixture 输入，生产必须由现有 UI/私有 store 构造；模型自行提供同名对象不构成授权或权威。
- 旧文稿的非 IANA 时区标识仍保留在私有原始 bytes/hash；新 recordingContext 对不能可靠解释的时区投影为 null，保留文字可整理，不改成设备当前时区。相对日期仍要求说明未知依据，新 Reminder 确认另选有效时区。
- 每种所选结果独立记录状态。全部 committed 才能整体 committed；部分成功且其他类型终结为 partiallyCommitted；仍有类型执行时保持处理中。失败/取消不删除已提交成功项。

## 验证与尚未证明的事实

[参考模块](../../../tools/integration/recording_ai_contract_request.py) 和 [测试向量](request.cases.json) 检查字段间、原始 bytes 与可控执行记录的约束。独立复核补了实际 input 中夹带未选正文、重复键、伪造结束、错误旧点、选区引入别段、all 模式错误旧点及非法时区反例。

context 必需 canonicalBytesUTF8、approvedCompleteness、明确选用 metadata/template；request 另有 inputBytesUTF8，执行关联另有 executionRecords。此处只用虚构数据。它没有原子读取 store/sidecar、真实执行观察、文件权限隔离、工具策略、tombstone 提交排斥或 outbound 模型请求捕获。

结构化输入通过不证明实际模型只收到这些数据；聊天历史、记忆、附件、系统提示和工具读文件仍须在原聊天 adapter 的发送/执行点共同约束。也不能由执行 fixture 的 started=true 宣称真实 run 已开始。C00 冻结后这些检查须进入现有业务入口，并用真实实现和可控替身再验证。
