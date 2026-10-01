# 一芥伙伴最小迭代：检查记录与真机步骤

日期：2026-10-01。范围来源：`docs/discussion/yima-minimum-iteration.md`；局部设计：[`yima-minimum-reminders.md`](../design/yima-minimum-reminders.md)。

## 已完成的非运行验证

- `bash tools/integration/build_device.sh development`：`VoiceContextAgentDev` / `Debug-Dev`，`generic/platform=iOS`，unsigned iphoneos 编译通过。日志：本机 `build/yima-minimum-build.log`。没有安装或启动应用。
- 同一脚本的装配审计通过：4643 个来源文件存在、448 个 Phone 编译输入保留、身份与容器隔离通过、设备产物及 framework 加载路径通过。
- macOS 纯 Foundation 日期回归检查通过：原值完全保留、日期修改保持时分秒和原时区、时间修改不改日期、显式移除时间、新增全天/带时间事项、无 calendar 的工具日期组件可显示。命令：

  ```sh
  xcrun swiftc Integration/App/ReminderDateEditing.swift tools/integration/test_reminder_dates.swift -o build/test-reminder-dates
  build/test-reminder-dates
  ```

- 待办页面的 40 个、四 Tab 宿主页的 14 个直接文案键已核对生成词表的英文和简体中文；动态完成/恢复及编辑/新增文案另由融合词表提供。检查 `git diff --check` 通过。
- 静态接线：录音详情无可读文字时显示原有处理状态；有文字时发通知，宿主复用聊天默认模型组的现有路由检查（包含启用、可见和凭据状态）、刷新快照并创建待发送草稿。配置 Sheet 切换语言后按原偏好恢复机制重开。草稿要求检查文稿状态、先给建议、明确确认后创建、结果不明先查询，以及写入 Generated 并保留来源。新装内置 Skill 与每次刷新 README 都包含此约定；已存在的用户 Skill 不覆盖。
- 待办仅使用 EventKit，不调用音频会话接口。四 Tab 仍共用宿主持有的录音服务。这个静态结论不能代替录音连续性验证。

## 后续真机安装

2026-10-01 用户明确授权在已连接的真机上安装。完成开发版签名编译、主应用与四个扩展的设备授权/App Group 签名检查、融合产物审计；增量安装到 `scottxz`（iPhone 15 Pro，iOS 27.0）成功。安装后设备查询确认 `YiJie.speech-note.dev` / Yima Dev 已更新；正式 `YiJie.speech-note` 的安装 URL、名称及版本与安装前一致。本次没有卸载、清除数据或启动应用，不将安装成功计作运行验收。

本机证据：`build/yima-minimum-signed-build.log`、`build/yima-minimum-signing-audit.json`、`build/yima-minimum-signed-assembly-audit.json`、`build/yima-minimum-install.json`、`build/yima-minimum-deployment.json`。

## 待执行的真机验收

本轮已获安装授权，没有明确的真机运行授权，以下均未执行。禁止模拟器。运行前使用系统提醒事项中的专用 `Yima 演示` 列表，只操作专用测试数据；不要将开发版数据隔离误认为系统提醒事项隔离。

1. 配置已有模型服务及聊天模型；未配置时，从录音详情尝试整理，应看到配置入口，取消后录音和回听可继续。
2. 录制明确包含一条行动建议的短文稿，等待文字生成。处理中/失败/无文稿时核对实际说明；部分已有文字应仅整理已就绪内容。
3. 从「交给智能体」进入草稿，确认没有自动发送。发送后查看建议与 `Generated/<recordingID>/` 产物，核对 recordingID、revision 和引用位置。
4. 用户明确确认创建一条无日期待办到 `Yima 演示`；工具结果应提供系统 ID、标题和列表，且不猜日期。若结果不明，先查询该列表，不直接重试创建。
5. 切至待办页刷新并筛选该列表，再到系统提醒事项核对同一条数据。圆圈与滑动完成均成功后反馈；显示已完成后恢复。重复点击不能重复提交。
6. 手动新增：筛选可写列表为新增默认；全部列表使用系统默认可写列表。取消编辑后系统中没有新增事项，保存后核对标题、备注、列表。
7. 分别测试无日期、仅日期、日期+时间、独立定时提醒。只有日期不能视为已配置 EKAlarm；定时提醒需在系统通知允许时核对真实到达，不以保存成功替代通知验收。
8. 在系统中准备带时区/秒值/重复/相对提醒/位置/多提醒的事项；只改标题或备注，检查未编辑属性不变。复杂组合的时间控件应禁用并解释去系统调整。普通事项只改日期应保留原时间和时区。
9. 只读共享列表可查看，完成/删除不可操作、保存不可用。无可写列表时说明原因且新增不可用。编辑期间外部删除、移动列表或变为只读后保存应据实失败，不重新创建。
10. 删除滑动不允许全滑直接移除；取消确认保留事项，确认后系统和 App 都移除。长按菜单和 VoiceOver 操作能完成等效行为。
11. 初次申请、拒绝、系统受限、设置中撤销、读取失败、保存失败各自有明确状态；不能把读取失败显示为空列表。外部编辑/删除及回到前台会刷新。
12. 录音期间切换四 Tab、打开模型配置、编辑/完成待办；检查采集和音频片段连续。系统中断按既有状态机记录，不宣称零中断。
13. 中英文、深浅色、Dynamic Type 至 accessibility3、VoiceOver、Reduce Motion 检查本路径。点击目标至少 44 pt，完成状态有文本，Reduce Motion 不做列表位置动画。

真机结果另补日期、设备、测试事项 ID、成功/失败证据；本轮不关闭原融合需求剩余验收，不宣称工具真实执行、通知到达、视觉或音频连续性通过。
