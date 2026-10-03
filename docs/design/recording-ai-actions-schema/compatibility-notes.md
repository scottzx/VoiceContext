# 旧文稿、Skill 与产物的兼容验证

日期：2026-10-03。**C00 评审材料，未冻结。** 本文记录实际已有读取/升级入口及受控主机验证；不表示 C01/C02/C04/C08/C12 已交付，不迁移真实用户数据。新格式的判定见 [transcript-notes](transcript-notes.md)、[input/request](request.schema.json) 与 [artifact-notes](artifact-notes.md)，不另造录音状态机。

## 生产 decoder 的主机证据

[兼容病例](../../../speech_note/HostTests/TranscriptLegacyCompatibilityChecks.swift) 通过 [现有主机 harness](../../../speech_note/HostTests/verify_transcript_protection.py) 编译实际 [TranscriptDocumentV1 / TranscriptDocumentStore](../../../speech_note/speech_note/Features/Documents/TranscriptDocumentV1.swift)。模型、CodingKeys 和时间 decoder 没有复制。fixture 从仓库的 [旧 source_chunk_id 文件](../../../speech_note/speech_noteTests/Fixtures/transcript_v1_legacy_source_chunk_fixture.json) 与 [source_ranges 文件](../../../speech_note/speech_noteTests/Fixtures/transcript_v1_schema_fixture.json) 读取；各变体只写临时 `Transcripts/<UUID>.json`，由生产 store 读取，结束删除临时目录。

已执行 `python3 speech_note/HostTests/verify_transcript_protection.py --legacy-only`，以下七组实际通过。随后省略该参数重跑完整 harness，保留原九组可靠性断言，加入兼容组后共十组通过。编译仅用主机 swiftc，沿用现有 Swift 5 / MainActor harness；仍有已有 Sendable、未使用 try? 及 renderer 日期属性的 actor-isolation 警告，不代表严格 Swift 6 或完整 App 构建通过。

| 病例 | 实际断言 | 兼容含义 |
|---|---|---|
| 裸 source_chunk_id，缺 start/end | 来源、文字、segment ID 保留；起点使用 offset_milliseconds × 16，终点等于起点；同时测 0 和 60 秒偏移 | 只能定位旧点，不能补出结束时间或范围覆盖 |
| source_ranges 与旧别名 | 两个明确来源范围及 ID 保留；非空 source_ranges 优先于旧 source_chunk_id；读取 chunk_id、缺 source_kind 默认 audio_chunk、speech_span_i_ds，并写回再读 | 新旧来源键继续兼容；别名正规化不是新增识别证据 |
| 缺可选字段 | tags/participants/speakerTurns/speakers/speechSpans/gaps 为空，title 为 nil、language 为空；languageMode 为旧 zh_en_bilingual；缺校对 flag/timestamp 为 false/nil | 读取默认值保持旧行为；不是对历史参与者、校对事实或完整性的证明 |
| RFC3339 | 无毫秒 Z、带毫秒 Z、毫秒 +08:00 对应正确同一时刻；写回统一 UTC 三位毫秒 | 正规化可能改变 bytes，不能按等价时间串复用旧摘要 |
| 人工校对与稳定 ID | 明确 true 的 flag、校对文字/时间、UUID 身份与旧来源点在 store 写读后相等 | 大小写 UUID 可读；只保留已有校对事实，不补造缺失事实 |
| 原 bytes 与重编码 | 原 fixture 与写回文件解码等价，但真实 CryptoKit SHA-256 不同；输出两个摘要 | source.sha256 必须对所指原 bytes 计算，不可把重编码摘要冒充原文件身份 |
| 旧 complete / gaps=[] | 裸点、明确范围与重编码文件仍无新 completeness/阶段 outcome/覆盖证据；重编码裸点的 end_sample 仍是 0 | 旧状态和默认空 gaps 不构成新 complete 判定；不能推断静音或 voicedEmpty |

这些检查读取真实生产 decoder，但没有生成持久 `transcriptEvidence`、候选、history 或 tombstone。当前生产 decoder 仍只返回 Transcript@1；上表“unknown”边界由待评审新契约规定，不声称生产旧稿已显示新完整性标签。已有正范围仅证明保存了来源坐标，不证明真实解码/VAD/ASR 全部处理过该域。

本次原旧 fixture SHA-256 为 `6a7a2182b87dba3c2662361fe95a8fe35c6592604802e9072ee0811d3f05d707`，生产 store 写回文件为 `aae9cb18413e10914f8b2fa62c42f0a9de682bdd46d7a938851973fa4f418735`。两者解码后的文档相等；这是固定 fixture 的验证结果，不是用户文稿摘要。

## 已有 Skill / Generated 入口与复用边界

