# 录音 AI 行动闭环：开发与验证记录

日期：2026-10-03。工作树：`voice_type`。本记录区分代码修复、网页交互演示、主机回归与 iOS 验收；不将它们合并为完整闭环已完成。

## 用户反馈后的原生 App 增量

用户明确要求继续代码开发、优先 iOS 原生 SDK 与效果。本批承接 [反馈记录](../design/recording-ai-actions-feedback-review-2026-10-03.md) FB02/FB06/FB10/FB11，沿用 DESIGN.md 已批准的原生风格，直接改现有 SwiftUI 页面。网页原型未变化；没有重新创建录音器、播放器或元信息服务。新增 AI 结果类型、直接发起整理、持久确认等流程未在这批实现或冻结。

| 反馈 / 可靠性落点 | 本批代码行为 | 边界 |
|---|---|---|
| FB02 点击标题改名 | 详情标题改为 plain Button，44 pt 目标，打开现有系统 Sheet/Form；关闭后立即重读详情 | 保存/取消/空标题沿用已有元信息服务；列表仍用同一 model，未另建重命名数据源 |
| FB11 一键开录 | 底部红键、顶部麦克风与 Widget 链接直接用上次类型；首次默认个人记录 | 原生次级 confirmationDialog 只设置下次类型，不自动开录；音频/视频导入仍独立选类型，不改录音偏好 |
| FB10 地点不挡开录 | 移除开录前的 App 地点询问；原有设置 Toggle、系统授权与开录后异步取地点保留 | 不自动打开定位、不改用户已有开关；首次必要麦克风授权仍需系统处理 |
| FB06 回听与文字 | seek 事件按播放器实际位置定位，支持暂停和重复定位同句；手动滚动暂停跟随，底部入口可恢复并显示全部发言 | 不切换详情 Tab、不自动清用户说话人过滤；无对应区间不高亮前句；旧零长度锚点不补造结束覆盖 |
| 原生启动失败提示 | Home 用系统 Alert 显示启动失败，麦克风拒绝时提供系统设置入口 | 不把失败当录音成功，不为重复启动另造失败消息 |
| 重复 / 失败启动保护 | model.start/append 共用权限等待至 refresh 的 MainActor 门闩；coordinator 持久化失败进入原有 cleanup，追录读取后重查活动会话 | 防重复权限等待、失败后状态锁死和追录越过 await 接管另一录音；不代表完整后台/崩溃恢复验证 |

新增控件使用 SwiftUI Button、Form、Sheet、Alert、confirmationDialog、Slider、AppStorage 与 iOS 18 onScrollPhaseChange；播放器仍使用 AVAudioPlayer，地点仍使用 CLLocationManager，保留原有原生 haptic。只对新增标题/跟随控件使用中性色、44 pt 和 Reduce Motion。此前说话人紫色 palette、句卡片着色等 DESIGN 差异仍存在，未顺带做整页样式迁移。

执行证据：

- `python3 speech_note/HostTests/verify_recording_entry_playback.py`：6 组通过。生产 model/coordinator 方法原样提取编译，权限、录音、仓库与 Live Activity 使用主机 fake；播放 helper 直接编译生产文件。覆盖重复 start/append、权限拒绝后重试、失败释放、持久化失败、追录等待竞争、精确边界/文字缺口/旧锚点。无真实权限、麦克风、文件持久化或 iOS UI 运行。
- iPhoneOS 26.5 SDK、`arm64-apple-ios18.0` 类型检查：生产播放 helper、生产 scrollToActiveSegment 方法及临时原生控件 API probe 通过。probe 只核对新增 SwiftUI API 可用性与类型，不等于两个完整页面编译。
- 5 个修改的生产 Swift 文件语法检查、融合输入/身份检查及 `git diff --check` 通过；独立智能体只读复核，并据其意见修正类型选择、旧锚点覆盖、失败提示与状态释放。
- 首次完整开发版构建尝试使用现有工程、`generic/platform=iOS`、禁签名；因工作树缺少 SherpaOnnx.xcframework、OnnxRuntime.xcframework、Rclone.xcframework 失败。该次未得到完整 App 编译/产物通过证据；后续补齐与部署见下一节。

