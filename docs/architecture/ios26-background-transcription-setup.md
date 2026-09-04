# iOS 26 后台转写签名与验证

## 当前行为

- iOS 18–25 只在前台提交推理；进入后台后当前 job 回到 `pending`，回到 App 自动续跑。
- iOS 26+ 仅在用户开启设置，并且通过停止录音、导入或手动重试启动转写时，提交 `BGContinuedProcessingTaskRequest`。
- SenseVoice 路径使用 GPU/Metal，因此 request 明确要求 `.gpu`。不使用 default resource 冒充“可在后台完成 Metal ASR”。
- 设备不支持 GPU 后台资源时不提交 request；签名或系统拒绝时提交失败。两者都会保留队列，进入后台时回到 `pending`，前台续跑。
- expiration 或用户在系统进度 UI 取消后，scheduler 先使 execution token 失效，再将 job 回到 `pending`；迟到结果不能提交。

## 签名状态与发布前前置

仓库的 `speech_note.entitlements` 已声明：

```xml
<key>com.apple.developer.background-tasks.continued-processing.gpu</key>
<true/>
```

主 App target 已设置 `CODE_SIGN_ENTITLEMENTS = speech_note/speech_note.entitlements`。Apple Developer 团队 `3HJ3R6SXAL` 中的显式 App ID `YiJie.speech_note` 已开启 **Background GPU Access** 和 iCloud；Xcode 已生成专用开发描述文件。

2026-08-24 已在 iPhone 15 Pro / iOS 26.5 上完成 Debug 真机构建、签名校验和启动。最终 App 签名中已确认包含：

- `com.apple.developer.background-tasks.continued-processing.gpu = true`
- `com.apple.developer.icloud-container-identifiers = iCloud.YiJie.speech-note`
- `com.apple.developer.icloud-services = CloudDocuments`

准备 TestFlight / App Store 构建前：

1. 为 TestFlight / App Store 的 distribution 签名生成同样包含 Background GPU Access 和 iCloud 的 profile。
2. 构建后使用以下命令确认 entitlement 确实签入 App：

   ```sh
   codesign -d --entitlements :- /path/to/speech_note.app
   ```

3. 在 iOS 26 真机上用真实待处理录音验证系统进度、锁屏、取消、expiration 和发热降级。这些系统调度行为不能由签名成功替代。

`Info.plist` 中的 `BGTaskSchedulerPermittedIdentifiers` 已配置为通配前缀 `YiJie.speech_note.transcription.*`。每次用户发起的转写使用带 UUID 后缀的唯一任务 ID，避免与旧 request 冲突。
