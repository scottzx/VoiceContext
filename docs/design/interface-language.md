# 一芥伙伴 / Yima 统一界面语言与 token

日期：2026-10-02。适用：融合版的聊天、会议、待办事项、拓展，以及 App 自己绘制的详情和阅读界面。

状态：完成现状审计与规范整理；代码 token、页面迁移及真机对照尚未实施。用户本轮要求建立统一设计语言，未要求立即批量修改页面。

## 1. 目标与设计依据

同一种文字、动作和信息层级，在切换 Tab 后保持相同的视觉表达。默认密度延续“原生、克制、内容优先、舒适紧凑”，使用系统字体、黑白灰和局部语义色。

项目级事实源仍是 [`DESIGN.md`](../../DESIGN.md)。本文将其 Typography、Color、Spacing、Layout、Accessibility 细化为跨页面的角色、组件契约及迁移输入；不另建品牌方向。2026-09-29 的融合导航约定优先于历史 v1 的单录音首页。现有待办原型继续提供业务布局输入，字体和留白按项目级规范收敛。

本轮交付是规范、差异清单与实施顺序。录音可靠性、聊天流式行为、日历和提醒事项权限／写入规则、用户字号设置继续作为兼容约束。

使用场景：用户在对话、会议回看和待办跟进之间切换；开发者新增页面或调整组件时，能找到明确的文字角色和布局规则。

### UI/UX 风格确认

复用已确认方向：Human 于 2026-08-03 确认的安静原生工具风格，以及 2026-09-29 确认的四 Tab 与舒适紧凑密度。关键词：原生、克制、清晰、可靠、内容优先；避免渐变、彩色工具分类、大标题堆叠、逐行卡片和桌面布局。

本轮无需另做流程原型：入口、业务路径和数据模型没有变化。后续用同一真机、相同字号与外观对照实际页面。新增纪要阅读器属于独立功能，需要另行定义阅读流程；不能将系统预览改造混入机械 token 替换。

## 2. 当前差异及成因

本表是源码审计，参考字号对应系统默认档位；不是实测屏幕字号，也没有读取或重置当前设备的字体偏好。聊天审计覆盖当前 `CollectionViewMessageListV3` 路径。

