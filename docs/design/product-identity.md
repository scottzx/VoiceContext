# 一芥伙伴 / Yima 产品身份

用户确认日期：2026-09-29。

## 名称与定位

- 中文名：**一芥伙伴**。
- 英文名：**Yima**。
- 定位：**手机上的个人助手 / Personal Agent**。
- 产品说明：帮助用户记录、理解和处理日常事务，整合聊天、会议录音、系统提醒事项与 shell、Skills、浏览器等 Agent 能力。可靠录音仍是核心能力。
- 开发版显示名：中文「一芥伙伴 Dev」，英文「Yima Dev」。

主 App、分享扩展、文件提供者和 Widget 的显示名由融合工程生成器维护，本地化资源按构建配置生成，避免英文系统下 Dev 后缀被覆盖。关于页使用本产品名称、定位及 OpenMinis 来源说明。

## 兼容性约定

| 项目 | 保持值 |
|---|---|
| 正式 / TestFlight Bundle ID | `YiJie.speech-note` |
| 开发 Bundle ID | `YiJie.speech-note.dev` |
| 扩展身份 | 保留各自正式 / Dev 前缀和现有后缀 |
| 代码仓库目录 | `voice_type` |
| Xcode 入口 | `VoiceContextAgent.xcworkspace` |
| Scheme | `VoiceContextAgent` / `VoiceContextAgentDev` |
| 原录音数据 | `Documents/VoiceContext` |
| Agent 文稿桥 | `/var/minis/shared/VoiceContext` |

iCloud 容器、App Group、Keychain、StoreKit 商品、深链和内部模块名继续沿用现有标识。更名不迁移或清空数据，不创建新的商店应用，也不修改原始源码来源和许可证。

历史验证记录、已发布版本材料和磁盘目录中出现的「听记 / VoiceContext」保留其历史含义。当前 README、融合设计和关于页使用新定位；视觉样式沿用 `DESIGN.md`，本次不更换图标或重做界面。

App Store Connect 名称、截图和商店描述需在后续发布时更新；仓库修改不会自动改变线上商店信息或手机上已安装的旧构建。

## 验证记录

更名后 `Debug-Dev` 与 `Debug` 的未签名 iphoneos 构建通过，主 App 和四个扩展的中英文显示名、Dev 后缀及身份装配审计通过。原有 entitlements 文件指纹未变。证据保存在本机 `build/yima-branding/`。本轮未重新安装或启动 App，手机上此前安装的「听记 Dev」仍是更名前构建。