基础体验开发阶段未安装或运行真机，也没有使用模拟器。后续已安装开发版，真机上的布局、权限弹窗、滚动、VoiceOver、地点与实际录音仍待验证；不将构建/安装或主机/SDK 检查计作 UX01–UX03 的交互验收通过。

## 构建依赖补齐与真机部署

2026-10-03，用户明确要求解决缺失框架并部署到已连接的 iPhone。完成以下工作：

- 从同一产品仓库主目录的原生缓存恢复 SherpaOnnx.xcframework、OnnxRuntime.xcframework、Rclone.xcframework 到本工作树；使用 APFS 克隆复制，不修改主目录。补齐关联原生库、头文件与资源，848 个文件与 native-cache-manifest.json 的固定摘要一致。
- 补齐缺失模型，4 个模型均通过 ModelManifest.json 的 SHA-256 校验。所有缓存和大模型仍在忽略目录，没有加入版本控制。
- 真实完整编译暴露 RecordingDetailView 的 SwiftUI 长表达式类型检查超时；把原滚动内容与观察回调原样提取为 readingScroll(using:)，保留同一 ScrollViewReader 与状态，未改变导航/Sheet/播放器行为。此后完整开发版构建成功，6 组主机回归仍通过。
- 使用现有工程、VoiceContextAgentDev / Debug-Dev、generic/platform=iOS 和自动开发签名；没有重生成工程、使用模拟器或更改版本号。完整签名构建 BUILD SUCCEEDED；codesign 深度严格校验、主 App 与 4 个扩展的 iPhone 设备覆盖、开发身份/权限和融合产物装配审计通过。
- 对 scottxz（iPhone 15 Pro）的 YiJie.speech-note.dev 增量安装成功。安装后回读名称 Yima Dev、版本 1.0 (7) 与新的安装 URL，并与安装回执一致；正式 YiJie.speech-note 的安装 URL、名称、版本及返回元信息与安装前完全一致。未卸载、清除或迁移应用数据。

设备最初无法建立隧道，随后连接恢复并提供 DDI 服务；本次 CoreDevice 报告传输为 localNetwork，不将其记作已验证 USB 传输。没有调用应用启动或测试命令，安装成功不代表运行、录音、系统提醒事项、定位或无障碍验收通过。

本机忽略证据目录为 build/recording-ai-actions-device/，包含 build.log（首次完整编译的类型检查超时）、build-retry.log（成功）、host-regression.log、source-audit.json、assembly-audit.json、signing-audit.json、device.json、install.json/log、两种身份的安装前后应用信息与 deployment.json。签名 App 位于 /tmp/yima-native-feedback-build/Build/Products/Debug-Dev-iphoneos/VoiceContextAgent.app。

## 二级页面隐藏主导航

按用户 2026-10-03 的要求，主 Tab 只显示在聊天、会议、待办事项、拓展四个一级页。会议列表与搜索结果改为原生值导航，保留搜索词和句子定位；会议与拓展用 NavigationStack 的路径控制 tabBar 显隐，待办“全部”沿用其原生导航绑定。更深工具页沿用所在栈的隐藏状态；聊天已有同样的路径控制，保持现有实现。设置、终端等仍使用原生 Sheet，录音详情播放器不受此次显隐控制影响。

完整 VoiceContextAgentDev / Debug-Dev 的 iPhoneOS 签名构建通过，codesign 严格校验与融合产物审计通过。23:46 增量安装 Yima Dev 1.0 (7) 到同一 iPhone 成功，回读安装 URL 与回执一致，正式版安装元信息前后相同；未启动 App 或清除数据。新增 U05 手工用例覆盖一级返回、取消侧滑、深层工具页、Sheet 关闭及搜索定位；这些真机交互尚未执行。本机证据见 build/recording-ai-actions-device/tab-navigation-build.log、tab-navigation-assembly.json 与 tab-navigation-deployment.json。

## 本轮范围

沿用 [PRD](../PRD-recording-ai-actions.md) 与 [27 项交付清单](../design/recording-ai-actions-delivery.md)。主仓库中的 PRD、清单、Plane ID 快照与界面语言文档已复制到本工作树；PRD 字节与 Plane 同步快照 sha256 一致。主仓库的其他未提交代码没有移入或修改。

三名智能体并行负责转写保护、Reminders 修复与交互提案；Reminders 智能体在完成实现后独立审阅转写改动，主代理统一复核、补充边界并收敛工程输入。

