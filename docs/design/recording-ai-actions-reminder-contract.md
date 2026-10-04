# Reminder 契约评审附录（C00 未批准提案）

状态：**待 D04/D05 交互评审与 C00 技术评审，未批准、未冻结、未实施。** 本文日期为 2026-10-03，是 [C00 主草案](recording-ai-actions-contract.md) 的 Reminder 附录。示例字段、接口名称及持久化格式都是提案；本文件不会改变现有 CLI 参数、用户 Skill 或已保存数据，也不代表 C10/C11 验收通过。

依据：[PRD F05/F06/F07、§7 与验收案例](../PRD-recording-ai-actions.md)、[C00/C10/C11 任务](recording-ai-actions-delivery.md)、[DESIGN.md](../../DESIGN.md)。交付顺序仍为交互评审 → 契约冻结 → 实施与验收。

## 1. 已有能力与最小增量

以当前仓库代码为基线；下表“已有”含本轮已完成的缺陷修复，不能推广为完整新契约已经可用。

| 复用位置 | 已有行为 | 契约所需最小增量（待批准） |
| --- | --- | --- |
| [SystemRemindersView.swift](../../Integration/App/SystemRemindersView.swift) / `SystemRemindersModel` | 待办页有日期概览、全部分组、来源筛选、完成/恢复、删除及原生编辑 Sheet；直接读写 EventKit；进入前台及 EventStoreChanged 刷新；独立授权请求状态 | 保留页面及 CRUD。把写入/查询语义接到同一执行服务；在现有详情增加会议来源和真实读取状态，不建第二套待办页或任务完成数据库 |
| 同文件 / `ReminderEditor` | 以 calendarIdentifier 选择可写列表；独立“到期日期/到期时间”和“定时提醒”；用户未改的字段保留；重复、relative/location/multi alarm 的时间编辑被禁止，标题/备注仍可编辑 | 从现有编辑字段生成确认 payload；显示目标列表账号、时区和实际结果差异；保存后统一回读。会议候选确认复用字段与校验，具体布局仍由 D04/D05 决定 |
| [ReminderDateEditing.swift](../../Integration/App/ReminderDateEditing.swift) | 仅修改用户触及的日期/时间成分；新建采用 Gregorian；既有 floating timezone 保持 nil；未改秒/亚秒保留 | 复用成分补丁规则，新增确认时的严格日期/时区校验；不要先转设备本地时间再重建全部成分 |
| [CalendarOffload.m](../../Vendor/Phone/src/ios/NativeOffloads/CalendarOffload.m) / shared reminder handlers | 两个工具共用 reminder CRUD；`--list` 采用唯一全名匹配，不存在/歧义/只读失败；`--due` 严格校验；保存后 refresh 并返回实际字段；nil fetch/超时失败 | 用 adapter 接统一的精确 listID、确认身份和恢复接口；保留旧输出。现有函数不具备持久幂等日志，不能据此声称 F06 已实现 |
| [RemindersOffload.m](../../Vendor/Phone/src/ios/NativeOffloads/RemindersOffload.m) | `apple-reminders` 委托上述 shared handlers；提醒工具当前没有 `--list-id` 或独立 `--alarm` 参数 | 经 C00/D05 批准后才增加参数或受控结构化入口；不能只改 help 就宣称支持 |
| [OffloadPermissionManager.swift](../../Vendor/Phone/src/ios/Agent/Offload/OffloadPermissionManager.swift) | 按工具有 Bypass / Ask Once / Not Allowed；首命令 basename 识别绝对路径；代码已注明不覆盖 shell/script/subprocess 间接调用 | 保留权限策略与提示。C11 在真实 native 执行点执行同一策略，且受控确认身份独立校验；首命令解析不能作最终权限边界 |
| [VoiceContextRootView.swift](../../Integration/App/VoiceContextRootView.swift) / `onOpenURL` | 已有产品/Dev scheme 与会议入口；当前只处理 start/stop recording；既有 results 通知可定位 recordingID | 增加经过本机关联索引解析的 recording/source-version 路由；URL 不能触发写入，不能误称现有 recording 深链接已经支持 |

