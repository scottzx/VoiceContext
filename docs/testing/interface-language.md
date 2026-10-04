# 统一界面语言验收记录

日期：2026-10-03。设计依据：[统一界面语言与 token](../design/interface-language.md)、[`DESIGN.md`](../../DESIGN.md)。

## 实现范围

- 一份 [`YimaDesignTokens.swift`](../../Integration/Shared/YimaDesignTokens.swift) 同时编入 App 和 VoiceRecording；SwiftUI／UIKit 共用文字角色、颜色和尺寸。
- 待办的月份／章节标题从 22 pt 收敛为 headline 17 pt，减少标题与子分组重复留白；保留日历类型点、今天旁的 info、来源筛选及到期左／提醒右同行。
- 聊天正文／输入基准从 16.5 pt 调为 17 pt，Markdown 标题、代码和段落接入角色；字体变化同步刷新 renderer、prebuilt 内容、附件和高度缓存。导航／工具操作接入 44 pt 点击区。
- 会议列表、详情元信息和正文接入共享角色；录音内容行最小 64 pt。逐字稿改为文档流，保留时间定位、说话人筛选、编辑、复制与播放位置提示。
- 默认助手图标、会话／工具类别、代码和说话人分类使用中性色；真实录音／失败／处理状态保留语义色。工具圆点动画遵守 Reduce Motion。
- 纪要产物文件列表已接线；系统 QuickLook 的文档内部排版未改造。

## 构建与静态检查

| 检查 | 结果 | 证据 |
|---|---|---|
| iPhoneOS Debug-Dev 编译 | 通过，最终缓存、对比度、点击区及现场分类颜色修补后再次编译 | `build/yima-design-language-verified-build.log`，`BUILD SUCCEEDED` |
| 工程／产物组装 | 通过，两模块的 token 源码均恰好一份 | `build/yima-design-language-assembly-audit.json` |
| 主 App 与 4 个扩展签名 | 通过，设备 provision 与开发版 App Groups 匹配 | `build/yima-design-language-signing-audit.json` |
| 字号策略边界检查 | 通过 | [`test_design_font_policy.swift`](../../tools/integration/test_design_font_policy.swift) |
| legacy project plist 与 diff 格式 | 通过 | `plutil -lint`、`git diff --check` |
| 旧字号缓存回挂复核 | 通过静态检查 | renderer 恢复实际字号；prebuilt 显示与测量均核对生成字号标记 |
| 新无障碍标签 | 通过静态检查 | 三个新增标签均含英文和简体中文翻译 |
| 小号警告／录音状态文字对比度 | 通过基于 token 的计算检查 | warningText 白底 6.80:1、深色 surface 9.54:1；recordingText 搭配 8% 同色白底 4.66:1 |

编译仍有弃用等警告，本轮未清理整个工程的警告。对比度为指定颜色及 alpha 的计算值，不替代真机对全部背景的走查。两处红色状态标签的底色由 12% 降至 8%，修复原组合约 4.33:1 的小字对比度问题。`build/` 内日志为本机证据，不作为可移植交付文件。没有使用 iOS Simulator。

复现命令：

```sh
xcodebuild -workspace VoiceContextAgent.xcworkspace -scheme VoiceContextAgentDev \
  -configuration Debug-Dev -destination 'platform=iOS,id=00008130-00063D581AFA001C' \
  -derivedDataPath build/VoiceContextAgent -clonedSourcePackagesDirPath build/PhonePackages \
  -disableAutomaticPackageResolution build
python3 tools/integration/verify_fusion.py --variant development \
  --products build/VoiceContextAgent/Build/Products/Debug-Dev-iphoneos
xcrun swiftc -module-cache-path /tmp/yima-swift-module-cache \
  Integration/Shared/YimaDesignTokens.swift tools/integration/test_design_font_policy.swift \
  -o /tmp/yima-test-design-font-policy
/tmp/yima-test-design-font-policy
```

## 字号偏好兼容对照

