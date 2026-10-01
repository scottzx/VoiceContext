# 待办日历首页：实现与验收

日期：2026-10-02。依据：用户指定的 `http://127.0.0.1:4175/todo-overview-prototype/` 与 [`../design/todo-overview.md`](../design/todo-overview.md)。

## 实现范围

- 待办 Tab 为月／周日历和当天事项两个组件：星期一开始、今天细圈、中性选择、独立红色待办点与绿色日程点、右上“今天”、无翻页按钮。翻月保留所选日，翻周移动七天；返回管理页恢复首页状态。
- 待办行及编辑器共用既有完成／恢复、短暂完成反馈、写入失败、只读、删除确认、复杂时间保护。新增预填所选日期，日期可关闭，通知独立。
- 系统日程在独立 actor 中查询，仅传不可变快照至 UI，展示时间、来源、地点、备注；页面不创建或编辑日程，也不自动上传给 Agent。
- 全部页按逾期／今天／未来／未安排组织，不带日历。两组来源以系统标识多选并持久化；支持全部取消、同名列表通过账户区分、显示已完成。已有单列表偏好迁入管理页，首页不受管理页筛选影响。
- 新来源默认选中；刷新保留用户取消的来源；仅成功读取时剔除失效标识并说明。权限撤销时保留偏好，显示来源访问状态，避免将暂不可读的列表当作已删除。
- 日程先加载未来一年并显示截止范围，可逐年加载更多；长范围按年查询避免 EventKit 四年谓词截断。历史日期通过首页查看；过期日程不加入“逾期”待办组。
- 独立用户触发权限请求、读取状态与重试；前台、EventKit 变更、日界与时区变化刷新。日历权限说明覆盖中英文，沿用现有开发版身份和全局录音条。
- 支持动态字体、深浅色、VoiceOver 日期数量／未读取说明、自定义月／周翻页、日期选择替代入口、Reduce Motion。

## 非 iOS 运行检查

纯 Foundation 回归可在 macOS 执行，不运行 iOS App：

```sh
xcrun swiftc -module-cache-path /tmp/yima-swift-module-cache Integration/App/TaskCalendarRules.swift tools/integration/test_task_calendar.swift -o /tmp/yima-test-task-calendar
/tmp/yima-test-task-calendar
xcrun swiftc -module-cache-path /tmp/yima-swift-module-cache Integration/App/ReminderDateEditing.swift tools/integration/test_reminder_dates.swift -o /tmp/yima-test-reminder-dates
/tmp/yima-test-reminder-dates
```

两组通过，覆盖本地日分组、星期一网格、月／周翻页、午夜、全天排他结束、跨日、23小时夏令时日；偏好序列化、空选择、取消来源不重选、来源删除、新来源与两类标识隔离；既有日期字段、原时区、未编辑时间与复杂数据保留规则。

最终 unsigned iPhoneOS 编译通过（`BUILD SUCCEEDED`），日志：本机 `build/todo-overview-final-build.log`；目标为 `VoiceContextAgentDev`、`Debug-Dev`、`generic/platform=iOS`，无安装或启动。融合产物审计通过：4643 个来源文件存在、448 个 Phone 编译输入保留、身份和容器隔离、设备产物、新增日历权限及三种语言的权限说明均通过；证据：本机 `build/todo-overview-assembly-audit.json`。编译提取的 106 个页面词条已与融合词表核对（纯数字无需译文），英文译文及中文源键可用；Python 语法检查与 `git diff --check` 通过。新增三个 Swift 文件及改动的待办页面无编译警告。

## 真机阶段记录（2026-10-02）

用户明确要求“真机已解锁，测试一下”，本轮获得运行授权。使用 `scottxz`（iPhone 15 Pro、iOS 27.0），完成设备目标签名编译、主应用及四扩展签名／设备授权检查、融合装配审计，增量安装 `YiJie.speech-note.dev` 并成功启动（PID 8146）。安装前后正式版 `YiJie.speech-note` 的安装记录一致；开发版进程在后续查询中仍为同一 PID。

通过 iPhone 镜像实际进入待办 Tab，浅色首页、真实提醒事项红点、今天选择、待办数量与日历未读取状态可见；点击月份旁箭头，月历成功收起为所选日所在的一周，页面内容保留，日历独立授权入口可见。此时手机被直接使用，镜像提示“iPhone 使用中”并断开；重连显示必须锁屏，已提示用户锁屏后继续。未确认日历授权结果，未创建、完成或删除任何系统事项；其余交互仍待继续测试，不将安装／启动计作全部功能验收。

