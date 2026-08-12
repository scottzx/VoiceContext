# 0.1.0 录音核心设计文档

## 文档信息

- 状态：已确认（实现依据来自已批准 PRD 与功能蓝图）
- Owner：Human product owner / Agent implementation
- 来源需求：`#3`，继承顶层 `#1`
- 对应功能模块：录音与本地数据 / 本地状态、任务队列与 journal；录音分片与前后台生命周期；恢复、低存储与音频保留
- 最后更新：2026-08-07

## 背景与问题

录音是 VoiceContext 的首要不可替代资产。已有技术验证证明真机 AAC、后台音频和本地推理链路可行，但尚缺产品化的稳定 ID、样本边界、持久化索引、崩溃恢复、显式 gap 与可执行保留规则。只保留一份可变数据库状态无法覆盖“journal 已落盘、索引尚未更新”时的进程终止；在音频实时回调中转换或写文件也会增加长录音掉包风险。

## 目标

- 一条 Recording 从显式开始到停止、处理、完成具有可验证状态机；非法迁移被拒绝。
- AAC-LC 以 16 kHz 单声道写入 AudioChunk；新录音默认每 60 秒（960,000 个输出样本）轮转，每个 chunk 有稳定 UUID、sequence 和无重叠的绝对样本边界。
- SQLite 是可查询索引，append-only JSONL journal 是提交事实；重放幂等。
- 中断、路由变化、写入背压或错误形成可定位 gap，不把缺口伪装成连续音频。
- 进程终止后恢复为 `interrupted`，运行中的任务回到 `pending`，但不秘密重启麦克风。
- 所有 Recording 原始音频默认 7 天；Recording 或 chunk pin 可长期保留；文本和派生文档不参与音频清理。
- 一条 Recording 可以包含任意数量 AudioChunk；文件轮转不创建新的用户记录。已关闭 chunk 立即成为后续增量处理的可靠检查点，但录音核心不在实时音频路径执行 VAD 或模型推理。

## 不做

- 本里程碑不实现 VAD、转写、说话人聚类、公开文档生成或最终产品页面。
- 分钟级增量转写、跨 chunk utterance carry 与 `source_ranges` 由 `docs/architecture/incremental-transcription.md` 定义；本里程碑只提供连续样本、chunk 关闭事件和恢复边界。
- 不做自动监听、开机自启录音、电话录音或原始音频云同步。
- 不为低存储静默删除未到期音频；不把会议标记当作永久保留开关。
- 不用模拟器结果替代后台、锁屏、中断、路由和 2 小时真机证据。

## 用户、场景或调用方

- 用户显式点击开始后，录音状态必须立即可见；进入后台或锁屏后采集继续。
- 用户暂停、恢复或停止时，界面状态、journal 和 SQLite 索引必须表达同一事实。
- App 启动恢复服务读取 journal 并修复索引；后续处理调度器读取 `pending` job。
- 保留服务只读取到期且未 pin 的 chunk，删除本地音频后写回 `audioRemoved` 事件。
- 完整性诊断读取 chunk、gap 与文件，定位缺失、损坏、重叠和未解释样本缺口。

## 产品流程 / 信息架构

产品入口、录音控制与全局录音状态沿用 `docs/PRD.md` 第 8、9、11 节和既有高保真原型。本技术设计只提供 Recording 状态与回调，不改变页面结构。

## UI/UX 风格确认（原型前门禁）

- 状态：已确认并复用，当前功能无需新原型。
- 一句话记忆点：像 Apple 系统录音工具一样简单、可信，状态诚实。
- 风格关键词：安静、原生、精确、私密、耐用；反向关键词：炫技、AI 感、装饰性渐变、卡片堆叠、状态含糊。
- 原生与品牌：以 iOS 原生交互为主，品牌特征来自单一红色录音控制和行为可靠性。
- 信息密度与层级：录音状态与停止入口优先，gap、后台排队和失败使用明确文字，不只用颜色。
- 视觉方向与无障碍：完整复用 `DESIGN.md` 的 Typography、Color、Core Components、Motion and Haptics、Accessibility。
- 决策记录：Human product owner，2026-08-03；适用于 v1 iPhone。
- 既有规范：`DESIGN.md`；`docs/design/v1/design-system.md`；`docs/design/v1/state-matrix.md`。

