# Reminder schema 与测试向量说明（未批准提案）

本目录是 C00 评审材料，未冻结、未发布存储格式，未接入生产。以 [Reminder 附录](../recording-ai-actions-reminder-contract.md) 与 [主契约](../recording-ai-actions-contract.md) 为依据。schema/cases/参考校验通过不表示 C00/C10/C11 或 T04/T05 完成，更不表示通知到达。

`reminder.schema.json` 采用 draft2020-12，外部引用 `common.schema.json` 的 uuid、sha256、source、citation、dateTime。source 严格只有 recordingID/revision/sha256，artifactID/citations 在 confirmation envelope；每条 citation 有自己的 source。新生成 UUID 用小写，schema 接受大小写以兼容已有标识。EventKit ID 是不透明字符串。

## Schema 能表达的边界

- due 与 alarm 自身可为 null；due 非空时 date/time/timezone 全部必填，date-only 必须 time:null，不能省略 time。alarm 非空只支持单个 absolute instant，必须带 RFC3339 offset 与 IANA zone。
- payload 复用当前 editor 的标题、列表 ID、due/alarm 独立开关、备注、priority；禁止额外 recurrence/location/multi 字段。sourceMarker 此轮只编码 URL carrier，scheme 由既有 build identity 决定，不加配置。其他载体仍待评审，不隐式变成已支持。
- confirmation 保留完整内容；prepared/confirmed/failedBeforeSave/saving/saved/savedWithDifferences/needsReconciliation/cancelled 使用不同字段约束。可空字段固定保留 null；saving 需要 attemptStartedAt，saved 需要真实 receipt 与 reminderID，savedWithDifferences 需要实际差异。
- receipt/actualReminder 保存 raw components 的未设置 null、秒与亚秒，以及 iana/offset/floating；读取既有事项不套用新确认的 IANA 输入限制；actual 非 Gregorian 成分原样保留、不按 Gregorian 解读或重构，不能与新确认的 Gregorian due 判为相同。全部 alarm 的 absoluteDate/relativeOffsetSeconds/structuredLocation/proximity 保留，不把 relative offset 0 丢掉，不因分类丢其他字段。
- externalObservation 的 available 下有真实 isCompleted；完成不另设读取枚举。permissionDenied/unreadable/identityUnresolved/deleted 分开。来源状态独立，不因来源删除删除系统事项。
- minimalIdentity 是清理后的独立身份记录，不冒充完整 confirmation；只有确认/action 身份、状态、sourceDeleted=true 与可选 reminderID，不能保留 payload/citations 或恢复创建权限。具体持久载体/迁移仍未批准。

此轮尚未冻结的 wire 细节：`differences` 暂为文本数组；confirmation 使用主稿的 `error`，不另造 lastError 别名；receipt 的 isCompleted 是 observedAt 时的实际快照；recurrenceRules 每条仅约束为非空 object，不定义新的重复规则模型。recurrence schema 通过**不足以**证明复杂规则完整、可往返或可安全修改；生产需保留原 EventKit 对象或明确拒绝，不能用旧 CLI 的 first recurrence 重建全部规则。

## 参考业务校验与独立 context

[`recording_ai_contract_reminder.py`](../../../tools/integration/recording_ai_contract_reminder.py) 导出 `validate(definition, value, context) -> list[str]`，仅对结构已经合法的评审 fixture 做参考检查，不读磁盘业务数据、不构造 EKEventStore、不授予权限、不保存或创建事项。它不是生产服务；缺 context 表示未评估该外部事实，绝不表示已经授权或已经证明未创建。

| 必需业务能力 | 本次参考入口/向量 | 生产仍需证明 |
| --- | --- | --- |
| 严格 Gregorian、有效 IANA、DST unique | `_due_errors` 以 ZoneInfo 两个 fold 往返核对；无效日期、gap/fold、唯一时分 | Swift/Objective-C 使用同一规则与测试向量；不依赖 rollover |
| absolute alarm 的 offset 与 zone 一致 | `_alarm_errors`；两个重复时分的不同 offset 都接受，错误 offset 拒绝 | UI 先确定真实 instant；EKAlarm 不保存展示 zone，不能伪称其为 actual 字段 |
| 精确列表与两层权限 | `_payload_errors` 与独立 targetList/fullAccess/toolAllowed context | 真实执行点读取当前列表、系统授权和 offload 策略，包含间接工具调用 |
| immutable canonical hash | common.payload_hash 绑定 actionID/artifactID/source/citations/payload；固定 UTF-8/中文换行、null/空备注向量 | 多语言 exact bytes 与同 ID 不可改；不允许用重编码的“等价”内容替换已确认 bytes |
| 来源、段 ID、引用范围 | `_confirmation_errors`；跨版本引用、范围倒置、大小写 UUID 重复、unknown segment | 解析实际权威快照；context.expectedSource/sourceSegmentIDs 来自独立 fixture，不由 value 自证 |
| 真实回执与实际设置 | `_receipt_errors`、`_matches_payload`；requestID alias、ID/映射冲突、floating/offset/亚秒、due 不算 alarm、relative/location | save 后真正 refresh/read；完整列表、due/start、全部 alarm/规则与 marker 核对，不能用请求填 actual |
| 独占、未知结果与永久身份 | `_confirmation_errors`；未持久意图、无独占、saving/unknown/saved 禁止再次 create、来源删除撤销 | 真正跨进程 CAS/锁、durable journal、App/Agent 重启、所有中断点；fixture 中 boolean 不是锁证据 |
| 外部删除与只读失败 | `externalObservation`；nil query、权限拒绝、零匹配、已核实删除分别编码 | ID nil/refresh false/零匹配不等于删除；完整跨列表查询与 marker 身份证据；未知绝不自动补建 |

case 是裸数组，每项含 name/definition/value/schemaValid/semanticValid，可含 errorCode/context。schemaValid=false 的 case 不调用参考业务校验；schemaValid=true 且 semanticValid=false 必须实际检出标注的 errorCode。通过结构与业务向量仅覆盖已明确的规则；unsupported recurrence wire、原子持久化、权限 dispatch 与 EventKit 的真实行为仍未实施。

context 是测试驱动提供的独立外部事实：targetList 的 id/exists/writable、当前 fullAccess/toolAllowed、expectedSource/sourceSegmentIDs、existingPayloadHash/existingActionBinding、intentPersisted/exclusiveReservation、saveAttempted/priorState/sourceDeleted/attemptCreate、readbackSucceeded/saveSucceeded/actualReminder/confirmedPayload/expectedMarkerURL、query.complete/matchedIDs、deletionEvidenceVerified。goldenCanonicalUTF8 仅为固定测试向量的人工查验材料。query 零/部分结果永远不能作为再创建许可；本参考模块也不把这些字段解释为授权票据。

## 本轮验证

```sh
python3 tools/integration/verify_recording_ai_contract.py --area reminder
```

已离线验证 81 个 Reminder 结构/业务向量；schema 自检、引用解析、RFC3339 格式与指定 errorCode 均通过。脚本只读这些评审 JSON 与标准库时区数据，没有生产持久读写、EventKit、设备/App 运行、私人提醒读取或通知观察。后续校验以重跑输出为准，不将本文的通过记录代替技术冻结或真机证据。