用户随后明确要求结合已有前端与功能增量设计。本轮补充 [现有产品基线与最小落点](../design/recording-ai-actions-existing-product.md)，只读核对当前工作树与主目录最新已开发页面、未提交 token 改动；没有整体导入它们。修订原型沿用详情四内容 Tab、底部播放器和已有更多菜单，从「交给智能体」进入选择 Sheet、现有聊天草稿，再通过原产物 Sheet 查看结果；待办总览与编辑器继续复用。此前独立「整理与结果」区不再作为生产页面实施依据。

| 交付 | 当前状态 | 实际边界 |
|---|---|---|
| D01/D02/D04/D05/D06 | 评审材料就绪，待 Human 结论 | [交互规格](../design/recording-ai-actions-interaction.md)、[网页原型](../design/recording-ai-actions-prototype/index.html)；不等同于批准/真实 App 接入 |
| D03 | P1 提案随原型单独展示 | 折叠树、文字等价阅读、Markdown/Mermaid 示例导出，未接生成服务 |
| C00 | [契约评审稿](../design/recording-ai-actions-contract.md)、附录与[机器 schema 提案](../design/recording-ai-actions-schema/README.md)，未冻结 | 已补严格字段、null、状态、范围、原始 bytes 与独立 context 的参考向量；不等于生产解码器、迁移或真实运行接入，流程批准、组合提交/格式渲染/完整 recurrence wire 与技术冻结仍待完成 |
| C01/T01 | 已有数据保护路径修复与 10 组主机回归通过，完整任务未交付 | 原 9 组可靠性与 7 个旧文稿病例作为兼容组；预检、人工稿保护、空/部分结果保护、原子合并；完整历史版本与候选采纳仍待设计/契约 |
| C02 | 未交付 | 普通不可读终结、静音/有声空识别区分及机器可读完整性仍需实现 |
| C11/T05 | 既有参数缺陷修复及主机回归通过，完整任务未交付 | 精确唯一名称、非法日期、可写列表、实际回执；新 list ID 参数、独立时间 alarm 参数和统一确认服务仍待冻结 |
| C04/COMMON-AC01 | 已有安装器的数据保护缺陷已修复，完整任务未交付 | 本地/镜像保留已有 Skill 和模板，仅补缺失文件；默认能力 adapter/版本升级、统一输入/manifest 与受管模板规则尚未实现 |
| C03/C05–C10/C12/C13 | 按依赖待推进 | 固定输入/正式产物、会议结果/行动页、持久幂等关联、删除恢复与 P1 导图尚未交付 |
| T06/T07 | 未执行 | 没有本次真机运行授权，未启动 iOS 或模拟器 |

## Reminder 修复证据

工具 create/update/list 共用列表选择与日期 helper：只有未指定名称时才允许默认列表；指定名称要求唯一全名，不存在、空值、歧义或只读明确失败。日期校验拒绝 rollover，纯日期不补时间，保留 Gregorian、显式 offset 与实际组件。iOS 创建有 due 时补 start；保存后读取真实账户、列表、due 和全部 alarm。保存后读取失败提示先核对，不声称未创建；查询 nil/超时不冒充空列表。

UI 授权使用独立 requestingAccess，前台刷新不提前释放尚未结束的权限请求。日期编辑在缺日历时补 Gregorian，既有 floating 日期保持 nil 时区；未编辑组件原样保留。产物入口拒绝非 UUID 来源标识，避免直接用任意字符串构造受管路径。

## 已执行检查