| 角色 / 区域 | 当前实现 | 收敛方向 |
|---|---|---|
| 待办月份、今日事项 | [`TaskCalendarView.swift:72`](../../Integration/App/TaskCalendarView.swift#L72) 和 [`SystemRemindersView.swift:236`](../../Integration/App/SystemRemindersView.swift#L236) 均为 `.title2.bold`，默认约 22 pt | 月份属于控制标题、今日事项属于章节，统一到 `.headline`；保留日期网格正文尺寸 |
| 待办章节间距 | [`SystemRemindersView.swift:203`](../../Integration/App/SystemRemindersView.swift#L203) 标题行 top 24 / bottom 12，另有分组 top 16 / bottom 4 | 使用章节和分组契约，避免多层 inset 累加造成大块留白 |
| 待办内容标题 | [`SystemRemindersView.swift:595`](../../Integration/App/SystemRemindersView.swift#L595) 为 `.body.medium`，默认约 17 pt | 已接近基准；不能为消除宽松感把所有待办文字都缩小 |
| 聊天正文与输入 | [`SelectableMarkdownView.swift:317`](../../Vendor/Phone/src/ios/Views/Chat/SelectableMarkdownView.swift#L317)、[`ChatInputBar.swift:1390`](../../Vendor/Phone/src/ios/Views/Chat/ChatInputBar.swift#L1390) 使用 16.5 pt 基准及独立倍率 | 同一正文角色基准为 `.body`；保留用户阅读／输入偏好并加入系统动态字体适配 |
| 字体缩放 | [`FontSettings.swift:82`](../../Vendor/Phone/src/ios/Shared/FontSettings.swift#L82) 有三条独立轴；[`MinisApp.swift:336`](../../Vendor/Phone/src/ios/MinisApp.swift#L336) 根视图指定类别，默认 `.large` | 默认继承系统 Dynamic Type；自定义倍率只应用一次，不能压低系统无障碍字号 |
| 会议列表 | [`ContentView.swift:1506`](../../speech_note/speech_note/Features/Home/ContentView.swift#L1506) 标题 `.headline`、元信息 `.subheadline`，内间距 4、垂直 padding 8；minHeight 60 | 作为列表密度参考；最小行高按现有规范收敛到 64，允许内容自然长高 |
| 会议详情元信息 | [`RecordingDetailView.swift:433`](../../speech_note/speech_note/Features/Recording/RecordingDetailView.swift#L433) 标题 `.title2.bold`，日期／时长 `.caption` | 保留详情标题；普通日期／时长用 metadata，句级时间戳才用 compact metadata |
| 逐字稿正文 | [`RecordingDetailView.swift:1153`](../../speech_note/speech_note/Features/Recording/RecordingDetailView.swift#L1153) 为 `.body`，额外行距 3 | 基准已合适；按文档排版规则统一段落节奏，保留时间和说话人结构 |
| 导航点击区 | [`MinisNavigationHeader.swift:223`](../../Vendor/Phone/src/ios/AgentKit/MinisNavigationHeader.swift#L223) 图标 40×40 | 视觉图标可保持小，点击区至少 44×44；不顺便重写导航手势 |
| 纪要产物预览 | [`RecordingAgentResults.swift:19`](../../Integration/App/RecordingAgentResults.swift#L19) 为文件列表，预览在 [`同文件:69`](../../Integration/App/RecordingAgentResults.swift#L69) 使用 `QLPreviewController` | 统一文件列表和预览入口；系统文档内部排版由 QuickLook 管理 |

字体差异同时来自角色选择和缩放机制；宽松感还来自字号、字重、间距和容器层级的叠加。待办与聊天正文基准本身只相差约 0.5 pt，优先处理标题层级和间距，而非整页同比缩小。

## 3. Token 层级与命名

保留现有 `vc.*` 命名，避免为产品更名重复创建一套 token。三个层次各有一个职责：

| 层次 | 示例 | 职责 |
|---|---|---|
| 基础值 | `vc.space.sm = 8`、`vc.radius.control = 12` | 允许的尺寸标尺 |
| 语义角色 | `vc.font.section`、`vc.muted`、`vc.layout.pageInset` | 表达内容和动作的用途 |
| 组件别名 | `vc.listRow.paddingY`、`vc.document.paragraphGap` | 组合基础值，定义真实组件；只为已存在的重复用法建立 |

页面选用角色，不直接选择“这页需要 22 号字”。业务几何、音频波形、手势阈值、流式列表估高不属于普通间距 token，不能用全局搜索替换迁移。

### 3.1 字体角色

数值仅帮助设计走查，实现优先使用语义字体，随 Dynamic Type 增长；不要用这些参考值固定最终字号或行高。

| Token | SwiftUI / UIKit 角色 | 默认参考 | 用途 |
|---|---|---|---|
| `vc.font.navigation` | 系统 inline title / `.headline` | 17 pt semibold | 四 Tab 及普通导航栏；交给系统管理几何 |
| `vc.font.detailTitle` | `.title2.weight(.bold)` / title2 | 22 pt bold | 进入单条录音／文档后的一次主标题 |
| `vc.font.section` | `.headline` / headline | 17 pt semibold | 今日事项、文稿、播放器等章节；日历月份控制标题 |
| `vc.font.itemTitle` | `.body.weight(.medium)` / body + medium | 17 pt medium | 待办、日程、文件条目；Recording 标题使用同基准 semibold |
| `vc.font.body` | `.body` / body | 17 pt regular | 消息、输入、逐字稿、App 内纪要正文 |
| `vc.font.metadata` | `.subheadline` / subheadline | 15 pt regular | 日期、时长、账户、解释性副文；可用于组内标题的 medium 变体 |
| `vc.font.compactMetadata` | `.caption` / caption1 | 12 pt regular | 句级时间戳、来源小字、同一行的到期／提醒日期、简短计数 |
| `vc.font.status` | `.caption` / caption1 | 12 pt regular | 简短状态；较长权限或失败说明使用 metadata |
| `vc.font.code` | 动态缩放的系统等宽字体 | subheadline 基准 | 代码／字面路径，保留中英文 fallback 和复制行为 |

`.caption2` 只用于原生控件的辅助标记，不作为正文。正文常规字重，章节 semibold；bold 保留给详情主标题，避免所有可点击内容都加粗。

文档中的 Markdown H1 / H2 / H3 分别映射 title2 / title3 / headline，H4–H6 使用 headline 的层级与间距变化，不无限放大。全文消息允许自然增长，不用两行截断；列表标题默认最多两行，大字体时允许增长。

### 3.2 字体缩放与现有偏好

SwiftUI 的语义字体和 UIKit 的 `preferredFont` / `UIFontMetrics` 使用同一系统字号环境。Apple 将 text style 作为自动缩放依据；适配自绘文本时需明确其对应角色。[Apple 自动字体缩放](https://developer.apple.com/documentation/uikit/scaling-fonts-automatically)

迁移契约：

- 系统 Dynamic Type 是共同输入。默认设置继承系统，不将 `.large` 固定写回所有页面。
- 保留 `fontSettings.chatInputScale`、`fontSettings.messageBaseScale`、`fontSettings.appBaseScale` 的已保存值和含义，不清零、不偷偷合并为一个设置。
- 现有 App 偏好映射为 DynamicTypeSize 档位，消息／输入偏好使用 multiplier，二者不是同一比例。迁移须记录各档前后对照，不能直接换成倍率乘法后声称显示完全兼容。正文基准 16.5→17 是明确的规范调整，保留偏好不等于最终字号逐像素不变。
- App 通用字体、消息阅读和输入各自使用所属偏好；同一个字号不重复乘 App 倍率和消息倍率。普通默认档位下基准一致，用户主动选择不同阅读字号时允许差异。
- 系统处于无障碍档位时，自定义缩小偏好不得覆盖系统类别或降低到系统所需字号以下；偏好原值仍保留。具体 SwiftUI／UIKit 适配须对照默认、非默认偏好和 accessibility3 验收。
- 字体变化须刷新 Markdown 缓存、UITextView、流式 collection view 的测量与输入高度。禁止只改渲染字体而保留旧估高。
- 不以限制正文 Dynamic Type 来解决拥挤。日历保留现有大字体周视图与日期选择替代入口。

### 3.3 间距与密度

基础标尺沿用 `DESIGN.md`：`2xs 2`、`xs 4`、`sm 8`、`md 12`、`lg 16`、`xl 20`、`2xl 24`、`3xl 32`、`4xl 48`、`5xl 64` pt。主节奏是 4 pt；2 pt 仅用于微小标记。

| 语义 / 组件 token | 值 | 契约 |
|---|---|---|
| `vc.layout.pageInset` | 20 | 自绘内容和文档页左右边距 |
| `vc.layout.listInset` | 16 | 原生列表／聊天 viewport 的允许变体；同一个列表不逐行漂移 |
| `vc.layout.sectionGap` | 24 | 独立内容章节之间；只由父容器添加一次 |
| `vc.layout.groupGap` | 16 | 同一章节内的子分组 |
| `vc.layout.headingGap` | 8 | 标题至其正文／条目 |
| `vc.listRow.contentGap` | 4 | 标题、来源与日期之间 |
| `vc.listRow.paddingY` | 8 | 普通内容行上下内边距 |
| `vc.listRow.minHeight` | 64 | 录音／事项内容行最小高度，非固定行高；表单／工具行另用原生规则 |
| `vc.control.hitTarget` | 44 | 每个可点击目标的最小宽高，视觉图标不必扩大 |
| `vc.control.primaryHeight` | 52 | 独立主要按钮；工具栏图标按钮仍是 44 点击区 |
| `vc.document.paragraphGap` | 12 | 相邻正文段落 |
| `vc.document.sectionGap` | 24 | 文档章节之间 |
| `vc.document.lineSpacing` | 3 | 基础档位额外行距参考；UIKit 按字体缩放换算，避免与 SwiftUI 各用一套比例 |

列表日期／时间与动作对齐，文字可折行。到期左、提醒右共用一行，保留此前确认的布局。空状态占一段内容，不用大面积 padding 凑满屏。

### 3.4 色彩、表面与形状

颜色值、深浅色与语义色完整表继续从 `DESIGN.md` 的 Core tokens 读取，本文不复制另一份 hex 表。系统动态颜色和显式 token 不是逐像素等价，适配后必须检查实际小字对比度。

| 角色 | Token | 规则 |
|---|---|---|
| 页面 | `vc.canvas` | 统一系统页面底色 |
| 主文 / 次文 / 禁用 | `vc.ink` / `vc.muted` / `vc.tertiary` | 主次层级通过角色表达，禁用不能只靠降低透明度 |
| 次级区域 / 独立控制面板 | `vc.grouped` / `vc.surface` | 日历、输入和播放器是真实控制面板；普通事项和录音保持平面行 |
| 分隔线 | `vc.line` | 细线，使用平台像素／separator，不套粗边框 |
| 录音 / 破坏性动作 | `vc.recording` | 小号状态文字使用已有 `vc.recordingText` 变体 |
| 处理 / 成功 / 系统外链 | `vc.warning` / `vc.success` / `vc.info` | 只传达真实状态；普通完成内容仍中性 |
| 待办日历类型标记 | `vc.calendar.reminderDot` / `vc.calendar.eventDot` | 分别别名到系统红／绿；限定日期下的小点和说明，不表示紧急或通知 |

形状使用 `vc.radius.flat = 0`、`vc.radius.control = 12`、`vc.radius.panel = 16`。系统 sheet/popover 保留原生形状。录音圆钮沿用 60–64 视觉直径、至少 72 点击区。

聊天气泡、输入框、代码块属于内容组件，现有圆角 18／20／8 等作为迁移时需核对的组件几何，不能扩散成新的通用 card 规则。其最终 token 值与 padding 在聊天迁移任务中对照确认；本轮不冒充已批准的新形状例外。

发现的既有规范冲突应逐步清理：助手图标渐变（[`CollectionViewMessageListV3.swift:284`](../../Vendor/Phone/src/ios/Agent/MessageList/CollectionViewMessageListV3.swift#L284)）、工具类别紫色／多色（[`AssistantBlockView.swift:42`](../../Vendor/Phone/src/ios/Views/Chat/AssistantBlockView.swift#L42)）、橙色行内代码和黑底绿字代码块（[`SelectableMarkdownView.swift:323`](../../Vendor/Phone/src/ios/Views/Chat/SelectableMarkdownView.swift#L323)），以及逐字稿句级卡片和红色填充描边（[`RecordingDetailView.swift:1166`](../../speech_note/speech_note/Features/Recording/RecordingDetailView.swift#L1166)）、紫／靛蓝说话人色板（[`RecordingDetailPlaybackPresentation.swift:93`](../../speech_note/speech_note/Features/Recording/RecordingDetailPlaybackPresentation.swift#L93)）。这些是后续有边界的组件调整，不在 token 接线时顺带大改。

## 4. 跨页面组件契约

| 组件 | 共同规则 | 按内容保留的结构 |
|---|---|---|
| 导航栏 | inline 标题、中性动作、44 点击区，系统安全区 | 聊天现有自绘 header 适配相同角色；保留交互返回补丁 |
| 章节标题 | section 字体、headingGap，父级只添加一次 sectionGap | 月份／今天／info 是同一组控件，不增大整个日历字级 |
| 内容列表行 | itemTitle、metadata 或 compactMetadata、平面行、自然高度 | 录音有时长／状态；待办有完成控件／到期／提醒；日程有时间／来源 |
| 正文阅读 | body、统一段落与标题标尺、文字优先 | 聊天保留用户气泡和助手输出；文稿保留时间定位和说话人；纪要保留章节和行动项 |
| 状态说明 | 明确文本、真实进度，metadata 长说明、44 操作区 | 无权限区别于空内容；任务更新、工具运行、转写进度各用真实模型 |
| 系统面板 | sheet/popover 原生，分段、完成／取消位置一致 | 待办来源切换和日期选择沿用当前流程 |

不是所有页面都有卡片；也不是所有字号相同。统一的是相同内容角色、基础尺寸、状态语义和操作姿态。

## 5. 工程落点

当前没有跨 App 与录音 framework 的设计 token 实现。`ChatColors`、`FontSettings` 位于 App 内，`RecordingStatusStyle` 位于独立 `VoiceRecording` 模块，不能直接让录音 framework 依赖 App 的 internal 类型。

优先采用最小改动：在产品仓库建立一份 `Integration/Shared/YimaDesignTokens.swift` 源码，承载角色与基础尺寸，通过 `tools/integration/generate_project.py` 显式编入 App 与 `VoiceRecording`。物理源码只有一份；两模块使用各自编译出的无状态值，不复制数值，不引入模块循环。保留原录音 target 的构建时也需添加相同源码输入。

共享定义保持各模块内部使用，不将两次编译产生的 token 类型作为跨模块 public API 参数；它们的类型身份不同。跨模块只传已有系统值／配置输入。

SwiftUI／UIKit 字体与颜色适配共用这份定义；用户偏好由 App 调用端提供，token 文件不持有 `FontSettings`、EventKit、录音服务或持久化状态。先转接 `ChatColors` 和 `RecordingStatusStyle`，再渐进替换调用处。暂不为标尺引入第三方库、主题引擎或独立组件框架；将来确有额外消费模块再评估 Swift package。

工程生成器是输入事实源，不直接维护一次性的生成项目文件。Vendor 改动按现有 [`OpenMinis 上游维护约定`](../architecture/openminis-upstream.md) 保存定制及来源清单，不能覆盖 vendored tree。

数据／接口：不增加业务数据模型；新增 token 与适配调用接口。录音、聊天和系统事项数据仍由原服务维护。

隐私／安全：不读取用户内容来生成样式，不新增联网、权限或上传；字号偏好原键继续保留。QuickLook 文档内容仍走现有预览入口。

## 6. 增量实施任务与依赖

本地任务草案，执行人除最后产品走查外为 Agent。先明确可验证交付，再落库；不自动启动其他会话。

| 顺序 / ID | 可独立交付的范围 | 依赖 | 验收标准 |
|---|---|---|---|
| DS-01 共用 token 与适配 | 共享源码接入两个模块；SwiftUI／UIKit role 映射；定义并实现字号兼容策略；普通中性色接线 | 无 | 两模块消费同一源码；iPhoneOS 编译通过；默认继承系统、原偏好不清零、倍率只应用一次；记录现有各偏好档位迁移前后对照；不修改业务模型 |
| DS-02 待办密度 | 月份／今日事项改为章节字级，按契约归一父／子间距，列表内容行接线 | DS-01 | 同字级标题与会议对照一致；日历红绿点、info、筛选及到期／提醒同行保留；44 点击区、大字不截断 |
| DS-03 聊天适配 | 消息／输入／Markdown 字体接线，header 点击区；缓存和 collection self-sizing 同步 | DS-01 | 默认正文基准一致；非默认阅读／输入设置保留；流式追加、历史回看、选中复制、输入增长和返回手势正常 |
| DS-04 会议列表和详情 | item／metadata／正文接线，64 最小内容行、倍速与说话人筛选点击区 | DS-01 | 默认日期时长角色一致；正文仍可时间定位；播放、倍速、录音全局停止保持可用 |
| DS-05 语义和文档组件整理 | 单独处理已记录的渐变／类别色、逐句卡片；聊天文档排版收敛 | DS-03、DS-04 | 符合 Color / Prohibited Patterns；工具与说话人仍可用文字辨认，选择及播放位置可感知 |
| DS-06 设计与无障碍验收 | Agent 检查与 Human 产品走查；三页相同环境对照，形成真实证据 | DS-02–DS-05 | 下列验收矩阵有已测结果、截图及未测边界；不以编译代替运行验收 |

DS-02／03／04 可分别实施，但不要并行修改共享字号策略。先交付共享定义和待办密度，再处理聊天／会议适配，最后整理内容组件与统一验收。无需改变信息架构、业务 API 或数据迁移；无需新原型、权限文案或发布条款任务，现有路径不变。字体和组件改动需要设计走查与无障碍验收，已列为 DS-06。

PM 追踪：项目启用了功能蓝图，但本轮 `project-items list`、`feature-catalog list` 和 `milestones list` 均因本地 `127.0.0.1:38080` 服务未运行而失败；尚未创建 requirement、功能节点、任务或里程碑，不能编造编号。服务恢复后先读取完整现有树，复用／新增“跨页设计语言”需求及叶子能力，再按上述产出建立 source、delivery 与 dependsOn。版本归属和日期待实际任务编排，本轮未提供发布日期或产能。

## 7. 验收与维护

- 三页对照使用同一物理设备、相同系统字号、相同 App 偏好、同语言和外观；记录的是 pt／角色与真实 UI，不把镜像像素当 pt。
- 默认、系统大字至 accessibility3、非默认 App／消息／输入偏好均需检查；保留已有值，测试结束恢复临时修改。
- 浅／深色、中英文、长标题／日期、空／加载／失败／受限状态均可读；所有独立动作至少 44×44。Apple 的点击目标基线同样为 44×44 pt。[Apple UI 设计基础](https://developer.apple.com/design/tips/)
- VoiceOver 朗读角色、状态和操作完整；Reduce Motion 不丢进度与选中反馈。
- 动态字体下元信息折行，标题／操作不互相覆盖；同一列表内容边缘一致，父子容器不重复添加章节间距。
- 聊天回归覆盖流式高度、长 Markdown、选择复制和键盘；会议覆盖播放与录音停止；待办覆盖月／周、筛选和事项更新。
- 不使用 iOS Simulator。仅在用户授权的物理设备运行；编译和静态审计不能标记上述矩阵通过。
- 新页面先选择既有 token／组件角色。确需新增角色时同时更新本文、共享源码和对应验收；偏离已批准 `DESIGN.md` 的方向才需要产品负责人另行决定。

待落地边界：聊天特殊形状的最终映射、SwiftUI／UIKit 缩放实现细节与真机矩阵；系统 QuickLook 正文排版不在 App token 可控制范围。本文没有宣称现有 UI 已统一，也没有将未来 App 内纪要阅读器列为已实现能力。
