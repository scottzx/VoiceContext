# 免费转写与魔搭按需模型下载

日期：2026-10-09。来源：产品负责人在本轮对话提出的两项调整，并确认“按照这个思路开始开发”。状态：已实施免费开放、App 内主动模型下载与小包规则；两套工程编译、产物审计与非 iOS 回归检查通过，真机后台生命周期与商店发布尚未验收。详见[开发验证记录](../planning/2026-10-09-free-transcription-development.md)。

## 目标与范围

1. 语音转文字免费开放，移除内购、试用倒计时、付费锁定和恢复购买入口。新老用户均不再依赖购买凭证使用转写。
2. App 安装包不包含语音转文字及说话人处理的模型权重。用户需要本地转写时，先进入下载页，明确点击后从魔搭下载。
3. 下载由 iOS 后台传输接管，支持进度、失败重试和重新打开 App 后恢复状态。下载、校验完成后可离线使用现有本地能力。
4. 录音采集、回听和已有文稿阅读不以模型下载完成为条件。待转写任务保留音频与检查点。

本轮不更换识别模型或推理引擎，不增加模型市场、用户魔搭账号、云端转写、下载完成通知或新计费规则。App 内购代码移除与 App Store Connect 商品停售分别跟踪。

## 已确认事实与可行性

### 内购影响范围

实施前并非只有转写按钮被收费状态控制。原 `Features/Purchase/` 提供 StoreKit、试用账本和共享 Keychain；`RecordingCoreModel`、录音首页、Widget 深链和融合录音入口均会读取付费状态。仅关闭 `TrialQuotaLedger.isManualTrialEnabled` 不能消除所有门禁。本次已删除这套购买代码、StoreKit 配置、购买 UI 与试用引导；原 Keychain 签名组为兼容保留，无购买读写代码。

需同步移除设置购买区、全屏到期购买页、首次引导中的试用步骤、转写准入和队列中的购买限制，以及相应本地化和测试。旧用户的 `lockedPendingPurchase` 作业实际仍为 pending，可清理旧错误后按普通待处理作业恢复；保留旧持久化状态的兼容读取，不删除音频、文稿或购买 Keychain，也不伪造“已购买”凭证。

### 模型与体积

当前模型由 `speech_note/speech_note/ModelResources/ModelManifest.json` 固定 SHA-256；本轮只读校验四个本地文件均通过。

| 文件 | 用途 | 精确大小（bytes） | SHA-256 |
|---|---|---:|---|
| `SenseVoiceSmall-Q8_0.gguf` | 本地语音识别 | 252,684,608 | `6c759ee4c9748c9b3f7a5a60ca74f0f7e685fb9d45d1378fce7cfd62f59adf29` |
| `silero_vad.onnx` | 语音活动检测 | 643,854 | `9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6` |
| `3dspeaker_speech_eres2net_base_200k_sv_zh-cn_16k-common.onnx` | ERes2Net 说话人嵌入与聚类（内部 ID 为 cam-plus） | 39,593,765 | `e2d2048292e055f7b61cdec3db010503f35369b245bf0b3bbad021c9a91e4053` |
| `pyannote-segmentation-3.0.int8.onnx` | 说话人分段 | 1,540,506 | `d582f4b4c6b48205de7e0643c57df0df5615a3c176189be3fc461e9d18827b5d` |

总计 **294,462,733 bytes，约 294 MB / 280.82 MiB**。这是可移出安装包的原始模型大小，不代表 App Store 压缩下载体积一定等量减少。

融合 App 另保留 **4,135,046 bytes，约 4.14 MB** 的独立聊天 VAD 资源，来自固定的 `RealTimeCutVADLibrary` 1.0.14（revision `b059608836a055dc0ce74ca2d0eeb19fc54cb7d4`）。系统 / 云聊天语音共用 `VoiceActivityDetector`，明确加载包内 `silero_vad_v5.onnx`（2,327,524 bytes）；该 SwiftPM 包同时分发 v4 `silero_vad.onnx`（1,807,522 bytes）。后者虽与本次 643,854 bytes 的下载工件同名，内容和 SHA-256 均不同。保留依赖资源避免破坏既有聊天语音，不修改固定依赖或增加构建剥离；本次四个按需转写工件仍不进入安装包。产物审计只对这个第三方 bundle 的两个确切路径及固定大小 / SHA-256 放行，并要求实际使用的 v5 存在；其他位置的四件权重或下载临时文件继续拒绝。

