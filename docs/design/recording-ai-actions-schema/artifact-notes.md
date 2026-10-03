# C00 产物结构与校验提案

状态：**待 Human 交互评审及技术评审，未批准、未冻结、未接入生产**。本文件与 `artifact.schema.json`、`artifact.cases.json`、`tools/integration/recording_ai_contract_artifact.py` 一起补充 [C00 主稿](../recording-ai-actions-contract.md)，不修改 PRD 验收范围。实际页面与最小新增依据见 [现有产品基线](../recording-ai-actions-existing-product.md)。

## 现有接入点与新增边界

- [`RecordingAgentResults.swift`](../../../Integration/App/RecordingAgentResults.swift) 第 19–29 行沿用文件列表及 QuickLook；第 34–66 行扫描 `VoiceContext/Generated/<recordingID>/`，已有真实路径、常规文件及符号链接检查。当前没有 manifest 解码、文件摘要或 typed data 校验，不能把目录中的任意文件称为已提交产物。
- [`VoiceContextRootView.swift`](../../../Integration/App/VoiceContextRootView.swift) 第 80–83 行通过 `newChatRequested` 预填现有聊天草稿。预填与选模板不是实际发送，更不是运行已发生的证据。
- [`AIChatViewModel+Persistence.swift`](../../../Vendor/Phone/src/ios/Agent/Chat/AIChatViewModel+Persistence.swift) 第 1109–1110 行创建并得到真实 `session.id`，第 1128–1146 行迁移草稿别名，第 1166–1170 行发出 `sessionDidCreate`。关联必须等实际发送取得真实会话和 user message 身份；不能持久绑定 `__new__` 草稿 ID。
- [`AIChatViewModel.swift`](../../../Vendor/Phone/src/ios/Agent/Chat/AIChatViewModel.swift) 第 2171–2178 行的 `sessionId` 是字符串、`draftId` 是临时别名；第 5175 行的 `runMsgId` 是 assistant message UUID，第 5442–5446 行可因新气泡更换。它不构成稳定的运行记录接口。[AgentRunEngine adapter](../../../Vendor/Phone/src/ios/Agent/Chat/AIChatViewModel+AgentRunEngineAdapter.swift) 复用工具执行批次，也不提供整个聊天 attempt 的持久身份。AgentStore 的 agents/settings 不能代替运行记录权威。

因此，manifest 的 `runID` 是**拟新增的 attempt UUID**；`sessionID` 保持现有真实会话 opaque string，`triggerMessageID` 是实际发送的 user message UUID。三者在本草案改为正式产物必填，以阻止草稿或助手气泡被当作执行关联。真实发送时建立、取消/中断时更新、重启时恢复的私有关联均尚未实现。新增关联要复用原聊天生命周期，不另造独立运行器。

## Wire 结构

Schema 使用 Draft 2020-12 和共同基址 `https://voicecontext.invalid/recording-ai-actions/`；标识、摘要、source、citation、日期引用 `common.schema.json`。`source` 始终只有 `recordingID/revision/sha256`，kind、发生时间、时区绑定在输入的 `recordingContext` 中。

| 结构 | 必填与含义 |
| --- | --- |
| artifact | `schema/objectKind/artifactID/requestID/runID/sessionID/triggerMessageID/inputSha256/source/type/status/files/coverage/citations/createdAt/data` 必填；`template` 可省略或 null，`warnings` 可省略。 |
| status | 这里只描述可发布对象，唯一值为 `committed`。进行中、校验中、失败、取消及中断保留在 request/typeOutcomes，不放行临时 manifest。 |
| type/data | minutes、mindmap、actions、export 分支严格对应，各分支拒绝额外字段及类型混用。 |
| minutes | `summaryClass/reason/title/summary/discussion/decisions/actions/unresolved` 必填。无决定或行动时相应数组允许空，不虚构事项填满结构；有内容的 summary 和条目必须带引用。 |
| action | `actionID/artifactID/source/title/citations/status=candidate` 必填。owner、到期、定时提醒、列表及 notes 可缺失；相应 nullable 字段保留未知。due/alarm 复用 Reminder schema，不推断列表、负责人或日期。候选不允许系统事项 ID、confirmationID 或完成状态。 |
| coverage | `selectedSegmentIDs/readSegmentIDs/missingSegmentIDs/unresolvedRanges` 必填。源音频无文字的缺口用 source range 表达，不捏造 segment ID。 |
| file | 每项必须有安全相对路径、mediaType、原始文件字节 sha256；重复路径业务校验拒绝。路径语法并不证明真实路径处于受管目录。 |

