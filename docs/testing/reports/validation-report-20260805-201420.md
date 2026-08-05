# 0.1.0 录音核心验证报告

- 设备：iPhone iPhone16,1
- 系统：iOS 26.5
- App 构建：speech_note 1.0 (1)
- 开始：2026-08-05T12:14:20Z
- 完成：待完成

| 检查项 | 结果 | 记录 |
| --- | --- | --- |
| 完整性诊断（边界/缺口/可读性） | passed | Recording 919C8EB7 |
| 30 分钟后台连续（锁屏/切换 App） | pending |  |
| 锁屏/控制中心停止入口 | pending |  |
| 2 小时连续分片（约 5 分钟边界） | pending |  |
| 电话/Siri 中断产生 gap 且 UI 显示 interrupted | pending |  |
| 蓝牙断连/路由变化产生显式 gap | pending |  |
| 强制终止后恢复 interrupted 且重复恢复幂等 | pending |  |
| 低存储拒绝新录音（请求麦克风前，原因明确） | pending |  |
| chunk 边界汇总 | pending | 共 7 个 chunk，合计 1865.4s：
  0–4800000（300.0s，closed）
  4800000–9600000（300.0s，closed）
  9600000–14400000（300.0s，closed）
  14400000–19200000（300.0s，closed）
  19200000–24000000（300.0s，closed）
  24000000–28800000（300.0s，closed）
  28800000–29846311（65.4s，closed） |

## 完整性诊断

- 未发现索引、样本边界或音频可读性问题。