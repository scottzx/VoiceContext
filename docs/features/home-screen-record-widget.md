# 主屏录音 Widget（FR-ADD-WDG / #70）

## 行为

- 主屏 **录音** Widget（small / medium）主操作打开 deep link：`voicecontext://start-recording`。
- App 收到链接后进入开录流程：
  - **已授权麦克风**：直接开始录音（尽量少打断）。
  - **未授权 / 未决定**：打开「开始记录」表单；拒绝时展示应用内权限说明与「前往系统设置」，**不静默失败**。
- Widget **不展示逐字稿**或其它隐私文稿内容；仅展示 Record 控件文案。

## 实现要点

| 组件 | 路径 |
| --- | --- |
| WidgetKit 扩展 | `speech_note/RecordWidget/` |
| Deep link 解析 | `speech_note/speech_note/AppDeepLink.swift` |
| URL Scheme | `Info.plist` → `CFBundleURLTypes` / `voicecontext` |
| 开录响应 | `ContentView.handleWidgetStartRecording()` |

- **不需要 App Group**：Widget 只负责打开 URL，不共享录音或文稿数据。
- **未设置** `CODE_SIGN_ENTITLEMENTS`，也未写入具体 iCloud container（沿用现有本地优先 / 真机签名策略）。
- Widget bundle id：`YiJie.speech_note.RecordWidget`（主应用 `YiJie.speech_note` 的扩展）。

## 真机：如何添加 Widget

1. 用 Xcode 将 **speech_note** scheme 安装到设备（会一并嵌入 `RecordWidgetExtension.appex`）。
2. 若首次安装扩展后主屏没有新组件：删除 App 重装一次，或重启 SpringBoard（锁屏后再试）。
3. 长按主屏空白处 → **编辑** → **添加小组件** → 搜索 **「录音」** 或 App 显示名 → 选择 small/medium → **添加小组件**。
4. 轻点 Widget → 应冷启动/唤起 App 并进入开录或权限说明。

### 若 Xcode 未自动嵌入扩展

1. 打开 `speech_note.xcodeproj`，确认 target **RecordWidgetExtension** 存在。
2. 选中主 target **speech_note** → **General** → **Frameworks, Libraries, and Embedded Content**（或 Build Phases → **Embed Foundation Extensions**）中包含 `RecordWidgetExtension.appex`，**Embed** / **Remove Headers on Copy**。
3. 主 target **Dependencies** 包含 `RecordWidgetExtension`。
4. 扩展 **Signing & Capabilities**：Automatic，Team 与主应用一致；**不要**为通过签名而添加具体 iCloud container / 勿给主应用重新挂上会破坏真机签名的 entitlements 文件。
5. 扩展 Info 需含 `NSExtensionPointIdentifier = com.apple.widgetkit-extension`（见 `RecordWidget/Info.plist`）。

### App Group（当前不需要）

仅当未来要在 Widget 上展示录音状态/时长等共享数据时，再考虑：

1. 主应用与扩展同时开启 App Groups（例如 `group.YiJie.speech_note`）。
2. 只共享非隐私状态字段；**禁止**把逐字稿写入 App Group。
3. 仍保持 Widget UI 无文稿预览。

## 验收对照

- [x] 可安装主屏 Widget，主操作进入开录流程（deep link → start sheet / 直接开录）。
- [x] 无麦克风权限时进入应用内说明，不静默失败。
- [x] Widget 不展示逐字稿内容。

## 已知缺口 / 后续

- 未做锁屏 / StandBy / Control Center 控件（本任务仅主屏 Widget）。
- Widget 不会显示「正在录音」实时态（无 App Group）；录音中再次点击会唤起录音中界面。
- 引导文案若需商店截图，可在 `docs/design/v1/` 补一张 Widget 示意。