建议首期用一次下载动作获取四个工件，保持完整转写和说话人能力；先不引入可选模型组合。前三个已是当前 ASR 初始化的硬依赖，不能只下载 SenseVoice 权重。

`Vendor/TranscribeKit/Sources/TranscribeCore/ModelRegistry.swift` 已登记 `scott887/SenseVoiceSmall-Q8_0.gguf` 的魔搭下载 URL，期望哈希与现有 ASR 相同。进一步使用已安装的 `transcribe` CLI 定位两个发布仓库，并查验远端文件清单，已找到四个精确对应工件。本次由产品层清单和下载服务接入固定 revision 分发地址，保留 TranscribeKit 固定快照。

### 魔搭核验结果

2026-10-09 追加核验：执行 `transcribe models` 与 `transcribe invoke --payload '{"method":"asr.info"}'`，CLI 0.4.1 返回两个已发布仓库：

- [scott887/SenseVoiceSmall-Q8_0.gguf](https://modelscope.cn/models/scott887/SenseVoiceSmall-Q8_0.gguf)：9 个文件，包含当前 iOS 使用的全部四个 GGUF / ONNX 工件。
- [scott887/speech](https://modelscope.cn/models/scott887/speech)：44 个文件，包含另一套 Seaco Paraformer、FSMN VAD、标点、CAMPPlus PyTorch 组件。这些 `.pt` / `.bin` 不能直接替换本 App 的 Silero / ERes2Net / pyannote ONNX。

授权联网后，两个仓库的公开文件列表 API 均返回成功。四个 iOS 工件的**服务端 SHA-256 元数据、大小和文件名全部匹配 App manifest / 本地文件**。使用固定 revision `0ac25de3b24eae49f5bf00dc485ef954b1f23a31` 对每件匿名请求 `Range: bytes=0-15`，均重定向到 HTTP 206、正确 Content-Range，且前 16 字节与本地文件相同。仅读取模型数据合计 64 bytes，未下载完整模型或使用 token；完整远端文件未重新计算 SHA，需在 App 下载完成时执行全文件校验。

| 工件 | 已验证固定版本直链 |
|---|---|
| SenseVoice Small Q8_0 | [下载 GGUF](https://modelscope.cn/api/v1/models/scott887/SenseVoiceSmall-Q8_0.gguf/repo?Revision=0ac25de3b24eae49f5bf00dc485ef954b1f23a31&FilePath=SenseVoiceSmall-Q8_0.gguf) |
| Silero VAD | [下载 ONNX](https://modelscope.cn/api/v1/models/scott887/SenseVoiceSmall-Q8_0.gguf/repo?Revision=0ac25de3b24eae49f5bf00dc485ef954b1f23a31&FilePath=silero_vad.onnx) |
| 3D-Speaker ERes2Net | [下载 ONNX](https://modelscope.cn/api/v1/models/scott887/SenseVoiceSmall-Q8_0.gguf/repo?Revision=0ac25de3b24eae49f5bf00dc485ef954b1f23a31&FilePath=3dspeaker_speech_eres2net_base_200k_sv_zh-cn_16k-common.onnx) |
| pyannote segmentation int8 | [下载 ONNX](https://modelscope.cn/api/v1/models/scott887/SenseVoiceSmall-Q8_0.gguf/repo?Revision=0ac25de3b24eae49f5bf00dc485ef954b1f23a31&FilePath=pyannote-segmentation-3.0.int8.onnx) |

可复核证据见[魔搭模型核验回执](../planning/2026-10-09-modelscope-model-audit.json)。此前受网络限制的“未验证”结论由以上结果更新；无需为本次四个工件另建仓库或更换模型。

### 后台下载边界

Apple 的 [Downloading files in the background](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background) 支持 App 挂起时由独立系统进程传输；通过固定 session identifier 和 AppDelegate 事件回调，可在系统回收 App 后重新关联任务。

用户从多任务界面强制退出 App 后，不能承诺继续传输或自动唤醒；重新打开时需恢复任务状态并允许重试。见 Apple 的 [iOS Background Execution Limits](https://developer.apple.com/forums/thread/685525)。传输实际执行时间受 iOS 调度约束，页面不能承诺锁屏后立即完成。

下载完成只代表模型可用，是否提交 Metal 推理由现有 scheduler / lifecycle 准入决定。现有 scheduler 也支持有效的 iOS continued-processing 授权；下载回调本身不授予推理权限，不能据此在未经授权的后台启动转写。当前 admission policy 未实际执行热状态判断，本轮不将其记作已有能力。

## 产品流程与信息架构

按产品负责人确认的方案，采用“**App 内下载页，魔搭作为文件来源**”。用户无需使用浏览器自行管理模型文件或登录魔搭。

1. 安装 / 首次引导：不启动模型下载；取消试用步骤。录音可直接开始。
2. 用户点击转文字、重新转写，或选择聊天的本地 SenseVoice 语音输入时：检查模型就绪状态。已就绪则继续；未就绪则进入下载页，暂不启动推理。
3. 下载页说明“语音转文字免费使用；首次需下载约 294 MB 的本地模型；下载完成后可离线使用”，展示魔搭来源和主按钮“下载模型”。只有用户点击该按钮才提交网络任务。
4. 下载期间：显示真实进度、已下载 / 总大小及取消操作。允许离开页面继续使用 App；再次进入显示同一任务，不重复创建下载。
5. 四个工件全部下载并校验通过后显示“已就绪”。现有 scheduler / lifecycle 准入允许时，恢复原有待转写队列；不自动重新打开麦克风。
6. 设置提供“语音转文字模型”常驻入口，可查看未下载、下载中、校验中、失败或已就绪状态。

录音自动转写：缺模型时保留 pending 任务，并在录音详情 / 转写中心显示“音频已保存，下载模型后可转文字”与“下载模型”入口；不在录音进行中突然弹页打断采集。

若用户取消下载，返回录音 / 文稿页面继续使用，待转写任务继续保留。后续再次点下载时复用校验通过的工件，只补缺失或损坏文件。

### UI/UX 风格确认

状态：**复用已确认设计系统**。依据项目根 `DESIGN.md`（2026-08-03 批准，含后续决策）中的 Aesthetic Direction、Typography、Color、Layout / Settings、Buttons、Accessibility，以及 `docs/design/interface-language.md`。

- 感受：简单、可信、可控制；关键词：原生、克制、清晰、内容优先。
- 页面采用现有单列原生 List / Form、系统字体、黑白灰主操作和语义状态；无需新品牌视觉。
- 参考 Apple 系统工具的下载状态层级；不增加营销插画、渐变、彩色卡片或付费升级推荐。
- 下载页作为二级页面隐藏主 Tab；状态与进度有文字，不只依赖颜色；触控目标至少 44 pt，支持 Dynamic Type、深色、VoiceOver 和 Reduce Motion。
- 既有视觉方向的决策人为 Human；本轮复用已确认视觉，按本文落实首次跳转及返回行为。

不单独制作低 / 高保真可点击原型：本次复用已有设置、导航与原生下载控件，状态和文案在本文明确；若后续决定制作原型，必须引用本节已确认的既有风格。实现后的设计和无障碍走查仍须交付。

### 状态、错误与恢复

| 状态 | 页面表达与操作 | 转写 / 数据行为 |
|---|---|---|
| 未下载 | 免费说明、大小、来源；下载模型 | 不运行推理，保留 pending 与音频 |
| 等待网络 / 系统调度 | 说明等待原因；取消 | 不展示虚假进度或记为识别失败 |
| 下载中 | 真实累计字节与进度；取消 | 禁止重复下载；录音不被阻塞 |
| 校验中 | 显示校验中，暂不可开始转写 | 临时文件不能作为模型加载 |
| 已就绪 | 可离线使用；返回 | 依现有推理准入恢复待处理队列 |
| 断网 / HTTP 失败 | 下载未完成；重试 | 仅补失败工件，保留成功工件 |
| 存储不足 | 说明需释放空间；重试 | 不删除录音或文稿腾空间 |
| 校验不通过 | 模型文件不完整；重新下载 | 隔离该文件，禁止进入推理 |
| 取消 / 强制退出后重开 | 显示实际剩余状态；继续 / 重试 | 已验证文件保留，重建系统任务映射 |

实施默认使用 Wi-Fi；下载页提供明确的“允许使用蜂窝网络”选项与实际下载大小。已有续传请求只有在网络策略与本次选择一致时才复用。

### 下载提示交互优化（2026-10-09）

产品负责人反馈现有提示不突出，要求用小横幅明确当前状态与建议操作。范围为录音详情的逐字稿区域、转写任务中心和模型下载页，复用 `DESIGN.md` 的 Typography、Color discipline、Buttons、Spacing 与 Accessibility；不另做原型或改变已有导航及下载策略。

- 转写区域顶部使用同一紧凑状态横幅：图标、明确标题、简短说明和单一的黑白主按钮。未下载明确“下载模型，开启免费转写”；下载中 / 等待 / 检查显示实际状态及真实字节进度，入口改为“查看下载进度”；失败展示原因与重试入口。模型就绪后移除转写区域的横幅。
- 模型下载页顺序改为状态横幅、网络选择与下载 / 重试 / 取消操作、下载大小及魔搭来源、后台与隐私说明。页首提示只展示实际状态，不在传输中继续劝用户重复下载；就绪时说明可离线使用。
- 中性底色和少量语义图标传达层级，不使用整块橙色卡片、营销插图或自动弹窗。正文允许折行，按钮至少 44 pt，下载主按钮 52 pt；标题 / 说明 / 按钮分别可供 VoiceOver 读取。
- 录音和已有文稿保持可用，空文稿不重复展示横幅中已有的缺模型提示。前往下载只打开页面，仍需明确点击下载按钮才能创建网络任务。

验收：三处状态文案和动作一致；下载页首屏能找到下载入口；未下载 / 等待 / 下载 / 检查 / 失败 / 就绪均有明确表达；中英文文案齐全，实际大小和进度来自下载服务。编译与静态走查不代替真机深浅色、大字和 VoiceOver 验收。

## 技术设计与接口

### 模型目录与清单

- 产品层维护一个受控目录，例如 `Application Support/TranscriptionModels/`，不参与系统备份或 iCloud 文稿同步。
- App 保留 manifest、模型归因 / 许可文本与推理运行库；四个权重文件不进入 App 或嵌入 framework。
- 清单由 App 版本随包发布，包含模型集合版本、工件 ID、相对文件名、精确大小、SHA-256、公开 HTTPS 下载地址、固定 revision 和许可来源。服务端仓库变更不能绕过哈希校验。
- 优先使用魔搭不可变 revision；若暂只能用分支地址，仍以随包 SHA 固定内容，变化必须失败而不是接受新权重。发布前验证 revision 的平台支持。
- 目录仅接受清单中的文件；先下载到 staging，校验后原子发布。就绪状态来自实际文件与清单的匹配，不依赖一个可过期的 UserDefaults 布尔值。
- 按缺失工件、下载临时文件和替换余量检查可用空间，不把 294 MB 当作所有设备上的精确峰值需求。

### 系统后台传输

- 单个稳定标识的 `URLSessionConfiguration.background(withIdentifier:)`；`sessionSendsLaunchEvents = true`。用户前台点击下载后一次提交全部缺失工件，不串行等待后台回调才创建下一件。
- 下载服务管理 task ID / artifact ID、进度、已验证文件、错误与系统提供的 resume data。支持时续传，不支持则重下相应工件；不能宣称任意服务端都支持字节续传。
- `didFinishDownloadingTo` 返回前把临时文件搬到受控 staging；随后流式校验，处理完全部事件再调用 UIKit completion handler。
- 启动重建相同 session，使用 `getAllTasks` 恢复真实在途任务。禁止仅凭保存的“下载中”字符串展示永久假进度。
- 文件已进入 staging 但校验未完成时若 App 被终止，重新打开后继续校验 staging；只有校验成功才发布，不永久停留在“校验中”或直接信任旧状态。后台时间不足时保留 staging，后续继续校验。
- 融合 `Vendor/Phone/src/ios/AppDelegate.swift` 与独立 `speech_noteApp.swift` 都要接入 `handleEventsForBackgroundURLSession`，通过产品桥接访问同一下载服务。

### 加载路径与队列准入

统一改造四处 Bundle 模型加载：

1. `Infrastructure/Inference/SenseVoiceInferenceService.swift`：当前从 Bundle manifest 目录加载前三个模型。
2. `Features/Speakers/OfflineSpeakerReclustering.swift`：离线说话人重聚类与嵌入。
3. `Features/Speakers/SpeakerDiarizationEngine.swift`：pyannote 与说话人嵌入 ONNX（当前工件为 ERes2Net）。
4. `Vendor/Phone/src/ios/HardwareBridge/Transcription/HardwareVoiceTranscriber.swift`：聊天 / 硬件本地语音共用。

在产品层提供统一可校验的模型路径解析 / 就绪能力，保留现有模块边界和 `Vendor/TranscribeKit` 固定快照。Phone 的必要适配按 `docs/architecture/openminis-upstream.md` 记录为产品 fork 定制。

`TranscriptionAdmissionPolicy` 移除购买条件，引入模型就绪条件。利用现有 `deferInference` 保留待处理任务，不把尚未下载计为识别错误。模型完成事件请求 scheduler drain；scheduler 仍负责决定当前是否允许推理。

### 安装包与生成工程

- `tools/integration/generate_project.py` 当前逐个打包整个 ModelResources，需改为仅保留清单 / 许可等小资源。
- 独立 `speech_note.xcodeproj` 的 filesystem synchronized membership 同步排除四个权重，否则独立 App 仍会携带模型。
- `tools/integration/verify_fusion.py` 由“模型必须在包中且哈希正确”改为“manifest / 许可存在，App 及其 framework 中无四个权重”。生成工程必须从脚本刷新，不能只修改生成结果。
- 开发机资源获取脚本仍可为离线测试准备模型，补齐当前未获取的 pyannote 工件，并与生产清单保持一致。

## 旧用户与发布迁移

免费开放立即取消旧试用到期 / 已购 / 未购之间的准入差异。保留历史录音、文稿、声纹、容器和 Bundle ID；旧购买存储不再决定功能可用性。

**旧内置模型无法保证在一次小包升级后复用。** 当前模型仅在旧 App Bundle，没有持久目录副本；覆盖升级会替换旧 Bundle。

2026-10-09 产品负责人明确确认：现有实际用户较少，接受老用户升级后首次使用转写重新下载模型的影响，继续直接小包更新，不制作过渡版或增加旧 Bundle 模型迁移。历史录音、文稿和声纹继续保留；发布说明需明确此次升级后首次转写需要下载约 294 MB 模型。

已下载到新持久目录且匹配清单哈希的工件，在后续覆盖升级中可直接复用。

商店材料需改为免费、首次按需下载和下载后离线；移除价格、购买与恢复购买审核路径。App Store Connect 商品停售是独立发布步骤，代码删除不能当作商品已停售。历史已购用户的退款 / 补偿不自动执行，也不在本次实现范围内新增政策。

## 隐私与模型来源

魔搭只分发模型文件；本地转写路径不上传音频、文稿或声纹。无需在客户端嵌入开发者魔搭 token；发布前核验公开文件无登录可达、实际内容 / 大小、Range 行为及重定向后的下载生命周期。

保留当前模型许可、作者和转换工件来源。魔搭相同名称的仓库不能单独证明格式兼容或重新分发权利；在既有许可结论基础上核对分发工件与归因记录，不以“免费功能”代替已有许可要求。

平台参考入口：[ModelScope 官方 SDK file_download.py](https://github.com/modelscope/modelscope/blob/master/modelscope/hub/file_download.py)、[模型下载文档](https://modelscope.cn/docs/models/download)。本次固定 revision、文件大小 / SHA 元数据及 Range 支持的结论来自实际 API 与 HTTP 响应，详见核验回执。

## 交付任务草案与依赖

以下为仓库内实现拆分，FT-* 是本文内部标识，未创建外部 PM 工作项。没有可读的现有里程碑，不虚构版本或发布日期。

| ID | 可独立评审的产出 | 设计输入 / 实现锚点 | 验收标准 | 依赖 | 建议执行角色 |
|---|---|---|---|---|---|
| FT-01 | 魔搭四工件分发核验与清单 | 本文模型 / 清单章节；ModelManifest.json | 已完成地址、固定 revision、匿名 Range 及 SHA 元数据核验；实现时将四件直链 / 大小 / 哈希写入清单，完整下载后仍须全文件校验 | 无 | Codex |
| FT-02 | 删除购买与试用，迁移旧待购任务 | 本文内购 / 迁移章节；Purchase、RecordingCoreModel、ContentView、Onboarding、VoiceRecordingWorkspace | 无 StoreKit 请求、购买入口或倒计时；旧过期用户可录音 / 免费转写；旧 pending 可恢复，音频和改稿不丢失；相关 HostTests 更新 | 无，可与 FT-01 并行 | Codex |
| FT-03 | 模型持久目录、下载服务与校验 | 本文系统后台传输 / 目录章节；新增产品服务和两套 AppDelegate 桥接 | 未点击不下载；所有缺件任务可恢复；部分文件不 ready；坏哈希不加载；失败只补缺件；持久模型不备份 | FT-01 | Codex |
| FT-04 | 下载页与各入口引导 | 本文流程 / 状态 / UI 风格章节；设置、详情、转写中心、聊天本地语音入口 | 原生风格、正确大小和状态；首次点击引导；取消能返回；离开后不重复任务；VoiceOver / Dynamic Type 状态文案齐全 | FT-03；实施前确认 App 内流程 | Codex |
| FT-05 | 所有加载器与模型准入接入 | 本文四处加载路径 / 队列章节 | 录音不因缺模型受阻；任务等待模型且不报识别失败；下载后会议、重聚类与聊天共用正确文件；沿用现有 scheduler / lifecycle 准入，下载回调不额外授予推理权限 | FT-02、FT-03 | Codex |
| FT-06 | 小包资源规则、检查与发布资料 | 本文安装包 / 发布章节；生成器、独立 pbxproj、verify_fusion、商店材料 | 两套工程排除权重；产物递归确认无权重而清单 / 许可完整；免费及首次下载文案一致 | FT-03、FT-05 | Codex |
| FT-07 | 实机生命周期与升级验收报告 | 本文验收矩阵；AGENTS.md | 每项有真实设备证据或标未测；后台 / 锁屏、网络、退出恢复、升级、免费旧用户、无障碍均覆盖 | FT-04、FT-05、FT-06；该次真机运行需明确授权 | 获授权的 Codex / Human |
| FT-08 | 商店商品停售与版本提交 | 本文发布迁移；现有发行流程 | 已确认免费元数据与商品状态；版本提交 / 发布有实际回执 | FT-07；外部发布授权 | Human |

FT-02 与分发核验可并行；建议作为同一产品调整交付，模型来源就绪后接入服务、页面、加载器和小包验证，再进入获授权的真机验收与商店流程。具体版本使用项目现有里程碑或服务端生成的下一 SemVer，服务恢复后再归属。

### 设计工作适用性

产品范围、信息架构、首用 / 返回流程、状态和文案由本文覆盖；视觉复用 DESIGN.md，不新增原型任务。无障碍规格归 FT-04，设计 / 可用性 / 无障碍走查归 FT-07。持久目录、旧状态兼容、接口、测试和发布分别归 FT-02 / 03 / 05 / 06 / 07 / 08。购买删除文案、流量与隐私说明纳入 FT-02 / 04 / 06。

## 验收矩阵

- [ ] 新装、旧试用未到期、已到期、已购用户均无购买界面或转写次数 / 时间收费限制。
- [ ] 模型未下载时录音、Widget 开录、回听、已有文稿阅读仍可用，音频与旧修改不丢失。
- [ ] 点击本地转写引导下载页，点击下载才联网；取消、返回与再次进入状态一致。
- [ ] 四件齐全且哈希正确前不运行推理；部分文件、错误页响应和篡改文件均被拒绝。
- [ ] App 切后台 / 锁屏可由系统继续传输；系统回收后任务重新关联；用户强制退出后的限制与恢复说明准确。
- [ ] 断网重试、空间不足、校验失败和系统不支持续传时均可恢复，不重复已成功工件。
- [ ] staging 校验阶段被终止后，重新打开可继续校验 / 隔离坏文件，不假 ready 或永久卡在校验中。
- [ ] 模型已就绪且设备允许推理时续跑 pending；下载完成不会自动开麦或在禁止后台推理时调用 Metal。
- [ ] 会议转写、导入 / 重转写、说话人重聚类及聊天本地语音输入均读取下载目录；后续覆盖升级复用匹配文件。
- [ ] 两套工程的实际 App / framework 产物不含四个权重，manifest / 许可完整。
- [ ] 下载完成后断网仍能本地转写；下载请求不包含音频 / 文稿 / 声纹。
- [ ] 页面深浅色、Dynamic Type、VoiceOver、Reduce Motion 和二级页 Tab 行为符合 DESIGN.md。

当前完成：FT-01 至 FT-06 的代码与发布文案已落地，包括购买删除、下载与安装校验、四处加载器、设置 / 详情 / 任务中心 / 聊天入口和两工程资源规则。macOS host 回归覆盖历史任务与文稿保全、缺模型准入、后台冷启动等待、文件完整性、部分集合拒绝、staging 恢复、原子替换及续传网络策略。通用 iOS 设备编译和产物检查作为开发验证；未运行 iOS App 或模拟器，不将这些检查当作 FT-07 真机后台下载验收。

## 实施决定与待验收

- 下载页与开发范围已由产品负责人确认，当前采用 App 内页面，魔搭供文件。
- 升级与网络默认按本轮开工时说明实施：直接小包升级后按需下载，Wi-Fi 默认、蜂窝显式选择。
- 下载完成只恢复已有队列，不自动重新打开聊天麦克风；未就绪时手动重转写先进入下载页，保留已有内容，完成后返回可再发起重转写。
- 下载服务启动只重关联已有系统任务并验证本地文件；创建新网络任务仅由用户点击触发。两套 AppDelegate 均接入后台事件完成回调。
- 后台冷启动先按实际 UIApplication 状态关闭队列准入；scene 初始状态同步，下载完成通知仅请求已有许可下的处理。说话人队列按任务和音频窗口检查执行许可，等待期间保留 pending。
- 魔搭分发地址、大小 / SHA 元数据与匿名固定版本 Range 已通过核验；App 完整下载与实机后台 / 锁屏 / 退出恢复仍待 FT-07 授权验收。App Store Connect 商品停售与最终版本提交归 FT-08，未执行。

项目 `.1agents/project_config.json` 的 `featureCatalogEnabled=true`。已执行 PM 启动检查，读取项目项 / 功能蓝图 / 里程碑时，本地 `127.0.0.1:38080` 服务在授权重试后仍拒绝连接，因此未取得既有树与稳定编号，未创建隐藏蓝图或重复任务。FT-* 仅为本文内部标识，不是已登记的 PM / Plane 编号。

仓库最近计划沿用 Plane「听记 / TINGJI」，见 `docs/planning/2026-10-09-progress-and-next-steps.md`。本轮尚未向 Plane 写入。后续按用户指定的管理入口，先回读既有需求再增量关联本设计；来源建议拆为“语音转文字免费开放”和“模型安装后按需下载”两个 requirement。功能归属建议为“录音与转写 / 免费使用”和“录音与转写 / 模型下载与就绪”，读取原树后再决定复用节点。