## 原型与 UI/UX

不新增原型。本里程碑只扩展录音核心与可观察状态；最终产品 UI 实现和设计走查分别由既有 `#40`、`#41` 追踪。锁屏 Remote Command 是否被系统展示必须真机验证，不能仅凭 API 注册宣称通过。

## 技术方案

### 提交顺序

```text
领域事件
  → 编码为一行完整 JSON
  → append 到 recording-journal.jsonl
  → FileHandle.synchronize()
  → SQLite BEGIN IMMEDIATE
  → 以 event_id INSERT OR IGNORE
  → 更新领域索引
  → COMMIT
```

若进程在 journal flush 后、SQLite commit 前终止，下次 replay 会补写索引；若事件已经提交，`event_id` 主键使 replay 无副作用。最后一行因崩溃不完整时只忽略未以换行结束的尾部，不掩盖中间损坏。

### 音频线程

AVAudioEngine tap 只复制输入 PCM 到有界队列。串行 writer 负责计量、48 kHz 等输入到 16 kHz mono Float32 的转换、AAC 编码和文件轮转；tap 不调用模型、不访问 SQLite、不写文件。`AACChunkBoundaryPlanner` 以绝对 16 kHz 样本计数切分跨包边界，避免依赖墙钟累计误差。

默认轮转长度为 960,000 个输出样本。若一个输入包跨越边界，writer 将同一包精确切成“旧 chunk 尾部”和“新 chunk 头部”，保证前一段 `endSample ==` 后一段 `startSample`。普通文件轮转不产生 gap，也不得通过移动或复制尾部样本制造重叠。历史约 5 分钟或其他长度的 chunk 仍由其实际 `startSample/endSample` 驱动读取，读取端不得假定固定时长。

### 生命周期

`RecordingSessionCoordinator` 是 capture、repository 和录音展示状态的协调边界。进入后台不停止 capture；系统中断将采集状态迁移为 `interrupted` 并打开 gap，结束时关闭 gap并按系统 `shouldResume` 决定是否恢复。锁屏停止通过 `MPRemoteCommandCenter.stopCommand` 暴露，最终可用性由真机验收。

采集生命周期与处理生命周期彼此独立。用户停止后，coordinator 在最后 AudioChunk 和 journal 安全关闭后立即释放当前麦克风会话；该 Recording 的 VAD、转写、聚类或文档任务可以继续运行，但不得继续占用 `activeCaptureRecordingID`，也不得阻止新的 Recording 开始。

## 数据与接口

- `Recording`：UUID、开始/结束时间、可选标题、`isMeeting`、状态、保留策略和更新时间。
- `AudioChunk`：UUID、Recording UUID、sequence、相对路径、`startSample/endSample`、时间、状态和 chunk pin。
- `RecordingJob`：UUID、类型、pending/running/completed/failed、尝试次数与错误。
- `RecordingGap`：UUID、原因、绝对样本起止和墙钟起止。
- SQLite schema v1：`recordings`、`audio_chunks`、`recording_jobs`、`recording_gaps`、`journal_events`；`PRAGMA user_version=1`。
- journal payload 覆盖 Recording 创建/状态、chunk 关闭、job、gap、保留变更、pin 和音频清理。

路径始终保存相对 Recording root 的值，避免容器路径在重装或恢复后失效。音频样本边界统一采用 16 kHz 输出时基。

## 状态、错误与恢复

- 采集主路径：`idle → preparing → recording → stopping → idle`。
- 采集暂停：`recording ↔ paused`；采集中断：`recording|paused → interrupted`。
- Recording 处理状态由独立调度器维护，可与采集状态同时存在；`processing → complete|needs_attention|locked_pending_purchase` 不占用麦克风会话。
- 非法迁移抛出错误，不静默改状态。
- 强制终止：`recording|paused|stopping → interrupted`，打开 `recoveredAfterTermination` gap；运行中的 job 回到 pending。
- 低存储：在请求麦克风前失败；默认保护阈值 512 MiB，可在测试中注入容量。
- writer 背压/写失败：产生显式 point gap，供诊断和 UI 提示，不声称无损连续。
- 索引诊断定位无效样本范围、重叠、未被 gap 覆盖的缺口、文件缺失和 AAC 不可读。

