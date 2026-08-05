# 0.1.0 录音核心验证报告（含离线复核与人工确认）

- 设备：iPhone 15 Pro (iPhone16,1)
- 系统：iOS 26.5（注：发布基线为 iOS 18，本机结果按设计文档要求记为补充证据）
- App 构建：speech_note 1.0 (1)，0.1.0 录音核心验证界面
- 取证会话：2026-08-05 18:42–19:27 本地时间；报告生成 20:14
- 人工确认：product owner，2026-08-05

## 检查项结果

| 检查项 | 结果 | 记录 |
| --- | --- | --- |
| 完整性诊断（边界/缺口/可读性） | passed | Recording 919C8EB7；离线 afinfo 复核格式与时长一致 |
| 30 分钟后台连续（锁屏/切换 App） | passed | 会话期间经历锁屏与 App 切换（人工确认） |
| 锁屏/控制中心停止入口 | pending | 本次停止（19:27:04）在 App 内执行；锁屏入口未验证 |
| 2 小时连续分片（约 5 分钟边界） | pending | 本次最长 31 分钟；5 分钟边界机制已由 7 chunk 与单测验证 |
| 电话/Siri 中断产生 gap 且 UI 显示 interrupted | passed | 微信来电（19:15:45）与手机来电（19:16:34），见证据 B |
| 蓝牙断连/路由变化产生显式 gap | skipped | 本轮跳过；routeChange 点状 gap 机制已由附带事件与单证实 |
| 强制终止后恢复 interrupted 且重复恢复幂等 | passed | 见证据 C（含二次恢复 0 条的人工确认） |
| 低存储拒绝新录音（请求麦克风前，原因明确） | 单测覆盖 | coordinatorDoesNotTouchMicrophoneBeforeExplicitStartOrWhenStorageIsLow 通过 |
| chunk 边界汇总 | passed | 7 chunk，0→29,846,311 样本，连续无重叠 |

## 证据 A：31 分钟连续会话（Recording 919C8EB7）

- 墙钟：18:55:51 开始 → 19:27:04 停止（31.2 分钟），期间经历锁屏与 App 切换（人工确认），采集未中断。
- 7 个 chunk：6×300.0s + 65.4s，边界恰为 4,800,000 样本整数倍；`afinfo` 逐个确认 AAC-LC、1 ch、16000 Hz，时长与样本计数一致（合计 1865.4s），逐个可播放。
- 墙钟 1873s 与音频 1865.4s 的 ~7.6s 差值 = 两次来电中断窗口（19:15:45→19:15:49、19:16:34→19:16:37），均有 gap 记录，偏差可解释。
- 状态链：recording → interrupted → recording → interrupted → recording → stopping → processing → complete，journal 与 UI 展示状态同源。
- SQLite 复核：user_version=1，journal_events=64 与 JSONL 行数一致，recordings=6 / chunks=11 / gaps=20，complete×5 + interrupted×1。

## 证据 B：系统中断 gap（真实来电）

- 19:15:45 微信来电、19:16:34 手机来电，各产生一条 `systemInterruption` gap（样本位置 19,106,995 / 19,820,716），UI 状态机进入 interrupted；中断结束后按系统 shouldResume 自动恢复采集，gap 同步关闭。
- gap 在样本空间宽度为 0（中断期间不写样本），墙钟缺口由 gap 起止时间表达；chunk 样本边界保持连续，诊断无未解释缺口。中断前后的音频未被伪装成无 gap 连续。

## 证据 C：强制终止恢复与幂等（Recording E79EA0F3 + 二次验证）

- 18:46:16 开始，录音中被强制终止；18:55:46 重启后恢复服务将其置为 interrupted 并打开 `recoveredAfterTermination` gap，已关闭 chunk 可见（本例强杀早于首个 5 分钟边界，故无已关闭 chunk；进行中的 m4a 留在磁盘但按设计不入 journal）。
- 恢复未自动开启麦克风；下一条 Recording（919C8EB7）由用户显式开始。
- 二次恢复（人工确认）：再次运行恢复显示 0 条，journal 无重复 recovery 事件，Recording/chunk/gap 无重复创建。

## 观察项（非阻塞）

1. 每次 session 启动/停止各伴随一个 sample 0 / 末样本位置的 routeChange 点状 gap，来自 AVAudioSession 激活/去激活通知；诚实且无害，诊断不构成问题。
2. 暂停区间（见 Recording 9715B22A 的 paused↔recording 往返）不产生 gap 行；墙钟缺口可由 journal 状态迁移事件推导。若未来要求墙钟缺口全部由 gap 表达，需新增 pause gap reason。
3. iOS 26.5 结果不能替代 iOS 18 兼容性结论（发布基线）。

## 剩余待办（真机）

1. 锁屏/控制中心停止入口：录音中锁屏，确认系统是否展示停止入口；不展示则截图记录，转后续 UI 任务评估 Live Activity。
2. 蓝牙断连轮次：连接蓝牙耳机/音箱录音中断开，确认产生显式 route gap。
3. 2 小时连续分片：预期 24 个 5 分钟 chunk + 1 个尾段。

## 完整性诊断

- 未发现索引、样本边界或音频可读性问题。