现有 UI 的评审差异：列表 Picker 只显示 title，同名跨账号列表需显示账号；行只显示第一项 absolute alarm，不足以说明 relative/location/multi 的实际设置；alarm DatePicker 使用设备显示时区而 due editor 使用 due 时区，需明确各自时区。`editableReminder` 的 ID 未找到或 refresh 失败当前均提示“已删除”，新关联流程不能沿用该判定；编辑器当前保存即提示成功，尚无实际回执核对。整体原生单列、平铺列表与 DESIGN 基线一致；新增状态文案和来源入口须评审，无需重建现有通用待办页。

## 2. 权威与标识

EventKit 是事项标题、列表、时间、alarm 和完成状态的唯一当前权威。关联索引只保存来源、确认身份、系统 ID 和最近观察证据；历史回执是某次读取的快照，不能当当前完成状态。`recentlyCompleted`、busyIDs、loading 等现有短期 UI 状态继续只用于呈现。

提案以一个 UUID `confirmationID` 表示一次已确认的创建操作；PRD 的 Reminder `requestID` 在此边界指同一身份，接口回执中两者值相同，不再生成两个互不约束的创建 ID。它不同于 AI 整理的 requestID。一个 actionID 默认只绑定一次创建确认；重复确认读取既有 operation。用户明确“另建一项”产生新 actionID 和 confirmationID，并保留原关联；同标题不用于去重。

source 固定为 recordingID、revision、sha256；artifactID 与 citations 是确认 envelope 的独立必填字段，每条 citation.source 绑定同一 source，引用必须属于绑定版本。仅有录音标题、模型输出、命令权限或一段带 confirmationID 的文字均不能建立已确认身份。

| 新增记录/字段 | 复用点与最小目的 |
| --- | --- |
| `confirmationID` / `payloadHash` / `state` / `version` / `attemptStartedAt` | 给现有创建执行点加可恢复预留；不把 busyIDs 或按钮 disabled 当持久独占 |
| `actionID` / `source` | 沿用会议产物和录音稳定 ID；仅索引来源，不复制原文，不新建任务完成状态 |
| `reminderID` / `receipt` / `lastError` | 从现有 actual read helper 增量编码；字段来自真实对象，错误来自真实失败点 |
| `listID` / `listDisplay` | 沿用 editor 的 calendarIdentifier；display 是用户确认的名称/账号快照，执行只按 ID 查找 |
| `due` / `alarm` / `notes` | 复用 editor 独立开关和现有日期补丁；新创建写完整已确认值，既有编辑写明确 patch |
| `sourceState` / `observedState` | 分别描述关联可达性与 EventKit 当前可读性；不持久保存第二份 completed 权威 |

## 3. 具体确认 payload

确认屏必须展示实际将写入的标题、目标列表名称及账号、到期日期/时间/时区、独立通知、备注和来源。负责人原文/不确定性是会议候选信息，EventKit 没有对应字段：未确认写入备注前不得自动拼进标题或 notes。无日期和负责人未知保持可见空值；相对日期按录音发生时间及所选时区解释，不按生成当天猜。

下列 JSON 为新建一项的非生产示例；ID 和全零 source.sha256 仅展示形状，不指向真实文稿。payloadHash 由确认服务对完整 canonical bytes 计算：

