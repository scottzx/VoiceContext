# #66 相册视频抽音轨 — 真机冒烟（摘要）

完整勾选表见 [`import-audio-device-smoke.md`](./import-audio-device-smoke.md) **§E**。

## 必须覆盖

1. 导入菜单：文件 + 照片与视频  
2. 相册视频抽音轨 → `ImportedAudioAsset` / ProcessingRange  
3. **无产品时长上限**；≥30 分钟样例至少完成导入入队  
4. 进度/排队可见；不阻塞麦克风录音  
5. 语音备忘录经 Files 中转（无 Share Extension）  
6. 失败可读；无半残 Recording；列表「导入」标识；播放连续  

## 自动化

`ImportAudioTranscriptionTests`：`videoAudioExtraction…`、`videoWithoutAudioTrack…`、`processingRangePlannerHandlesThirtyMinute…`、`unsupportedImageExtension…`。

## 签名约束

不要为跑通冒烟重加 `CODE_SIGN_ENTITLEMENTS` 或写死具体 iCloud container。
