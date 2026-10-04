# 录音 AI 行动闭环：机器契约评审材料

日期：2026-10-03。**未批准、未冻结、未发布存储格式、未接入生产。** 依据 [C00 主稿](../recording-ai-actions-contract.md)、[现有产品基线](../recording-ai-actions-existing-product.md)、文稿与 Reminder 附录。新增流程仍需 D01/D02/D04/D05/D06 评审；本目录不改变原 PRD、Plane 状态或已有存储。

| 文件 | 约束与配套 |
|---|---|
| [common.schema.json](common.schema.json) | source 三字段、UUID、SHA-256、RFC3339、引用、16 kHz 来源范围；源版本/范围整数使用 Int64 边界 |
| [request.schema.json](request.schema.json) | 选定输入、真实聊天发送关联、请求多类型状态；[说明](request-notes.md)、[向量](request.cases.json) |
| [transcript.schema.json](transcript.schema.json) | 伴随完整性、音频预检、候选/采纳/历史、删除墓碑；[说明](transcript-notes.md)、[向量](transcript.cases.json) |
| [artifact.schema.json](artifact.schema.json) | 已提交 manifest、文件、覆盖、引用、纪要/行动/P1 导图及导出；[说明](artifact-notes.md)、[向量](artifact.cases.json) |
| [reminder.schema.json](reminder.schema.json) | due/alarm、固定确认、实际回执、读取状态、来源清理后最小身份；[说明](reminder-notes.md)、[向量](reminder.cases.json) |
| [兼容说明](compatibility-notes.md) | 实际旧文稿 decoder/store、原 bytes 身份、已有 Skill/模板安装与两套历史产物目录的复用边界 |

均采用 JSON Schema draft2020-12；`.invalid` ID 仅用于离线解析身份，不访问服务器。这些文件是定义库，根节点本身不是对象校验入口。完整对象须引用对应公共 `$defs`（例如 request/input、artifact、confirmation/receipt、transcriptEvidence）；artifactBase 等内部组合定义或单个 primitive 均不能作为完整对象验收。Schema 不替代业务范围比较、来源 bytes、当前版本、真实读取或持久独占。

## 重跑

在仓库根目录运行，Python 需要 jsonschema/referencing：

```sh
python3 tools/integration/verify_recording_ai_contract.py
bash tools/integration/test_recording_ai_hash.sh
```

第一条离线验证 schema、外部引用、格式与指定业务 errorCode，同时执行 Python canonical 向量；参考业务模块位于 tools/integration/recording_ai_contract_*.py。输入、执行、读取、查询和文件事实均来自可控 fixture，不读取私人文稿、提醒或凭据。第二条只编译/执行 macOS 主机 Swift/Objective-C 参考编码器，对 [24 个编码向量](canonical-hash.vectors.json) 比较逐字节 JSON、SHA-256 或拒绝原因（15 个成功、9 个拒绝）；不启动 iOS、模拟器或 EventKit。

2026-10-03 全域输出：5 个 schema、249 个向量通过（request 41、artifact 69、transcript 58、reminder 81）。产物参考入口已组合严格 input 解码、canonical 正文投影、runAssociation 及实际文件/data/renderer 证据校验；独立审阅的全录音标签、伪造输入/运行、导出旁文件反例均被拒绝。结果以重跑命令为准，不把参考向量通过记作生产任务完成。

编码向量覆盖非 ASCII 键的 scalar 排序（区别 UTF-16/locale 排序）、NFC/NFD 键和值保持区分、中文/emoji、全部 C0 必需转义、null/缺字段、布尔/整数、数组顺序、Int64 上下限及超出 2^53 的精确整数；拒绝 float、非有限数、越界整数和孤立 surrogate。Swift 使用原 NSString/NSDictionary，Objective-C 按有效 UTF-8 排键，均不依赖 `.sortedKeys` 或 Swift String 的归一化字典相等。三种主机参考实现的共享向量通过，不等于生产 codec；原始 JSON 重复键/数值词法的严格解码、真实业务类型与持久确认服务接入仍未实现。

## 接入与迁移仍需完成

当前生产路径仍使用旧文稿、可变 Source、聊天草稿、Generated 文件和 EventKit CRUD。schema 不会自动迁移这些数据，也不为历史无 manifest 文件或无确认身份事项补造成功记录。旧文件继续通过现有 QuickLook 历史入口；已有用户 Skill/模板不覆盖，会议确认不能退回不具备身份的旧 create。

后续技术冻结还需将完整 request 状态与产物发布组合，确定并实现 Markdown/结构文件及导出的受管渲染器，定义复杂 recurrence 的完整回读 wire，完成旧能力 adapter/受管模板版本升级与历史产物关联，并将规则接入真实业务类型/服务。已有安装器的缺失文件补齐与保留策略已单列主机验证，不冒充 C04 完整升级。参考组合检查中的可信 context/renderer 记录不是生产输入或实际渲染器，也不能证明跨模块服务接入已成立。

参考检查没有实现跨进程锁/CAS、崩溃持久化、EventKit 保存/回读、重启核实、删除提交排斥、ASR 证据、模型实际传递或物理路径打开。尤其是 intentPersisted/exclusiveReservation/readbackSucceeded 等 fixture boolean 不是这些能力的证明。后续 C01–C13/T01–T07 必须用实际业务实现验证；真机运行仍需该次明确授权，未运行 iOS。