本机证据：`build/todo-overview-signed-build.log`、`build/todo-overview-signing-audit.json`、`build/todo-overview-signed-assembly-audit.json`、`build/todo-overview-install.json`、`build/todo-overview-launch.json`、`build/todo-overview-processes.json`、`build/todo-overview-apps-before.json`、`build/todo-overview-apps-after.json`。界面证据为本会话的 iPhone 镜像截图；未使用模拟器。

## 待继续的真机验收

本轮已获真机运行授权。以下使用专用系统测试列表继续，未完成项不标记通过：

1. 月／周横向手势、纵向滚动、短距离／纵向／取消手势不翻页、翻页不误选日期；今天与展开、不同月份选择、管理页返回位置。
2. 仅待办／仅日程／两者同日点、未安排待办不打点、已完成待办不打点；时间排序、午夜跨日与跨夏令时、全天结束边界。
3. 分别首次授权、拒绝、受限、仅写日历权限升级、设置撤销和恢复、读取／更新失败；另一来源仍可用，无可写提醒事项列表可解释。
4. 同名来源、多选、全部取消、重开保留、外部删除来源后提示、未勾选列表不被刷新自动恢复。筛选不修改系统数据，首页不受影响。
5. 新增日期预填及关闭、不自动增加通知；编辑复杂时间仍保留；完成反馈／恢复、只读、删除确认与外部删除一致；系统提醒事项和 App 为同一数据。
6. 日程详情及未来范围、加载更多、跨年重复事件无重复；历史日程通过首页可回看，事件不显示完成圆圈。
7. 中英文、深浅色、Dynamic Type 至 accessibility3、44pt 点击区、VoiceOver 月／周自定义操作与未读取状态、Reduce Motion；横竖屏适配。
8. 录音中跨 Tab、权限 Sheet、提醒事项编辑，检查全局停止可达与实际音频连续性。

EventKit 的日程查询接口不提供一般读取失败的错误回调；本实现显示可观察的权限请求错误和访问失效，不能据静态编译确认底层系统日历服务故障的全部表现。

## 日历授权后不展示：回归检查（2026-10-02）

用户反馈申请日历权限后没有展示数据。修复将权限请求改为主线程触发，独立维护 `requestingAccess`，不再让初始数据加载阻止授权按钮；授权成功后丢弃旧读取会话，首次读取时才创建 `EKEventStore`。授权弹窗期间的前台／系统变更刷新不会提前结束请求；撤销访问会清除快照与覆盖范围。

以下 macOS 模型测试注入虚拟读取器和权限状态，不读取本机日历、不申请本机权限、不运行 iOS App：

```sh
xcrun swiftc -module-cache-path /tmp/yima-swift-module-cache Integration/App/SystemCalendarModel.swift tools/integration/test_calendar_access.swift -o /tmp/yima-test-calendar-access
/tmp/yima-test-calendar-access
```

已通过：初始加载时申请权限、重复点击仅申请一次、授权弹窗期间刷新、允许后重新读取并发布来源和日程、撤销／拒绝清空状态、请求失败结束进度并显示错误。模型测试不作为真实权限回调的替代证据。

修复版设备目标签名编译成功，应用及四扩展签名／设备授权检查通过，已增量安装至同一真机的 `YiJie.speech-note.dev`。命令行启动被锁屏策略拒绝，改由已连接的 iPhone 镜像搜索并打开 `Yima Dev`，没有修改系统权限。启动后直接识别已有日历授权：月／周视图显示绿色日程点，2026-10-02 当天显示 2 项真实全天日程；全部页展示今天与未来日程，筛选面板展示来自 iCloud、Outlook、订阅日历等的来源。返回首页和应用返回前台后，当天 2 项日程仍显示。未创建、编辑或删除系统日程。

本机证据：`build/todo-calendar-access-fix-build.log`（`BUILD SUCCEEDED`）、`build/todo-calendar-access-fix-signing-audit.json`、`build/todo-calendar-access-fix-install.json`、`build/todo-calendar-access-fix-launch.json`（记录锁屏启动拒绝，不能作成功启动证据）、`build/todo-calendar-access-fix-processes.json`。成功启动和数据展示证据为本会话的 iPhone 镜像截图。此次真机验证的是已有授权后的加载恢复；未重置隐私权限来重新触发首次授权弹窗，首次授权、拒绝和撤销的真机组合仍未完整验收。