本轮进一步提案：每个正式 typed artifact 至少声明一份 `application/json` 结构文件，其实际 JSON 必须等于 manifest 的 `data`；fixture 用 `data.json`，该文件名并非契约保留字。JSON 解码拒绝重复键、非 JSON 常量和非法 UTF-8。路径、内容类型、原始字节摘要与结构数据均分别核对。

Markdown/Mermaid 是结构数据的派生阅读/分享文件，应由受管 renderer 从已验证数据生成。参考校验对 `text/markdown`、`text/vnd.mermaid` 要求独立 renderer 观察记录，绑定 artifactID、type、data 的 canonical sha256、声明路径、mediaType 和实际输出字节；文件摘要正确仍不能替代这个关联。**生产受管 renderer 未实现**，fixture 的 `rendererEvidence` 只让“数据正确但 QuickLook 文件被换成另一份事实”的反例可独立检出，不能证明现有模型任意生成的 Markdown 已经符合纪要语义。格式扩展及渲染协议仍待评审。

## 组合校验与独立证据

入口先做 artifact JSON Schema。仅 schema-valid 向量进入 `validate(definition, value, context) -> list[str]`；错误码来自实际校验分支，与向量预期独立。外部证据形状损坏时失败关闭。

artifact 参考入口对 `inputBytesUTF8` 做严格 JSON 解码，校验完整 `request.schema.json#/$defs/input`，再调用 request 的 `validate('input', ...)`：所选文字、顺序、来源范围、metadata/template、来源 kind/timezone 与完整性伴随证据必须匹配独立权威。对 runAssociation 同样先做 schema，再调用共享运行业务校验，核对真实 lifecycle observation。`[]` 输入、伪造 canonical 中没有的正文、running 却带 endedAt 均不能通过。

fixture context 的来源如下，**不可由模型输出提供**：

| context | 独立证据要求 |
| --- | --- |
| canonicalBytesUTF8 | 实际创建输入时保存的完整 canonical 原始 UTF-8 字节；source.sha256 对此计算。向量使用合成 Transcript@1 文稿，不使用用户私人数据。 |
| inputBytesUTF8 | 完整 recording-input@1 实际选定快照字节，不能重新编码后代替原 bytes；inputSha256 对此计算。向量已升级为完整 wire 输入，包含 scope/selectionMode、全部 required 字段及可验证转写范围证据。 |
| approvedCompleteness/approvedMetadata/approvedTemplate/approvedSpeakerLabels | 从 source-matched 私有伴随记录及明确用户选择得到，供 request.input 校验；不是产物自报。整条录音的完整性还需由真实转写服务验证私有伴随记录。 |
| request | 该域使用已绑定请求字段的 fixture 投影（requestID/source/inputSha256/selection/recordingContext/completeness），不是完整 request wire 对象。生产提交入口还需组合完整 request 状态、typeOutcomes 与取消/删除门禁校验。 |
| runAssociation/executionRecord/triggerMessage | runAssociation 为完整 wire 对象；executionRecord 是实际 attempt started/lifecycle 观察，triggerMessage 是真实 user 发送记录。向量只是受控替身。 |
| readEvidence | 实际输入读取工具/执行观察得到 runID、inputSha256 与已读 segmentIDs。模型自己列出全部 readSegmentIDs 不能当作证据。 |
| unresolvedRanges | 已绑定输入/私有完整性伴随证据中需要保留的缺口投影，包括没有文字段的音频范围。 |
| files/rendererEvidence | 受管文件实际 bytes 和类型/常规文件观察；后者为受管 renderer 的独立输出观察提案。JSON 中自报 `kind=regular` 不能替代物理文件检查。 |
| writeAttempts/sourceDeleted | 与该未确认产物关联的独立写入次数及源删除门禁。缺少零写入证据不会默认成 0。 |