| 检查 | 结果 | 证明范围 |
|---|---|---|
| `python3 speech_note/HostTests/verify_transcript_protection.py` | 10 组通过 | 原 9 组实际生产可靠性回归与旧文稿兼容组（7 个病例）；无 iOS 运行 |
| `python3 speech_note/HostTests/verify_transcript_protection.py --legacy-only` | 7 个病例通过 | 实际 decoder/store 的旧点、范围与别名、默认字段、RFC3339、校对/ID 和原 bytes 身份；临时文件，不迁移用户资料 |
| `python3 speech_note/HostTests/verify_skill_pack_preservation.py` | 8 组通过 | 实际 seeder 的本地/临时镜像保留、补缺失、重复/变化 bundle、根/子目录 symlink 拒绝、镜像失败不回滚本地、读取失败及恢复重试；无真实 iCloud |
| `bash tools/integration/test_reminder_contract.sh` | 通过 | 生产 helper 的唯一/歧义/失效/只读/默认列表、非法日期、纯日期、时区和回执；内存 fixture，不创建 EKEventStore |
| swiftc 编译并执行 `test_reminder_dates.swift` | 通过 | 未改组件、日期/时间独立修改、时区、Gregorian 与 floating 兼容 |
| iPhoneOS SDK clang `-fsyntax-only` | 通过 | CalendarOffload/RemindersOffload 的设备 SDK 静态编译；仅既有 nullability 警告 |
| 修改的 Swift 文件 `-frontend -parse` | 通过 | UI、文稿、仓库、转写与最终化文件的语法检查；不等同于完整 App 模块编译或界面运行 |
| 公开纪要 Skill `quick_validate.py` | 通过 | 旧路径、JSON/Markdown、模板、疑似说话人、来源与原文不修改的兼容基线 |
| 融合工程 `verify_fusion.py --variant development` | 通过 | 编译输入、Bundle ID/容器/Dev 隔离与来源快照；未指定设备产物 |
| 网页原型浏览器走查 | 通过，详见原型 README | 虚构数据的交互路径、深浅色、大字、44 pt 目标；不代替 iOS 无障碍验收 |
| 现有产品基线与契约草案检查 | 通过 | 两目录 11 文件源码摘要快照、42 个本地链接、JSON 示例与 source/confirmation envelope 一致；不能证明新业务实现完成 |
| `python3 tools/integration/verify_recording_ai_contract.py` | 5 个 schema、249 组通过 | 41 请求、69 产物、58 文稿、81 Reminder 的结构/参考业务向量；严格 input、执行观察、whole/selection 与实际字节组合，全部可控 fixture，不是生产服务 |
| `bash tools/integration/test_recording_ai_hash.sh` | Swift/Objective-C 各 24 组通过 | 15 个精确 UTF-8/摘要、9 个类型/Unicode/边界拒绝；Python 执行相同向量。macOS 参考编码，非生产 codec/严格原始 JSON 解码器 |
| `git diff --check` | 通过 | 差异空白检查 |

完整 iOS App 未编译、安装或运行；没有通知到达、后台压力、真实 EventKit 外部变更或真机无障碍证据。

修订导航已实际点击核对：会议列表 → 原详情四 Tab/更多菜单 → 范围 Sheet → 原聊天输入与发送；运行留在原会话。Root 通过 Codex in-app browser 捕获 [现有详情承接](../design/recording-ai-actions-prototype/preview-existing-detail.jpg)、[增量范围 Sheet](../design/recording-ai-actions-prototype/preview-existing-scope.jpg)、[原聊天草稿](../design/recording-ai-actions-prototype/preview-existing-chat.jpg) 三张新截图；旧截图不作为当前导航证据。基线静态核对发现底部播放器与 DESIGN 阅读顺序的既有差异、校对徽标使用蓝色等，真机/VoiceOver 尚未核验，本轮未顺带重排或改生产样式。

## 审阅发现与后续门禁

独立审阅发现并修复：所有人工编辑与 ASR/说话人回写都在文稿 store actor 内合并最新版本；旧编辑目标 ID 消失时明确冲突；空结果、窄范围、跨来源旧段与旧零长度引用不能丢文字；预检必须拒绝实际覆盖不足的截断音频；排队前登记全部来源并一次挂齐回调，避免第一项先完成导致整份提前完成。已移除/损坏来源的预检与仓库登记保持一致。修复后 9 组实际生产服务主机回归通过，Reminders 智能体最终只读复核未发现本轮范围内新的必须修正问题。

主机回归沿用工程的 Swift 5 与 MainActor 默认隔离设置。为避免链接无关的 Sherpa 推理运行时，脚本从生产源码原样提取说话人辅助声明和最终化提交方法；文稿、仓库、范围解码、预检、排队与完成协调直接编译生产文件。编译输出仍包含既有 actor/Sendable 与 unused `try?` 警告，本轮未扩展修复范围。

