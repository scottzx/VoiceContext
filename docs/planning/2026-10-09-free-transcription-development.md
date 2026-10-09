# 免费转写与按需模型下载开发验证

日期：2026-10-09。依据：[实施设计](../design/free-transcription-model-download.md)。产品负责人已确认按该方案开发，并授权编译到真机。本记录描述开发检查与真机安装，不表示已完成完整真机验收、商店商品停售或版本发布。

## 实施结果

- 删除购买 / 恢复购买、72 小时试用和收费准入代码、界面、StoreKit 配置及相应测试；历史 `lockedPendingPurchase` 兼容解码并作为普通待处理任务继续。
- 四件模型使用魔搭固定 revision `0ac25de3b24eae49f5bf00dc485ef954b1f23a31`，合计 294,462,733 bytes；只有用户点击下载才创建网络任务，默认 Wi-Fi、蜂窝显式选择。
- 系统后台 URLSession 重关联已有任务，展示真实字节进度；支持取消、失败重试、匹配网络策略的 resume data、staging 恢复、全文件大小 / SHA-256 校验和原子安装。Application Support 模型目录设置排除备份。
- 设置、录音详情、任务中心及聊天本地语音提供下载入口；缺模型保留录音和队列，已存在的文稿仍可读。下载完成恢复已有队列，聊天麦克风需要再次主动开启。
- 四处模型加载器使用统一已验证目录；两套工程排除四件权重，保留清单、归因及许可。融合 App 的独立聊天 VAD 资源约 4.14 MB 保留，并按固定路径、大小和哈希审计。
- 后台冷启动先关闭 ASR 准入，初始化即建立恢复屏障；scene 初始状态同步，恢复完成后才允许处理。说话人处理按源任务和音频窗口检查执行许可，门禁延后与用户重转写取消有不同原因，均保留可靠持久状态。

## 开发检查

| 检查 | 结果 / 边界 |
|---|---|
| 融合开发版 `VoiceContextAgentDev`，通用 iOS 设备，无签名 build | 通过；没有安装或运行 App |
| 独立 `speech_note`，通用 iOS 设备，无签名 build | 通过；没有安装或运行 App |
| 融合开发版 `VoiceContextAgentDev` / `Debug-Dev`，连接的 iPhone 15 Pro 签名 build | 通过；Xcode 27.0，Apple Development 签名，`codesign --verify --deep --strict` 通过，签名产物资源审计通过；主 App 与四扩展的描述文件均有效、覆盖目标设备，Team / App ID 与开发版容器权限匹配 |
| USB 真机更新安装与安装后查询 | 通过；设备 `scottxz`，iOS 27.0.1，`devicectl` 返回安装成功；查询确认 `YiJie.speech-note.dev` / Yima Dev 1.0 (7)。更新开发版，未卸载 App，未启动 App 或操作麦克风 / 模型下载 |
| `verify_fusion.py --variant development --products build/VoiceContextAgent/Build/Products/Debug-Dev-iphoneos` | 通过；实际 App / framework 未带四件转写权重，清单与许可匹配，聊天 VAD 精确校验通过 |
| 独立 App 递归资源审计 | 通过；四件权重与 `.partial` 不存在，唯一清单及全部归因 / 许可与源码一致 |
| `verify_fusion.py --variant production` | 通过；正式版配置静态检查，未构建正式发行归档 |
| `HostTests/verify_model_download.py` | 通过；缺失 / 部分模型拒绝、同大小坏 SHA 拒绝、重开 staging 恢复、原子替换、已验证文件删除失效、续传网络策略；使用临时小文件，无网络 |
| `HostTests/verify_transcript_protection.py` | 通过；11 组，包括旧文稿兼容、校对保护、旧待购买任务免费续跑与音频 / 文稿字节不变、冷后台模型就绪不执行、前台只续跑一次、初始恢复屏障 |
| `HostTests/verify_recording_entry_playback.py` | 通过；录音入口并发 / 权限失败恢复、播放时间边界；macOS host 检查 |
| Swift parse、脚本语法、plist / JSON 解析、`git diff --check` | 通过；新页面静态检查沿用 DESIGN.md 的原生 List、语义字体、单色操作和至少 44 pt 按钮 |

模型服务已通过默认 MainActor、完整 concurrency 选项的 macOS 类型检查。新说话人执行门禁的 iOS 回归测试已编写，未运行；实际模型推理测试显式依赖预下载的模型并默认禁用，不会在测试启动时主动联网。

## 下载提示交互优化

2026-10-09 根据产品负责人反馈，录音详情逐字稿区域、转写任务中心和模型下载页共用紧凑状态横幅，包含标题、说明、语义图标和明确操作。未下载提示首次下载大小与免费转写；下载 / 等待显示真实字节进度；检查、失败和就绪分别表达实际状态。详情空文稿区域去掉重复的缺模型提示，已有文稿继续展示。

下载页将状态和网络选择 / 下载操作前置，来源、后台及隐私说明后置。主要按钮最小高度 52 pt，采用黑白反色；文本使用语义字号、自然换行，未新增自动下载或自动录音。

增量检查通过：融合开发版签名 build、独立 App 无签名 build、`codesign --verify --deep --strict`、实际产物 `verify_fusion.py`、`git diff --check`。15 条新增文案在生成器、两套源资源和实际 App 的中英文 `.strings` 中逐项核对通过；显式保留中文条目，兼容融合 App 的英文源语言清单合并。

已通过 USB 更新安装至 iPhone 15 Pro `scottxz` 的 Yima Dev 1.0 (7)，安装回执成功。未启动 App 做视觉走查；深浅色、Dynamic Type 至 accessibility3、VoiceOver 和六种状态的实际界面仍待真机验收。本次只调整提示呈现和操作层级，模型下载服务及录音 / 转写调度逻辑保持原实现。

## 尚未验收的外部步骤

未启动任何 iOS 模拟器。开发版已编译并安装到物理 iPhone，尚未启动 App 做功能验收。真实下载完整文件、系统后台 / 锁屏调度、断网 / 强制退出恢复、设备实际备份属性、正式版覆盖升级与 VoiceOver / Dynamic Type / 深浅色走查仍未验收。

App Store Connect 旧商品停售、截图替换、最终归档上传和发布未执行，见[发布清单](../release/free-transcription-model-download.md)。旧内置模型不会跨小包升级自动保留，老用户首次转写需按需下载；已有音频、文稿与持久模型目录保持原身份和相对路径。
