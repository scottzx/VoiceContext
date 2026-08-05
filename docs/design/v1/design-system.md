# VoiceContext v1 iPhone 设计系统与 SwiftUI 标注

> PM `#40` 交付物 · 版本 1.2 · 2026-08-03  
> 项目级视觉与交互事实源：[`DESIGN.md`](../../../DESIGN.md)。本文只补充 v1 iPhone 页面、组件和 SwiftUI 实现标注。  
> 产品输入：[`docs/PRD.md`](../../PRD.md) 第 8–11、15–16、18–20 节，以及 [#39 信息架构](information-architecture.md)、[用户流程](user-flows.md) 和 [状态矩阵](state-matrix.md)。

## 1. 设计意图与边界

界面把「记录」作为唯一主对象：用户从日历记录流中开始、查看和继续处理一条 Recording。它既是多人对话的记录器，也是接住个人念头的语言记事本。会议不是 Tab、列表或录音管线；它是详情和开始 sheet 内可选的一组结构化字段。“闪击胶囊”只是个人语音记事的体验隐喻，不进入数据模型，也不使用独立的彩色卡片样式。

- **先记录，后整理。** 唯一主要操作是「开始记录」，不要求用户先分类或填写表单。
- **一个念头也是完整记录。** 个人独白可以没有主题、参与人或会议字段；以音频、时间和文稿形成完整可回看的胶囊。
- **本地优先且状态诚实。** 明确表现录音、等待前台、处理中、失败和锁定，绝不把尚未生成的文稿显示为完成。
- **把不可逆事项讲清楚。** 原始音频默认 7 天；长期保留是逐条显式选择；清理音频不会清理文稿或导出文档。
- **录音始终可控。** 录音时全局状态条出现在记录、详情和「我的」中，带立即停止入口。
- **本交付不设计** iPad、Mac、Windows、输入法、云端 ASR、实体议程附件、自动监听或内置 LLM 总结。

### 1.1 视觉与产品参考原则

视觉上参考用户确认的 Apple Voice Memos 方向：黑白灰为主、平面记录列表、克制留白、细分隔线，以及唯一高饱和的红色录音入口。这是 iPhone 原生工具感的参考，不复制 macOS 窗口、交通灯或桌面双栏几何。

产品层级继续参考用户提供的钉钉 A1 图片，而不复制其品牌、硬件绑定或功能范围：

- 借鉴：录音入口突出、录音控制位于底部、详情先放播放器、转写文本围绕时间展开、短语音也能成为一条完整笔记。
- 不借鉴：云端 AI 总结、模板智能匹配、实时翻译、硬件连接状态、多媒体链接总结和复杂的详情多 Tab。
- VoiceContext 的差异：端侧处理、开放 Markdown/JSON、7 天音频生命周期，以及个人念头、多人对话和会议共享同一 Recording。

## 2. 视觉基础

| Token | 浅色 | 深色 | SwiftUI 建议 | 用途 |
|---|---|---|---|---|
| `vc.canvas` | `#FFFFFF` | `#000000` | `Color(.systemBackground)` | 主页面底色 |
| `vc.surface` | `#FFFFFF` | `#1C1C1E` | `Color(.secondarySystemBackground)` | sheet、分组控制、独立播放器 |
| `vc.grouped` | `#F2F2F7` | `#1C1C1E` | `Color(.systemGroupedBackground)` | 设置分组和次级区域 |
| `vc.ink` | `#1C1C1E` | `#F2F2F7` | `Color.primary` | 主文字、单色主操作和普通选中态 |
| `vc.muted` | `#636366` | `#98989D` | `Color.secondary` | 辅助文字；浅色小字保持 AA 对比度 |
| `vc.tertiary` | `#8E8E93` | `#636366` | `Color(.tertiaryLabel)` | 禁用、三级元数据 |
| `vc.line` | `rgba(60,60,67,.18)` | `rgba(84,84,88,.65)` | `Color(.separator)` | 列表细分隔线、次级描边 |
| `vc.recording` | `#FF3B30` | `#FF453A` | `Color.red`（语义封装） | 开始、录音中、停止和真正破坏性操作 |
| `vc.recordingText` | `#D70015` | `#FF6961` | 语义红的文字变体 | 小号录音 / 停止文字，避免浅色下对比不足 |
| `vc.warning` | `#FF9F0A` | `#FF9F0A` | `Color.orange`（语义封装） | 处理中、疑似、注意 |
| `vc.success` | `#34C759` | `#30D158` | `Color.green`（语义封装） | 需要强调的确认成功 |
| `vc.info` | `#007AFF` | `#0A84FF` | `Color.blue`（语义封装） | 系统设置、权限和外部 / 系统链接 |
| `vc.infoText` | `#0066CC` | `#409CFF` | 语义蓝的文字变体 | 小号系统 / 外部链接文字 |

- 字体：使用系统 San Francisco / 苹方；标题为 `.title2.weight(.semibold)`，区块标题 `.headline`，正文 `.body`，辅助信息 `.subheadline` / `.caption`。不使用固定字号来阻断 Dynamic Type。
- 间距：4、8、12、16、20、24、32 pt；页面水平边距 20 pt；列表行最小高度 64 pt；主要按钮最小高度 50 pt；录音圆钮视觉直径 60–64 pt。
- 形状：Recording 列表行无外部圆角；输入和小控件 10–12 pt；独立播放器 14–16 pt；只有真正的状态标签使用胶囊。不默认同时给元素添加边框、底色、大圆角和阴影。
- 图标：SF Symbols；图标永远配有可见文案或可访问标签，状态不只由颜色传达。
- 动效：普通模式仅使用 `snappy` 的 160–240 ms 过渡；`accessibilityReduceMotion` 为真时取消连续脉冲、波形和位移，仅即时更新文案与进度。
- 严禁：紫色 / 橙色品牌色、装饰渐变、彩色发光阴影、通用彩色图标底和「每个区块一张卡片」。

## 3. 组件契约

| 组件 | 视觉和内容 | SwiftUI 落点 | 必要状态 / 无障碍 |
|---|---|---|---|
| `VCPrimaryButton` | 浅色黑底白字、深色白底黑字、50–52 pt 高 | `Button` + 自定义单色 prominent style | 最小 44×44 pt；disabled 改对比并说明原因 |
| `VCSecondaryButton` | Surface、Line 边框、主文字 | `.buttonStyle(.bordered)` | 非破坏性次级操作；不和停止共享红色 |
| `VCDestructiveButton` | Recording 红 | `.tint(.red)` + `.role(.destructive)` | 用于「停止录音」；二次确认屏保留「继续录音」 |
| `VCStatusChip` | 默认为图标 / 小点 + 状态文字；仅重要语义状态使用局部色 | `Label`、`Capsule`、自定义 `ShapeStyle` | 支持 `recording / processing / complete / needsAttention / locked / offline`；完成默认中性 |
| `VCRecordingBar` | 固定在顶部内容区；红点、时长、说明、停止；仅可用极浅红表面 | 安全区内 overlay；状态由 `RecordingState` 驱动 | `accessibilityElement(children: .combine)`；停止按钮独立可聚焦 |
| `VCCaptureDock` | 首页底部独立红色圆形录音钮；首次 / 空状态显示可见文案 | `safeAreaInset(edge: .bottom)` + `Button` | 可见直径 60–64 pt，实际命中区 ≥ 72 pt；无渐变、发光或橙色替代 |
| `VCVoiceCapsule` | 个人短记录的平面行变体；标题、首句、时长、时间 | 与 `VCRecordRow` 共用视图结构、模型和导航 | 不新增 `recordingType`，不使用独立彩色卡片；完整行可点 |
| `VCAudioPlayer` | 进度、当前/总时长、播放、15 秒快退/快进、倍速 | `AVAudioPlayer`/播放协调器的 View | 音频已清理时保留位置但改为说明卡；全部控制有可访问标签 |
| `VCCalendarStrip` | 横向七天日期；今天有中性环，选中为 Ink 实底白字 | `ScrollView(.horizontal)` + `Button` | 每日标签含完整日期与记录数；不以周几缩写作为唯一信息 |
| `VCRecordRow` | 平面全宽行；标题、时间、元数据、状态文字、细分隔线 | `NavigationLink(value:)` | 行高度 ≥ 64 pt；完整 cell 可点；处理状态有文本且不只依赖颜色 |
| `VCInfoNotice` | 左侧语义色线、图标、标题、说明与动作 | `ContentUnavailableView` 的局部样式 / `GroupBox` | 用于权限、后台、iCloud、失败、试用；VoiceOver 先朗读事实再读操作 |
| `VCRetentionCard` | 音频时长、到期日、可切换长期保留 | `Toggle` + confirmation dialog | 关闭长期保留时明确回到默认 7 天；音频清理后禁用播放但保留文稿 |
| `VCSpeakerIdentity` | `未知 / 疑似 / 已确认` 的文字 chip | `Label` + `Menu` / sheet | suspected 不能和 confirmed 使用同一标签；仅确认操作写入长期档案 |
| `VCSettingRow` | 单色 SF Symbol、标题、摘要、chevron；无通用彩色图标底 | `NavigationLink` | 每行 52 pt 以上；开关有清晰 label，不隐藏关键状态 |

## 4. 页面组合与 SwiftUI 实现标注

| 页面 | 建议根视图 | 主要组件 | 交互、数据与状态锚点 |
|---|---|---|---|
| 首次引导 | `NavigationStack` + paged `TabView` | `VCInfoNotice`、主/次按钮 | 权限、iCloud、试用分步骤；拒绝权限仍可进入只读记录页 |
| 记录（日历首页） | `NavigationStack` + `ScrollView` / `List` | `VCCalendarStrip`、`VCRecordRow`、`VCCaptureDock`、`VCRecordingBar` | `selectedDate` 过滤同一 `Recording` 集合；个人笔记和会议同一平面列表；右上角「我的」；无底部多 Tab |
| 开始记录 | `.sheet` + `ScrollView` | 首屏直接录音、可选字段、会议 toggle | 直接开始在字段之前；标题 / 参与人 / 标签全部可选；`isMeeting` 为真才显示主题与纯文本议程；无附件控件 |
| 录音中 | `RecordingView` | `VCStatusChip`、时长、电平、实时文稿、底部暂停/结束 | 个人独白不显示参与人表单；实时文稿是可选增量；后台回前台时显示积压而非假装已处理 |
| 停止确认和处理 | sheet 或导航目的地 | 破坏性确认、进度、`VCInfoNotice` | 先安全关闭分片；处理拆成转写、分人、生成文档；失败可重试，音频已保存 |
| Recording 详情 | `ScrollView` | `VCAudioPlayer`、文稿、`VCRetentionCard`、`VCSpeakerIdentity`、导出 action | 播放器位于标题之后、文稿之前；同一详情容纳个人、多人和会议 Recording；会议状态只开启结构字段与完成后的 Skill 入口 |
| 我的 | `List` | `VCSettingRow`、用量摘要 | 购买、iCloud、保留、Skill、隐私与许可；本地功能不依赖 iCloud 成功 |
| 购买、同步、许可 | `NavigationStack` 子页 | 信息卡、主/次按钮、状态 notice | 商店离线、iCloud 不可用、冲突均提供本地 fallback，许可离线可读 |

建议的状态类型（命名可在实现时调整）：

```swift
enum RecordingState { case preparing, recording, paused, interrupted, stopping, processing, complete, needsAttention, lockedPendingPurchase }
enum SpeakerIdentityState { case unknown, suspected(name: String), confirmed(name: String) }
```

- 使用 `@Observable` / `@State` 驱动画面。`RecordingState` 是唯一的全局录音状态来源；`VCRecordingBar` 读取同一实例，禁止为不同页面复制停止逻辑。
- 使用 `NavigationStack` 和值式目的地；关闭 sheet 或返回日期页不会停止录音。
- 文本输入用 `TextField` 与 `TextEditor`，并为议程设置可见标签；不把 placeholder 当作唯一标签。
- 暂无真实实现时，预览可使用 `RecordingPreviewStore`，但 production view 不应以原型硬编码文案为数据源。

## 5. 状态映射与文案

| 状态 | 页面呈现 | 主操作 | 不能发生 |
|---|---|---|---|
| 权限拒绝 | 「仍可浏览记录」+ 权限用途说明 | 前往系统设置 | 自动再次请求、空白首页 |
| 低存储 | 红色 notice：「无法安全开始新记录」 | 管理存储 | 静默删音频、开始后才报错 |
| 录音后台积压 | 全局条：「录音继续，转写待前台处理」 | 打开当前记录 / 停止 | 说转写仍在后台运行 |
| 系统中断 | `gap`、中断时间和路由变化 | 恢复后继续 / 停止 | 将两段显示为连续音频 |
| 处理中 | 阶段名称 + 进度 + 稍后查看 | 稍后查看 | 空文稿标「已完成」 |
| 转写失败 | 「转写未完成，音频已保存」 | 重试 | 删除音频或生成空文档 |
| 试用耗尽 | 「音频已保存，转写等待解锁」 | 永久解锁 / 恢复购买 | 把记录叫作录音失败 |
| iCloud 不可用 | 「文档仍保存在本机」 | 导出 MD / JSON / 稍后重试 | 阻塞本地录音、处理、编辑 |
| 音频已清理 | 禁用播放，保留文稿和日期 | 查看文稿 / 导出 | 移除整条记录 |

## 6. 无障碍与尺寸验收

- 目标设备：iPhone 15（393×852 pt）及 iOS 18；在竖屏安全区内，首页、开始记录、录音、处理与详情不截断主要操作。
- 所有可点击控件实际命中区域不小于 44×44 pt；录音停止按钮和「开始记录」不得在滚动后不可达。
- 支持至少 `.accessibility3` 的 Dynamic Type：列表行和必要控制面板可纵向增长，日期选择可横向滚动，元数据允许换行。
- 每个 SF Symbol 均有 `accessibilityLabel`；状态 chip 使用文字、图标与颜色三重表达。录音时长用可读时间（如「12 分 48 秒」）而非逐字数字噪声。
- VoiceOver 焦点顺序：导航 → 录音状态条 → 日期 → 记录流 → 固定开始记录入口。详情顺序为标题 → 播放器 → 文稿 → 元数据。状态变化用礼貌 announcement，停止确认用明确的破坏性语义。
- 深色模式只替换 token，不反转警告与状态语义；正文和表面最少保持 WCAG AA 的 4.5:1 对比度。
- Reduce Motion 下关闭录音红点脉冲与电平循环；用「正在录音」和静态条形高度继续传达状态。

## 7. 高保真原型与评审范围

可点击原型位于 [`prototype/`](prototype/README.md)，覆盖：个人语音记事、多人对话、可选会议字段、日历记录流、音频优先详情、录音、后台返回、停止、处理、说话人、导出、我的、购买、iCloud、许可，以及全部关键异常状态。原型使用黑白灰、平面 Recording 列表和局部语义色，不得恢复旧的紫色 / 橙色渐变方向。

本设计系统是 SwiftUI 的视觉与交互标注，不等同于已经完成的 iOS 实现。真机对照、VoiceOver 和动态字号实际验收由 PM `#41` 在实现可运行后进行。