`coverage` 的 selected 必须等于请求，read 与 missing 是 selected 的互斥分区；read 必须等于独立观察且摘要一致。发布提案要求所有已有选定文字实际读完，missing text IDs 为空；已知原音频缺口可以继续整理，但必须留在 unresolvedRanges 和含缺失/临时/未知标签。不能把未读尾段改名为原音频缺口。此规则支持长文覆盖验收，不等于证明跨段总结的事实与语言质量已经合格。

citation 必须使用相同 source 三元组并且只指向本次选择。可选半开区间必须有效并处于所引文字范围；跨多个 source asset 的区间不能用没有 asset 身份的单一区间冒充定位，需省略区间或拆分引用。excerpt 如提供，必须是所引原文中的实际片段。引用存在与字面摘录一致仍不能自动证明模型对讨论、决定和行动的分类正确。

纪要标签优先级：个人录音或处理未终结 → preliminary；已终结且选定内容或整条录音任一有已知缺失 → withMissingContent；任一完整性未知或来源 kind 未知 → completenessUnknown；只有 meeting、terminal、选定内容及整条录音均 complete 才可 formal。reason 必须持久保存。局部 complete/整条 partial 或 unknown 的正反例单列，禁止把局部覆盖升级成整份正式纪要。

关键错误分组包括 source/input hash mismatch、run/trigger/lifecycle mismatch、input schema/正文与权威不符、citation source/range/selection mismatch、未读尾段、unresolved range 丢失、文件缺失/损坏/格式或 renderer 不符、summaryClass 不符、未确认写入、源已删除及 P1 树/导出错误。实际 codes 见独立向量与模块。

## P1 未批准提案

- 树采用 flat nodes + parentNodeID，单 root topic、UUID 唯一、单父、全部可达、无环；重复 ID 即使位于不同父节点也拒绝。行动节点必须指向同产物实际 candidate。每个节点含来源引用。
- 暂定最多 1000 节点、body 8000 字符、12 层（根为第 1 层），均是待评审边界，不能据此缩小 F04 的阅读、无障碍或导出验收。
- 暂定 Markdown/Mermaid 导出保存 `originatingArtifactID/type`、所有元素来源映射及原父边；源对象须是独立读取的已提交产物。输入 context 的 origin 还需由实际读取入口完整验证。
- 暂定导出在实际文件内保存一行来源 metadata：Markdown 使用 HTML comment，Mermaid 使用 `%% voicecontext-provenance:`。真实声明的每个导出文件都需含完整 metadata，未列出的旁文件不能代替。只剩结构 JSON 而没有导出文件也失败。这个 header 协议及 renderer 的转义、图语法、布局和可阅读性尚未批准或实现。

## 兼容、提交与验证限制

旧无 manifest 产物继续通过原列表/QuickLook 的独立兼容入口阅读，标记来源/完整性无法核验；不补造正式 manifest、run、来源摘要或 formal 身份。后续索引必须区分历史文件与新运行的 staging/失败文件，不能把所有无 manifest 的新文件都归入历史正式结果。已有用户 Skill 不能被自动覆盖；升级能力和旧入口分别保留，实际迁移实现及回归仍未交付。

run 结束与产物提交是两个状态域：一个类型已提交后，另一个类型失败或取消，不抹掉已提交对象；整体结果由完整 request/typeOutcomes 汇总。参考函数没有执行 CAS、原子多文件发布、提交时取消竞争、源删除 tombstone 或重启恢复。物理 symlink/祖先路径解析、TOCTOU、原子替换均须在真实读写服务及临时目录 fixture 中验证，不能由本模块的 lexical path 和 `kind` fixture 声称已保证。保留删除后的旧产物与“源已删除后新提交”也须分别处理；当前 sourceDeleted 反例只拒绝新发布。

行动仍是候选，零写入规则不等于确认授权。实际确认 payload、精确 listID、due/alarm、幂等及回执由 [Reminder 契约](../recording-ai-actions-reminder-contract.md) 负责；系统完成状态只读 EventKit。候选日期的事实依据和待确认 UI、真实写入/通知效果、完整删除残留审计均是后续验收范围。

验证命令：`python3 tools/integration/verify_recording_ai_contract.py --area artifact`。本轮 **69 组 shape/business 向量通过**，含完整输入组合校验、尾段、未知/局部与整份、文件内容和旁文件导出绕过反例。它们是离线合成 fixture，不能算 C00 已冻结、正式产物实现或 F03/F04/F08 已完成；未启动 iOS、模拟器或 EventKit。