三个 UserDefaults 键保留，不清零、不合并。下表为源码映射及系统 `.large` 时的计算参考，不是真机像素或实测字号。消息与输入各自使用其原倍率，先按系统 `.body` 缩放，再应用所属偏好，避免重复叠加 App 倍率。

| 已有档位 | App 通用类别（迁移前 → 后） | 消息／输入倍率 | 旧 16.5 pt 基准 | 新 17 pt 基准 |
|---|---|---:|---:|---:|
| XS | small → small | 0.88 | 14.52 | 14.96 |
| Small | medium → medium | 0.94 | 15.51 | 15.98 |
| Default | 固定 large → 跟随系统 | 1.00 | 16.50 | 17.00 |
| Medium | xLarge → xLarge | 1.06 | 17.49 | 18.02 |
| Large | xxLarge → xxLarge | 1.12 | 18.48 | 19.04 |
| Extra Large | xxxLarge → xxxLarge | 1.21 | 19.965 | 20.57 |

系统进入无障碍类别后，App 自定义类别不得低于系统类别；消息／输入倍率低于 1 时使用 1，但已保存偏好值保留。策略检查覆盖全部系统类别的默认继承、普通自定义映射、accessibility3 下限和内容缩放下限。UIKit 的实际 UIFontMetrics 曲线及三页布局仍需真机验证。

## 真机运行矩阵

设备：scottxz，iPhone 15 Pro，iOS 27.0 (24A437)。已安装授权的开发版 `YiJie.speech-note.dev`，保留现有数据与偏好；安装证据为 `build/yima-design-language-install.json`。

| 项目 | 结果 |
|---|---|
| 最新开发版安装／启动 | 通过；分类颜色补改后已重新安装并启动复核 |
| 三页相同环境的文字、间距、层级对照 | 已走查，沿用设备既有浅色／简体中文／字号；标题、正文、元信息和常用操作无静态覆盖 |
| 待办日历／info／筛选／到期提醒同行 | 通过：月／周切换、今天、info 说明、全部页筛选弹窗内日历／待办切换；到期左、提醒右。编辑入口打开后取消，无事项写入；未改变来源勾选 |
| 历史聊天／长 Markdown／键盘与输入 | 已走查标题、正文、粗体、列表、分隔线及行内代码；滚动正常。选择菜单和拷贝动作可执行，未读取剪贴板内容；镜像键盘输入四行临时英文后已清空，输入框自然增高。代码块／表格与手机软键盘遮挡未验证 |
| 会议列表／逐字稿／播放与筛选 | 列表／详情／元信息／逐字稿通过；播放、暂停、句菜单“从此开始播放”定位至 00:57、当前位置提示通过，结束时已暂停。倍速菜单可打开，未改变倍率；现有录音没有多说话人过滤样本，未测过滤 |
| 非默认 App／消息／输入字号，系统 accessibility3 | 未做运行验收；未重置或修改用户字体设置 |
| 深色、英文、VoiceOver、Reduce Motion | 未做完整运行矩阵；Reduce Motion 已有静态实现检查 |
| 新消息流式高度、录音跨 Tab 全局停止 | 未做本轮运行回归；原业务调用保留，不能据此标记通过 |

截图证据见本轮真机镜像操作的会话输出，使用同一设备；镜像像素不换算为 pt。未重置字号、语言、外观、来源选择；输入测试没有发送消息，临时草稿已恢复为空。

现场发现聊天会话列表仍使用自动主题分类的紫／黄等装饰色，与 `DESIGN.md` 冲突。已补改共享类别颜色映射和分类编辑面板，保留 category 数据、SF Symbol、用户 Soul 图标和真实运行状态；增量编译、签名、重装通过，安装后已确认列表及编辑面板的普通分类图标均为中性色，暂停状态的橙色标记仍保留。编辑面板打开后取消，未修改会话信息。Human 产品走查仍需核对阅读舒适度及特殊聊天组件形状。
