# 录音与锁屏卡片状态同步

日期：2026-10-01。

用户反馈：真实锁屏、来电已实测；播放其他音频使录音暂停时，锁屏卡片和灵动岛仍显示录音正常。

## 修复

- `RecordingSessionCoordinator` 在捕获中断、暂停/恢复成功后，先发布真实捕获状态及 Live Activity 更新，再等待 journal/间隙写盘。写盘失败不再阻止卡片反映已经发生的麦克风状态变化。
- `RecordingLiveActivityManager` 用短暂的 UIKit 后台任务保护 ActivityKit 更新，完成或到期即释放；更新与结束按顺序提交，避免旧状态覆盖新状态。
- 保留现有卡片布局与文案：系统中断显示“已中断”，手动暂停显示“已暂停”；恢复失败继续显示中断，仅捕获恢复成功才显示“正在录音”。

同步窗口修复和真机 ActivityKit 回归已通过。用户随后于 2026-10-01 回复“ok 没问题”，确认实际场景复测通过；这一结论来自用户交互实测反馈。ActivityKit 的后台更新依赖应用仍有执行时间，见 [Apple ActivityKit 文档](https://developer.apple.com/documentation/activitykit/activity/update(_:)) 与 [UIKit 后台执行说明](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time)。

## 验证

- `VoiceContextAgentDev` / `Debug-Dev`，仅 iPhone device 编译：通过。
- 融合装配、固定依赖指纹、模型资源和深层签名检查：通过。
- 增量安装至 `scottxz` 的 `YiJie.speech-note.dev`：通过。
- 回归启动：初次被 iOS 的 `Locked` 拒绝；用户解锁后启动成功。
- 真机 ActivityKit 回归：全部通过，报告 `passed: true`。首次即时读取在暂停/恢复阶段误报，增加最长 2 秒的异步内容传播观察后通过；这一轮仅修正读取时机，未更改生产状态同步代码。

DEBUG 参数 `--recording-activity-probe` 运行专用回归。使用临时目录和模拟捕获事件，不使用麦克风，不修改用户录音；实际创建和更新 ActivityKit 活动，并检查以下内容：

1. 外部音频中断后，未获恢复许可时卡片保持中断状态。
2. 恢复失败不显示正在录音；成功恢复与手动暂停对应真实状态。
3. 注入 journal 写入失败后，卡片仍显示中断。
4. 快速更新以最后状态为准；结束后卡片移除。

报告位于 Dev 沙盒 `Documents/recording-activity-regression.json`。本机证据目录：`build/recording-activity-fix/`，包含 `build.log`、`source-audit.json`、`assembly-audit.json`、`signature.log`、`install-diagnostic.json`、`launch-diagnostic.json`、`regression.json`（通过）与 `regression-first.json`（首次即时读取误报）。

交互复测步骤：开始录音后锁屏，播放其他 App 音频，确认卡片和灵动岛显示中断；停止其他音频并恢复录音，确认捕获恢复成功后显示正在录音。用户已确认修复后无问题。