普通不可读任务的 completed 状态不等于原文完整，F01-AC03 暂未通过。跨 actor 删除、重启恢复、公开副本和迟到产物防复活仍属于 C12/C13，当前无持久 tombstone/删除协调，不声称已修复。系统事项同一确认的持久独占、来源标记恢复和双向关联仍属 C10，当前工具不具备完整幂等闭环。

用户评审具体默认提案后才能冻结 C00，并继续接入依赖它的新流程；P1 不阻塞 P0。人员、排期和 Plane 完成状态未调整。1agents 本地 daemon 当前不可达，本轮执行证据保存在仓库；不将本地文档视为看板状态同步。

## C00 机器材料增量（非生产）

多智能体并行新增 input/request、文稿伴随证据与候选/删除、正式产物/行动/导出、Reminder 确认/实际回执 schema 及可控 fixture 参考模块。只读核对真实聊天发送后修正了“现有 Agent Store 管运行”的不准确描述：ChatStore 持久会话/消息，执行器当前没有整理业务的独立持久 run ID；新的 attempt 身份须绑定真实用户消息与开始/结束，不能从草稿或文件存在推断。

独立复核补了实际 input bytes 中的未知字段/重复键、伪造终结状态、错误旧点、选区混入未选范围、all 模式错误定位点、非法时区路径等反例。新校验明确 all/segments 投影，旧 Transcript@1 不经过新 schema；零长度点继续可读但不成为覆盖。实际 Reminder 的非 Gregorian 组件保留，不能按 Gregorian 年月日误拒绝；新增输入仍采用严格 Gregorian。

主机 Swift Foundation/CryptoKit、Objective-C Foundation/CommonCrypto 与 Python 对共享 24 个编码向量逐字节/摘要或拒绝原因一致。新增参考编码器显式验证 scalar 键序、NFC/NFD、完整 Int64 边界、float 与孤立 surrogate；它们未接入生产确认服务，原始 JSON 重复键/数值词法严格解码与真实服务接入仍待完成。范围/独占/来源/读取等 fixture boolean 也不是实际锁、ASR、EventKit、删除提交排斥或运行证据。既有 seeder 文件保护修复见下节；未请求权限或运行 iOS。

全域 249 组通过后再做独立变形复核：选区 complete/整录音 partial 不能 formal；已重绑 input hash 但正文不符 canonical 被拒绝；`[]` 输入不再崩溃；伪造运行终结被拒绝；未声明 sidecar 的来源头不能替代真实导出文件。正式结构 JSON 必须与 manifest.data 一致，展示/导出文件还需独立受管 renderer 证据；当前只是参考契约，生产渲染器/原子发布仍未实现。通过记录不更改任何 Plane 完成状态。

## 已有 Skill 安装路径保护

实际 `PublicSkillPackSeeder` 旧实现整目录删除/复制本地 Skill，云端又整目录替换 Skill 与 Templates。临时目录回归先真实复现“Existing Skill was overwritten”。修复后保留所有已有同名文件与用户额外文件，仅补缺失 bundle 文件；重复安装新增数为 0，变化 bundle 也不覆盖用户内容。镜像结果逐文件报告实际新增和跳过，不声称已更新保留的旧文件。

新增文件沿用协调写入，先复制到同目录隐藏 `.writing` 暂存文件，再用拒绝现有目标的 [FileManager.moveItem](https://developer.apple.com/documentation/foundation/filemanager/moveitem%28at%3Ato%3A%29) 提交；已存在目标不走替换。独立审阅补出的根目录符号链接遗漏和枚举读取失败冒充成功均已修正。8 组生产 seeder 主机回归验证本地/临时云镜像保留、根/子目录边界及读取失败恢复；未证明真实 iCloud 运行、崩溃重启或任意外部进程的并发锁。完整受管版本升级、新 adapter/manifest 及历史迁移仍属于 C04，不通过覆盖旧文件实现。

## 工作树构建环境

工作树缺少忽略的 ProviderCustomization 配置，已从主仓库恢复与导入指纹完全一致的文件，未打印内容或纳入版本控制。工程生成器按本机存在的模型资源枚举，且文件 ID 依赖绝对路径；直接重生成会在此工作树丢失未检出的模型引用并产生无关 ID 变化。本轮保留已验证的既有工程/资源引用，仅增加 TranscriptionRetryPreflight 的两个对象与编译成员。真实构建前仍须准备既有模型和原生构建依赖。