## 隐私、安全与合规

- 麦克风只在用户显式调用 start 后请求；构造 coordinator、恢复 journal 或低存储失败均不会打开麦克风。
- 原始音频只写本地 Recording 目录，不进入 iCloud；journal 包含本地路径和状态，不同步。
- 所有 Recording（包括会议）默认 7 天；会议与个人语音规则一致。Recording pin 或 chunk pin 是唯一长期保留信号。
- 清理音频不删除逐字稿、日历索引或派生文档；低存储不触发静默越权删除。

## 验收标准

- [x] 领域模型与 journal 事件可编码解码；SQLite v1 migration 可重复创建。
- [x] journal 先 flush 后索引提交；重复 replay 不重复创建 Recording、chunk、gap 或 job。
- [x] 通用样本边界规划与历史 5 分钟真机证据证明跨输入包轮转无重叠与未解释缺口。
- [ ] 新录音默认 60 秒轮转；2 小时形成 120 个连续完整 chunk 加可选尾段，历史非 60 秒 chunk 仍可读取、播放、转写和导出。
- [x] tap 不运行模型或文件写入；writer 队列有界且错误可观察。
- [x] 非法状态迁移被拒绝；未显式开始或低存储时不访问麦克风。
- [x] 强制终止恢复为 interrupted；运行中 job 回 pending；重复恢复幂等。
- [x] 清理只删除到期未 pin 音频，会议与个人规则一致，文档保留。
- [x] 自动诊断可定位损坏、重叠与未解释缺口，并生成包含设备/系统/结果的报告。
- [ ] 按 `docs/testing/0.1.0-device-validation.md` 完成 30 分钟、2 小时、锁屏停止、中断、路由、强制终止与低存储真机验收。（已完成：30 分钟后台、来电中断 gap、强制终止与恢复幂等、完整性诊断；待补：2 小时、锁屏停止入口、蓝牙断连）

## 待确认项

- Remote Command 在目标 iPhone/iOS 版本的锁屏与控制中心展示情况；若系统不展示，需要在后续 UI 任务选择 Live Activity 或其他产品方案。
- 发布基线要求 iOS 18；当前可用真机若高于 iOS 18，只能形成补充证据，不能替代 iOS 18 兼容性结论。
- 已知行为：session 激活/去激活会各产生一个 sample 0 / 末样本位置的 routeChange 点状 gap，属诚实记录，无需修复。
- 用户暂停在当前绝对样本位置打开 `userPause` gap，恢复时在新的当前样本位置关闭；即使 pause 期间没有新增音频样本，该 gap 仍是下游 utterance carry 不可跨越的显式连续性边界。
- 强杀时进行中的 chunk 按设计不可恢复（只有 closed chunk 入 journal），孤儿 m4a 会留在磁盘；是否在恢复时清理或 salvage 留待后续版本评估。
- 60 秒轮转把未关闭检查点窗口从约 5 分钟降至最多约 60 秒，但不等于承诺当前 active chunk 必然可恢复；发布验收必须分别报告 closed chunk 恢复与 orphan/salvage 行为。

## PM 追踪关系

- 来源 requirement：`#3`
- 功能蓝图：录音与本地数据 / 本地状态、任务队列与 journal；60 秒录音分片与前后台生命周期；恢复、低存储与音频保留；录音与处理正交生命周期
- 既有基线任务：`#15`、`#16`、`#17`、`#18`、`#19`
- 本轮增量任务：`#43`（60 秒轮转与历史兼容）、`#44`（录音/处理正交生命周期）
- 目标里程碑：`0.1.0` 完成 60 秒可靠分片，`0.2.0` 完成录音与处理生命周期解耦