| 现有入口 | 当前行为与可复用点 | 尚未实现的升级要求 |
|---|---|---|
| [MeetingWorkspaceBridge.installSkill](../../../Integration/App/MeetingWorkspaceBridge.swift) | 已有 voicecontext/SKILL.md 时不覆写；通过 reconcileOrphanSkill 接回现有 Skill 注册；缺文件才装默认文本 | 没有 schema-capability 协商、用户确认升级、受管模板 ownership/version 记录或 C04 新 adapter；不能把“跳过”说成旧 Skill 已升级 |
| [MeetingWorkspaceBridge.publish](../../../Integration/App/MeetingWorkspaceBridge.swift) | 从现有公开文稿/模板/Skill 生成独立 Source 快照；Generated 独立；source-files.json 是本发布器写过的路径清单 | 该清单不是 artifact manifest，也没有固定 input bytes/源摘要/run 关联；不是 C12 墓碑或不可变历史版本 |
| [旧 load_transcript.py](../../../speech_note/Supporting/VoiceContextPack/Skill/generate-meeting-minutes/scripts/load_transcript.py) | 优先 transcript.json，必要时读 Markdown；检查 Transcript@1、kind=meeting、state=complete、revision 可转整数及非空 segments | 原检查不等同新 completeness；Markdown fallback 重建文字且给 gaps 空值，缺 stable ID/精确范围，不能通过此路补造 citation 或正式纪要证据 |
| [旧 generate_minutes.py](../../../speech_note/Supporting/VoiceContextPack/Skill/generate-meeting-minutes/scripts/generate_minutes.py) | 写 Meetings 下 generated/<template>/<time>.md；header 保存 recordingID/revision/source_kind/template/time；生成前后比较原文文件 SHA，检测变化 | 比较用摘要未写进 header；没有 run/选区快照/typed manifest/树或行动提案，不等于提交时并发排斥；旧输出不能被补标为新 formal 产物 |
| [PublicDocumentPublisher](../../../speech_note/speech_note/Features/Documents/PublicDocumentPublisher.swift) | 沿用公开会议目录与 Daily 时间线；创建既有 generated 目录；派生物读取可沿用现有文件管理 | 发布文稿不自动迁移派生物、不补 run/manifest；与 Agent Generated 的大小写/目录差异需在 C04 adapter 显式映射 |
| [RecordingAgentResults](../../../Integration/App/RecordingAgentResults.swift) | 沿用 VoiceContext/Generated/<recordingID> 列表与 QuickLook，检查 UUID、常规文件及真实路径 | 没有 typed manifest 解码或摘要验证；旧无 manifest 文件仅供独立历史读取，不能伪造关联；新 staging/失败文件不能统称历史已提交结果 |

[PublicSkillPackSeeder](../../../speech_note/speech_note/Features/Documents/PublicSkillPackSeeder.swift) 本轮已由根代理修复为本地及镜像目标只补缺失文件，保留已有同名 Skill、脚本、默认/自定义模板与额外文件。根代理先以旧生产实现实际复现 `Existing Skill was overwritten`，修复后 [主机回归](../../../speech_note/HostTests/verify_skill_pack_preservation.py) 的八组临时目录病例通过：本地修改/重复零新增/变化 bundle 保留，镜像同名修改及独有文件保留并补缺失，本地及镜像的根/子目录 symlink 边界，以及源目录读取失败/恢复重试。新增文件先经协调写入隐藏暂存文件，再非替换提交；已存在文件逐项报告跳过。独立审阅复现的根目录 symlink 漏查与枚举读取错误漏报已修正。镜像目标是注入的临时目录，没有访问真实 iCloud；不证明崩溃恢复或任意外部进程的并发锁。

该修复防止安装器覆盖用户文件，不能因此声称既有 Skill 已执行受管版本升级。完整默认 Skill 升级仍需 C04 adapter 与 ownership/version 规则；旧无 manifest/history/run 的关联迁移仍未实现。

| 可重跑命令 | 已执行结果 | 证据范围 |
|---|---|---|
| `python3 speech_note/HostTests/verify_transcript_protection.py --legacy-only` | 7 病例通过；独立审阅后补三种 endedAt 非 nil / 60 秒断言，再次通过 | 生产 Transcript@1 decoder/store、临时 JSON 与真实 bytes hash |
| `python3 speech_note/HostTests/verify_transcript_protection.py` | 原 9 组 + 兼容组，共 10 组通过 | 现有可靠性纯逻辑与主机音频/队列/临时文稿；不代表 App 运行 |
| `python3 speech_note/HostTests/verify_skill_pack_preservation.py` | 根代理执行 8 临时目录组通过 | 生产 seeder；本地和注入镜像目录的文件保护、路径与读取失败，不包含真实云服务 |

## 待评审迁移规则

1. 旧 JSON 继续交给 Transcript@1 decoder；新 schema 对新对象生效。缺终点保留 legacyAnchor，不造下一段起点或片尾终点；缺阶段证据投影 unknown。已知失败/缺口按新契约另行投影，不能仅凭旧字符串或 gaps 空数组降级/升级。
2. 首次关联前固定实际读到的原 bytes 并计算 source hash；重编码只产生新的 bytes 身份。持久 history、原文件归档、恢复及事务边界目前未实现，不能把上面的临时 round trip 称为历史迁移。
3. 校对 true/edited_at 与既有 ID 保留；缺 flag 的 false 是兼容默认值，不是“历史从未校对”的审计证据。旧边界不明的段保持保守保护，候选稳定映射及用户采纳按 [文稿附录](../recording-ai-actions-transcript-contract.md) 待评审。
4. 旧 Skill 保留，新增能力走明确 adapter/version 入口；旧无 manifest Generated 继续历史查看，不静默删除、不补造摘要/run/完整性或新的产物关联。两个已有输出目录须保留 provenance，不能按同名文件直接归并。
5. 迁移不得延长音频七天保留期限，或因仅找到旧文稿/旧 Generated 解除 tombstone。真实库存、原文附件清理、墓碑统一提交、重启恢复与并发采纳仍是 C12/C01 未完成项。

验证只在 macOS 主机编译/执行纯逻辑和临时文件读写；没有 iOS Simulator、设备运行、生产音频识别、真实用户数据迁移或 UI 验证。
