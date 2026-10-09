# 免费转写与模型按需下载发布清单

更新日期：2026-10-09。适用于一芥伙伴 / Yima 当前融合版本。功能依据：[实施设计](../design/free-transcription-model-download.md)。本文提供提交文案和发布检查，不表示已完成真机验收、商品停售或商店发布。

语音转文字免费开放，新老用户均不受原试用和购买状态限制。安装包保留模型清单、归因、许可与本地推理运行库，四个模型权重首次使用时由用户主动下载；合计 294,462,733 bytes，界面约为 294 MB。下载完成并校验后可离线转写。

2026-10-09 已确认直接发布小包更新，不发过渡版本。旧版模型只在安装包中，老用户升级后首次转写也需下载约 294 MB 模型；历史音频、文稿和声纹保留。已保存至新版持久目录且校验有效的模型在后续升级中复用。

融合 App 保留约 **4.14 MB（4,135,046 bytes）** 的独立聊天 VAD 资源，用于原有系统 / 云聊天语音采集。它来自 `Package.resolved` 锁定的 `RealTimeCutVADLibrary` 1.0.14（revision `b059608836a055dc0ce74ca2d0eeb19fc54cb7d4`），包含实际使用的 Silero v5 和包内 v4。包内 v4 与本次 644 KB 的转写 VAD 同名但内容不同；这两份第三方资源按固定路径、大小和 SHA-256 核对并保留，不属于四件按需下载工件，不修改依赖快照或构建时剥离。

## 商店说明替换文本

简体中文：

> 语音转文字免费使用。首次使用时，在 App 内下载约 294 MB 的本地模型；下载完成后可离线转写。模型来自魔搭平台，无需魔搭账号。录音、回听和阅读已有文稿不需要先下载模型；本地转写不会将音频上传到魔搭。

English (U.S.):

> Speech-to-text is free. Download approximately 294 MB of local models in the app when you first need transcription. Once the download is verified, transcription works offline. Models are distributed through ModelScope; no ModelScope account is required. Recording, playback, and reading existing transcripts remain available before downloading. Local transcription does not upload your audio to ModelScope.

删除商店描述、截图和宣传页中的 72 小时试用、永久解锁价格、购买与恢复购买入口。保留当前实际交付能力的描述；更新截图时依照仓库 `DESIGN.md`，只使用已验收的界面和示例数据。

## App Review Notes 草案

> Speech-to-text is free for all users. This build does not offer in-app purchases or a trial period. To review local transcription: record a short clip, open the recording, and choose transcription. If models are missing, the app opens its model download page. Tap Download Models to begin an approximately 294 MB download from the public ModelScope repository. No ModelScope account is required. After all four files pass local integrity checks, transcription runs on device and works offline. Recordings and transcripts are not uploaded to ModelScope. Recording, playback, and existing transcripts are available without downloading models. The download can continue while the app is suspended; if the user force-quits the app, reopen it to recover or retry the download. Model downloading itself does not authorize background transcription.

上述英文在本次构建通过相应真机验收后用于提交。其他聊天服务或授权工具的网络行为应按最终产品的实际情况另行披露，不能将本地转写的隐私说明扩展为整个融合 App 都无网络或无账号。

## 工程与开发资源检查

- `tools/integration/generate_project.py` 只将模型清单和 `.md` / `.txt` 归因许可文件复制到融合 App；独立工程也排除四个权重文件。
- `python3 tools/integration/verify_fusion.py` 检查两套工程的资源规则与 manifest 元数据。提供 `--products` 后，递归检查 App 及其扩展 / framework 不含四个按需权重，同时核对随包清单、许可文本及独立聊天 VAD 的两个固定工件；第三方同名资源只有在确切路径、大小与 SHA-256 均匹配时才放行。
- `zsh tools/fetch-model-resources.sh` 仅用于开发机准备离线资源，不由构建或 App 首次启动调用。它读取清单的固定版本 `downloadURL`，下载包括 pyannote 在内的全部四件，验证大小和 SHA-256 后才替换本地文件；中断的下载使用 `.partial` 文件续传。
- `zsh tools/verify-model-resources.sh` 检查开发机模型大小与 SHA-256。开发目录存在模型不表示模型进入安装包。

## 发布验收与外部步骤

- [ ] 对最终归档执行 `verify_fusion.py --variant production --products <归档的 Products/Applications>`，确认四个权重未进入 App，清单和归因许可完整。
- [ ] 获用户明确授权后，在物理 iPhone 验证首次主动下载、锁屏 / 后台、断网恢复、取消、校验失败及重新打开的恢复行为。
- [ ] 新装及旧试用未到期、到期、已购状态均无购买界面，下载后可免费转写；模型未下载时仍可录音和查看旧文稿。
- [ ] 从旧版覆盖升级后，音频、文稿和声纹保留；首次转写明确引导重新下载模型。新版持久目录中的有效模型在后续升级中复用。
- [ ] 商店文案、截图、隐私政策与审核说明统一为免费及首次按需下载，明确模型分发网络请求与本地音频处理边界。
- [ ] Account Holder 在 App Store Connect 检查并停售旧内购商品。移除客户端代码不代表商店商品已停售；本文不代替外部操作回执。
- [ ] 使用实际版本号与 Build 号提交已验收归档，记录上传、审核和发布结果。没有执行上述外部操作前，不标为已发布。