```json
{
  "confirmationID": "822eaf46-818e-4f0e-bb20-0ab36a8cfe5c",
  "actionID": "5bbf7e64-e67a-4d6f-ab64-408061357142",
  "source": {
    "recordingID": "9ee27674-9f92-49f7-b0e0-d1917760e62a",
    "revision": 3,
    "sha256": "0000000000000000000000000000000000000000000000000000000000000000"
  },
  "artifactID": "d4d22575-d19e-4a9f-871e-35b1b36c7a19",
  "citations": [{
    "source": {
      "recordingID": "9ee27674-9f92-49f7-b0e0-d1917760e62a",
      "revision": 3,
      "sha256": "0000000000000000000000000000000000000000000000000000000000000000"
    },
    "segmentIDs": ["02d14bba-6c3b-4758-9607-29983068098d"],
    "startSample": 96000,
    "endSample": 144000
  }],
  "payload": {
    "operation": "create",
    "title": "发送预算草案",
    "listID": "eventkit-list-opaque-id",
    "listDisplay": {"name": "工作", "account": "工作账号"},
    "due": {"date": "2026-10-09", "time": null, "timezone": "Asia/Shanghai"},
    "alarm": null,
    "notes": null,
    "priority": 0,
    "sourceMarker": {"carrier": "url"}
  }
}
```

持久记录另含必填 `payloadHash`、`createdAt`、`confirmedAt`、`state` 和单调递增 `version`。执行前必须解析真实快照中的 ID、半开 sample 范围及来源 hash。所有时间戳采用带 offset 的 RFC3339；新生成 UUID 统一小写字符串；EventKit ID 为不透明非空字符串，不能改写大小写。

字段规则：

- 标题先按现有 editor 规则去两端空白，再显示供确认；空标题拒绝。notes 的 null 表示新建无备注，空字符串是明确空备注。已确认 payload 不在执行时再次改写或追加模型内容。
- 新确认必选精确 listID。可用默认列表时，先解析出 ID 并显示在确认屏；点击确认后默认列表变化也不能改投另一列表。缺失、失效、只读或无权限均在保存前失败。
- `due=null` 表示无到期；非空 due 必须有严格有效 Gregorian 日期。`time=null` 表示 date-only，hour/minute/second/nanosecond 不设置；有 time 的提案格式为 HH:mm，秒和亚秒明确为零。新确认必有有效 IANA 时区。遇到 DST 不存在或重复的本地时间一律拒绝，要求改选无歧义值；当前提案没有 offset/fold 选择字段，不声称可选择重复时分中的某一次，也不依赖 Calendar 自动 rollover。
- `alarm=null` 表示无定时通知；首轮新建支持至多一个独立 absolute alarm，形状为 `{at: RFC3339, timezone: IANA}`。offset 必须与所选时区在该瞬间一致；带 offset 的 RFC3339 已确定唯一瞬间，不能仅因本地时分重复而拒绝。若 UI 只提供有歧义的本地时分且尚未确定瞬间，则先要求明确值，不自行选择。允许无 due 但有 alarm；单有 due 不产生 alarm。绝对瞬间之外的展示时区属于确认日志，不伪称 EKAlarm 自带时区。
- 新建不接收 recurrence、location、relative 或多 alarm。现有复杂事项可完整读取；未修改的字段全部保留，需要修改不支持的组合时在写前拒绝。现有能力可由系统提醒事项继续调整，不能把复杂组合静默压成一个 absolute alarm。
- iOS 有 due 时还需 start，采用 Gregorian；新建提案 start=due，作为确认说明/回执字段，不另造开始时间。既有 start 未改则保留，不为改标题重置它。
- `sourceMarker` 是已确认写入的一部分。URL 空闲时可写 `voicecontext://recording/<recordingID>?confirmation=<confirmationID>`，Dev 用 `voicecontext-dev`；scheme 复用现有 build identity，不作为新增配置或由 Agent 自选。已有 URL/notes 不覆盖。其他载体需显示后确认；如果没有批准的标记策略，先失败，不进行无法可靠恢复的新来源创建。

payloadHash 提案为 SHA-256(canonical UTF-8 JSON)：对象键按 Unicode 标量排序、数组保留顺序、无空白、非 ASCII 直接 UTF-8、字符串只作 JSON 必需转义、不作 Unicode/大小写/时区再归一化、数值只允许约定整数字段；纳入 actionID、artifactID、完整 source、citations 与 payload，排除 hash 自身和执行状态。所有可空字段固定保留 null，缺失字段拒绝，null 不与省略混同。冻结时必须提供 Swift/Objective-C 相同测试向量。确认服务保存当时完整 bytes 与 hash，执行只接受该记录；相同 confirmationID 改 title/list/time/source 等任何绑定字段返回 payloadConflict，需新的明确确认。

受信任的 UI 确认动作或受控 Agent 确认回调建立 confirmed 记录。Agent 可以准备/展示候选和请求执行已确认 ID，不能从对话摘要、共享文件或 URL 自行写 confirmed。一次具体批量确认足够，每个被选行动独立记录与回执；未选择、取消为零写入。

## 4. 保存后实际回执

复用 `reminder_to_dict`、`reminder_due_dict` 和 model 的真实查询，增量形成下列字段。回执必须在 `saveReminder(commit:true)` 后读取，不能把请求 JSON 原样标为 actual。保存成功但读取或持久保存回执失败进入 needsReconciliation。

| 回执字段 | 来源/约束与现有兼容 |
| --- | --- |
| `confirmationID`、`requestID`、`actionID`、`observedAt` | 私有确认日志；requestID=confirmationID；不是从事项 title/URL 推断的授权 |
| `reminderID`、可空 `externalIdentifier` | EventKit calendarItemIdentifier / external identifier；保留旧 CLI `id`；external ID 只作辅助证据，不假设唯一或永不变化 |
| `title`、`listID`、`listName`、`account`、`accountID` | 实际对象及实际 calendar/source；旧 `list`、`list_id`、`account` 继续可读；listID 变化如实报告 |
| `due.components`、`start.components` | year/month/day/hour/minute/second/nanosecond、calendar identifier，未设置值保持 null；不得丢亚秒。旧 `due_components` 继续保留 |
| `due.hasTime`、`due.timezone` | 时区提案 `{kind: iana|offset|floating, identifier: string|null, offsetSeconds: integer|null}`；直接 DateComponents.timeZone=nil 即 floating，不能用设备或 calendar 时区代替。offset 是该日期可计算时的 offset，否则 null；旧 `due_has_time`/`timezone` 保留兼容含义 |
| `alarms[]` | 全部 alarm，逐项 absoluteDate、relativeOffsetSeconds、structuredLocation（名称/经纬度/半径）及 proximity；无设置为 []，不只读第一项。保留既有 CLI alarms，不声称当前 helper 已提供新 schema 全字段 |
| `hasTimedAlarm` | 非 location 的 absolute 或 relative alarm 存在才为 true；due 单独不算。relative 不能冒充 absolute；不能证明具体通知到达 |
| `recurrenceRules[]`、`notes`、`URL`、`priority` | 实际完整读取；旧 CLI recurrence 只编码 first rule，并不等于完整新回执。既有复杂规则编辑应保留原 EventKit 对象，不依赖有损重构 |
| `verification`、`differences[]` | `matchesConfirmedPayload` / `savedWithDifferences`；对照已确认标题、精确列表、due/start、实际 alarm、标记等。系统变更、alarm 截断或读取后外部变更如实记录 |

nil due/start 返回 null；date-only 不能为便利展示填 midnight time。实际读取允许 IANA、固定 offset 或 floating，区别于新确认只接受明确时区。derived ISO/日期字符串仅供展示，raw components 是核对依据；当前 CLI `timezone` 的兼容字符串不能当完整 floating 判据。alarm absoluteDate 是瞬间；其展示时区来自确认记录或明确展示选择，receipt 不把它称为 EventKit 保存的 alarm timezone。

`savedWithDifferences` 仍表示**已有系统事项**，不能作为创建失败自动再建。UI 说明哪些要求不同，后续仅对已存在 ID 作新的明确编辑确认或打开系统事项。读取成功只能证明设置；系统通知权限、专注模式、投递及用户看到通知需要 T06/T07 的授权真机观察。

SDK 依据：本机 iPhoneOS26.5.sdk 的 `EKReminder.h` 明确 Gregorian、nil timezone=floating、iOS due 必需 start；`EKCalendarItem.h` 明确 ID 非 sync-proof，且 `addAlarm` 说明保存可截断超出日历支持数量的 alarm；`EKEventStore.h` 指出成功保存后对象字段更新为数据库值、fetch callback 可为 nil。参见 [Apple due 组件](https://developer.apple.com/documentation/eventkit/ekreminder/duedatecomponents)、[Apple ID](https://developer.apple.com/documentation/eventkit/ekcalendaritem/calendaritemidentifier)、[Apple alarm 添加](https://developer.apple.com/documentation/eventkit/ekcalendaritem/addalarm(_:))。本次仅阅读 SDK，未执行 EventKit、授权或读取私人事项。

## 5. 持久独占与中断恢复状态机

EventKit 和本地日志没有共同事务。不能以“原子写文件”或进程内 actor 代替跨进程独占。提案复用一个本机私有创建日志/关联索引；具体文件或数据库载体待 C00 审查，不存凭据、原文摘录或第二份完成权威，不放入 Agent 可改写的共享文稿目录。

每个 confirmationID 有持久唯一键，并有唯一 actionID→confirmationID 的创建绑定，防止不同入口给同一行动另发确认 ID 绕过幂等。按 state/version 作 compare-and-set；所有 UI、Agent、CLI adapter 只能调用同一预留入口。执行期间还需跨进程 OS 锁或单一写入 owner，禁止两个执行者分别从 confirmed 新建。数据库唯一键/锁/文件事务如何实现须在冻结时选择一种最小方案并证明进程间有效。创建日志不能写入/校验失败时，禁止调用 EventKit。

| 写入状态 | 条件/可执行动作 | 禁止行为 |
| --- | --- | --- |
| `prepared` | 候选或确认草稿；可改/取消；尚无受信任确认 | 创建系统事项 |
| `confirmed` | 具体 payload 已确认并持久保存；执行点重查来源许可、系统/工具权限、列表和校验 | 相同 ID 改 payload；仅靠名称模糊去重 |
| `failedBeforeSave` | 证明保存函数未调用：校验、授权、列表或持久预留前失败；修复后可重试同一已确认 payload | 用户改了字段后仍沿用同一确认身份 |
| `saving` | CAS 从 confirmed/failedBeforeSave 预留成功；**持久保存 saving、完整 payload/hash、attemptStartedAt 后才调用一次 EventKit** | 没有持久意图就保存；另一个调用再创建 |
| `saved` | 成功回读实际对象；关联、回执与 saved 状态本机原子提交 | 对重试再次 create；把历史 completed 当当前状态 |
| `savedWithDifferences` | 已成功读取，但实际设置与确认不同；保存差异，待用户处理现有对象 | 因差异自动再建或静默补参数 |
| `needsReconciliation` | saving 后崩溃、超时、通信/读取/本地提交失败；或当前对象/标记查询冲突 | 自动重建，锁租约过期后重建，零匹配后补建 |
| `cancelled` | 未进入 saving 时用户取消；零写入 | 后续 Agent 回调恢复为 confirmed |

一旦保存调用已经开始，即使 error 返回或调用线程被取消，默认需核实；不能仅从缺 ID/error 文本推断无写入。只有能证明调用前失败才进入 failedBeforeSave。saving 持久化后但调用前崩溃也保守核实；这种保守停留用于防重复，不宣称无损自动重试。新的调用看到 saving/needsReconciliation 返回 existing operation 和待核实状态，不能 create。进程退出释放 OS 锁，**不会**清除持久 saving；lease/超时用于释放执行资源，不能授予新的创建权。

恢复顺序：

1. 从私有日志核对确认身份、payload hash、状态/版本。日志缺失或损坏不能凭 URL/模型文字还原写入授权；先返回待核实/日志错误。
2. 优先按既有 reminderID 获取并 refresh；身份仍匹配则读取实际对象、修复映射并返回同一 operation 的最新观察。已发生外部编辑时保留真实差异，不能拿请求 payload 覆盖它。
3. 单次 ID lookup=nil/refresh=false 不能叫 deleted。完整同步可能改 ID；在完整授权与成功查询下，按来源 marker、已存 ID/external ID 等证据核对。查询涵盖当前全部可读提醒列表（不能只限原列表，因为事项可移动），不能使用 UI 筛选、completed-only、`--limit` 或分页未结束的结果证明零匹配。nil、超时、权限变化、部分列表不可读均为未完成查询。
4. 唯一 marker 对象只是候选证据：核对来源/确认记录及现有映射，冲突或疑似复制/用户改 marker 仍待核实；多匹配返回 conflict，不自动挑一个。**saving/needsReconciliation 后零匹配仍禁止自动补建**：从未保存、已保存后外部删除、标记被改不能可靠区分。
5. saved 身份永久不回到可创建状态。系统删除/来源删除不会解除这个幂等约束；保留最小 operation/映射身份，按保留策略清除正文和不可保留来源信息，包括 citations/快照及日志中的完整 payload。来源 tombstone 后未进入 saving 的确认不得再执行；已进入 saving 的操作只核对已有系统结果，缺少正文时也不改用自动新建。明确另建走新 actionID/confirmationID 与新确认。

marker 是可编辑查找线索，不是不可伪造身份、授权票据或绝对“恰好一次”证明。主方案只能承诺同一已确认操作不会被服务自动再次 create；无法核实时允许停在 needsReconciliation。禁止依赖标题相似度、创建时间接近或“没查到”实现自动恢复创建。

## 6. 统一服务入口与读取状态

这些是现有业务层的最小职责接口提案，不要求新建通用架构层。生产类型/Swift-Objective-C 桥接名在冻结时决定。`SystemRemindersModel` 继续驱动 UI，shared native handlers 继续给两个 CLI 复用；两者 adapter 必须调用同一实现和错误语义。

| 接口职责（名称提案） | 输入/结果 | 复用点与最小改动 |
| --- | --- | --- |
| `listTargets` | 实际 listID/name/account/read-write 及系统授权状态 | 复用 calendars(for:.reminder)；editor Picker 补账号；不能把 nil/error 当 [] |
| `prepareConfirmation` / `confirm` | 固定 source/action 与 payload → 草稿/受信任 confirmed 身份 | C09 现有会议结果入口扩充候选；复用 editor 字段；不触发系统写入 |
| `executeConfirmed` | confirmationID + payloadHash → operation/实际 receipt/可解析错误 | 唯一来源创建入口；复用现有构造/日期/保存/读取，但增加持久独占与校验；Agent 不能直接绕回原始 create |
| `reconcileConfirmation` | confirmationID → 查询证据/修复后的 operation | 复用 EventKit ID/完整查询；仅核对，结果不明禁止新建 |
| `readReminder` / `refreshAssociations` | reminderID + 可选确认身份 → observedState + 实际对象 | 复用 model refresh 与 shared read helper；补完整 alarm/规则；来源关系单独返回 |
| `updateReminder` / `completeReminder` / `deleteReminder` | 精确 ID、明确字段 patch/目标 completed 值；返回实际读取或 unknown | 复用现有 CRUD；保存前重读权限/列表，未改复杂字段保留；关联事项修改不另建；toggle 由 adapter 解析为明确目标值，重试不再次取反 |

普通手工新增继续从现有 editor 发起，不强制要求会议 source；来源创建才要求会议 source/引用。若普通创建接入持久 operation，也只能使用同一写入服务与明确用户动作，不凭空造会议关联。迁移完成前，旧无身份 create 仍是不带持久幂等保证的接口，会议确认路径不能降级调用它。

读取状态提案：`available`（真实字段含 isCompleted）/ `permissionDenied` / `unreadable` / `identityUnresolved` / `deleted`。deleted 仅在同一服务已确认删除该对象，或具备足够核对证据后使用；完整零匹配也可能只是失去关联标记，应返回 identityUnresolved。权限撤回不是删除；外部移动读取真实新 listID；恢复授权只刷新，不补建。来源状态另为 available/updated/deleted/unresolvable，source.deleted 默认保留系统事项，来源回跳给出解释。C13 接入 C12 的 tombstone/保留策略，不在 C10 独自重做整条删除链。

可解析错误至少包含 code、phase、confirmationID（适用时）、systemReminderID（已知时）、retryDisposition 与原始 SDK domain/code（适用时）。code 候选：invalidPayload、payloadConflict、sourceUnavailable、listMissing、listAmbiguous（旧名称 adapter）、listReadOnly、permissionDenied、toolPolicyDenied、unsupportedSchedule、journalUnavailable、readUnavailable、needsReconciliation、identityConflict。重试指引仅 `safeBeforeSave` / `queryOnly` / `newConfirmationRequired` / `none`；“保存失败”文本不能暗示可安全再次创建。

两层授权均在真实执行点检查：iOS Full Access 是访问条件，现有工具的 Not Allowed/Ask Once 是 Agent 调用条件；已经允许工具不等于已确认具体会议 payload。UI 原生编辑遵守其既有直接用户动作；Agent 直接/间接 shell 调用必须遵守同一工具策略。建议新接口明确 caller context，不允许 caller 自报“已授权”替代受控回调。

## 7. 兼容与迁移边界

| 当前接口/数据 | 过渡规则 | 尚未具备的能力 |
| --- | --- | --- |
| `apple-reminders` 和 `apple-calendar` Reminder 子命令 | 保持共享 handlers、现有名称与旧字段；新增字段兼容追加，旧消费端忽略未知字段 | 当前无独立 Reminder `--alarm`、无 `--list-id`、无 confirmation/requestID 持久接口；event `--alarm` 不等于 reminder alarm |
| 旧 `--list <name>` | 精确唯一全名匹配；明确空名/不存在/同名歧义/只读失败；只有 create 未指定列表可按旧规则取系统默认，实际回执返回 ID | 新来源确认不能把 name 当最终写入目标；先解析/show ID 后冻结到 payload，执行重新验证该 ID |
| 旧 `--due` | 保留有效 ISO/relative 输入；date-only 无 time，无效 rollover 保存前拒绝；仅 due 不写 alarm | relative 参数在旧工具仍按调用时刻计算；会议候选先按录音时间解释为具体时间，不能复用相对 CLI 造成跨天变化 |
| 旧 CLI receipt | 保留 id/title/completed/list/priority/notes/location/recurrence；增补 list_id/account/due/due_has_time/timezone/due_components/alarms/has_timed_alarm | 当前保存后读取失败只给 existing internal_error 文本/ID；不具备新 operation 状态或完整 recurrenceRules，不能据此关闭 F06/C10 |
| 旧文稿、产物及用户 Skill | 保持 Transcript@1 与旧无 manifest 内容可读；Reminder 关联独立增量存储，不要求重装或重写已有用户 Skill | 无 action/confirmation 记录的旧事项不自动推断关联，不按标题补造确认日志；旧 Skill 不假定认识新参数 |
| 既有系统事项复杂规则 | 从同一 EventKit 实例重读并 patch 已改字段；未改时间/recurrence/alarm 保留；不支持编辑时明确失败 | 不能用旧 CLI first recurrence JSON 重建全部复杂规则；有损读取 adapter 不能冒充新完整写入契约 |

迁移顺序提案：先冻结纯业务类型/回执/错误与主机 fixture → 在现有 shared handlers 与 model 中复用统一校验/实际读写 → 落地私有 operation 与独占 → 接 C09/C10 候选确认与来源导航 → 经批准增加 CLI adapter/参数。每步保留旧入口可用，会议新功能只有所有必要保证到位后开放。日志 schema 版本升级保留已 saved/saving 的身份；升级无法解释的记录进入待核实，不能清空后再建。

## 8. 任务与 PRD 逐条核对

下表定义待实现验收，不将文字提案算为生产完成。

| 任务验收 | 本附录约束 | PRD 对照与复用边界 |
| --- | --- | --- |
| C00-1 稳定 ID/字段/来源/状态/失败/系统完成权威 | §2–6，confirmation/request 同一创建身份、不可变 hash、来源核验、实际读取、独占状态机 | F05-AC01–03、F06-AC01–03；复用 EventKit model，不新建 completed 数据库 |
| C00-2 向后兼容 | §7，独立增量关联、不推断旧确认、不要求重装/重写 Skill | COMMON-AC01；Transcript@1 与无 manifest 的全局策略沿用主草案，本文不另造升级格式 |
| C00-3 时间/列表/回执/恢复/删除 | §3–7，due/alarm 独立、ID 目标、actual、unknown 禁止重建、来源删除保留事项 | F06-AC01–04、F07-AC01–03、F08-AC02/05；C13 接 C12 删除规则 |
| C10-1 重复确认/回执丢失/中断/重试 | §5，持久唯一键 + CAS + 跨进程独占；saving 后零匹配禁止再建 | F06-AC01、F06-AC02、F05-AC02；UI busyIDs 不算幂等验收 |
| C10-2 双向导航/外部状态/权限 | §1、§6，增量录音路由及现有详情入口、读取真实移动/完成状态，权限/不可读分离 | F06-AC03–04；当前 onOpenURL 尚无 recording detail 路由，需实施，不把现有 start/stop 当完成 |
| C10-3 失效不重建/不双存完成/来源删除 | §2、§5–6，确认身份不复位，sourceState 分离；C13 接 tombstone | F06-AC03–04、F08-AC02/05；不重做待办页和 C12 清理层 |
| C11-1 listID/日期/时区/独立 alarm/实际回执 | §3–4、§6；复用现有 editor 独立开关与 strict helper，补完整 actual | F07-AC01–02；CLI 新输入尚待批准，通知到达属于 F07-AC04 |
| C11-2 非法日期/只读/失效拒绝/无默认回退 | §3、§6–7；写前验证且 frozen ID 不变；无 half-configured save | F07-AC01；现有 host helper 可覆盖部分逻辑，不能证明整个新服务 |
| C11-3 核对设置/真实执行权限/复用 CRUD | §1、§4、§6–7；统一实际读取、执行点权限，复杂设置保留/拒绝 | F07-AC02–03；首命令权限解析不足以覆盖间接调用 |

## 9. 冻结前检查与验证提案

需由 D04/D05/C00 确认：列表名称/账号与时区的呈现、一次批量确认/逐项状态、sourceMarker 载体、无法核实/已保存差异的文案与用户动作；技术评审确认统一执行点、私有存储及跨进程独占方案、canonical hash 向量、错误码/CLI 迁移。本文未给出已批准布局或磁盘 schema。

生产服务后续必须用同一业务实现和可控 EventKit 替身做回归：双执行者并发；所有 save 前后崩溃点；日志提交失败；保存成功读失败；零/单/多标记；ID 同步变化、列表移动、标记修改/外部删除；权限恢复、nil/超时/部分查询；date-only、offset/floating/亚秒、DST 歧义；alarm 截断及复杂规则保留；同 ID 改 payload、同标题明确另建；批量成功项不重试；source tombstone 与迟到回调。fixture 禁止真实 EKEventStore 授权或私人读取。

本轮已有 `tools/integration/test_reminder_contract.sh` 仅验证生产 helper 的列表/严格日期/日期组件/回执字段逻辑，设备 SDK 静态编译仅证明语法类型；两者均不能关闭 C10/T04 的持久幂等或 T05 的完整统一权限/独立 alarm 验收。T06/T07 与 F07-AC04 需之后得到明确真机运行授权，记录系统设置、实际对象及通知观察；当前未执行。
