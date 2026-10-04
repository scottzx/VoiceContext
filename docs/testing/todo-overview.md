# 待办日历首页：实现与验收

日期：2026-10-02。依据：用户指定的 `http://127.0.0.1:4175/todo-overview-prototype/` 与 [`../design/todo-overview.md`](../design/todo-overview.md)。

## 实现范围

- 待办 Tab 为月／周日历和当天事项两个组件：星期一开始、今天细圈、中性选择、独立红色待办点与绿色日程点、右上“今天”、无翻页按钮。翻月保留所选日，翻周移动七天；返回管理页恢复首页状态。
- 待办行及编辑器共用既有完成／恢复、短暂完成反馈、写入失败、只读、删除确认、复杂时间保护。新增预填所选日期，日期可关闭，通知独立。
- 系统日程在独立 actor 中查询，仅传不可变快照至 UI，展示时间、来源、地点、备注；页面不创建或编辑日程，也不自动上传给 Agent。
- 提醒首页与全部页共用已持久化的来源和完成状态筛选，首页也有筛选入口；当天列表、数量、逾期摘要、日历红绿点同步筛选。全部页按有事项的日期组织，不带日历；无日期待办保留“未安排”。点击日期标题，用原生年月日滚轮跳转，仅提供当前筛选下有待办或日程的日期。两组来源以系统标识多选并持久化；支持全部取消、同名列表通过账户区分、显示已完成，沿用已有偏好键与单列表迁移。
- 新来源默认选中；刷新保留用户取消的来源；仅成功读取时剔除失效标识并说明。权限撤销时保留偏好，显示来源访问状态，避免将暂不可读的列表当作已删除。
- 日程先加载未来一年并显示截止范围，可逐年加载更多；长范围按年查询避免 EventKit 四年谓词截断。更早的历史日期通过首页查看，全部页沿用从今天开始的日程查询范围。
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
4. 同名来源、多选、全部取消、重开保留、外部删除来源后提示、未勾选列表不被刷新自动恢复。两页互相同步筛选，首页列表、数量和日历点一起变化；筛选不修改系统数据。
5. 新增日期预填及关闭、不自动增加通知；编辑复杂时间仍保留；完成反馈／恢复、只读、删除确认与外部删除一致；系统提醒事项和 App 为同一数据。
6. 日程详情及未来范围、加载更多、跨年重复事件无重复；历史日程通过首页可回看，事件不显示完成圆圈。
7. 中英文、深浅色、Dynamic Type 至 accessibility3、44pt 点击区、VoiceOver 月／周自定义操作与未读取状态、Reduce Motion；横竖屏适配。
8. 录音中跨 Tab、权限 Sheet、提醒事项编辑，检查全局停止可达与实际音频连续性。

EventKit 的日程查询接口不提供一般读取失败的错误回调；本实现显示可观察的权限请求错误和访问失效，不能据静态编译确认底层系统日历服务故障的全部表现。

## 事项样式与日期跳转（2026-10-04）

按用户补充要求，日程和待办共用标题、来源、次级信息的排版：44pt 前导区域、4pt 信息间距、相同列表边距与上下留白。待办保留完成／恢复和编辑，日程用日历图标区分类型，并展示全天或起止时间以及已有地点；日程保持只读。没有新增装饰性卡片容器。

全部事项由四个宽泛分组改为逐日分组，空日期不生成标题。日期跳转沿用会议列表的原生 Sheet 与年月日滚轮；可用日期来自当前已读取、已选择来源及完成状态筛选后的事项。更换年月时同步纠正不可用的日，取消不跳转，确认在 Sheet 关闭后定位；减少动态效果时取消定位动画。未安排待办仍可读，只有未安排事项时不生成日期入口。日程继续沿用当前已读取的未来范围和“加载更多日程”，没有扩展系统查询范围。

Foundation 主机回归通过，新增同日本地时间去重、稀疏日期、闰年切换、跨月和来源过滤后失效日期、空选项、跨午夜与夏令时日选项检查；原有来源偏好和日历规则回归同时通过。完整 iPhoneOS 开发版签名构建通过，真机 UI 交互尚未执行。

更新版已增量安装到 scottxz 的 Yima Dev 1.0 (7)，安装后回读 URL 与回执一致，正式版安装元信息前后相同；没有启动 App、执行真机交互、修改系统事项或清除应用数据。本机忽略证据：build/recording-ai-actions-device/task-style-date-final-build.log、task-style-date-assembly.json、task-style-date-install.json、task-style-date-deployment.json。页面新增词条的英文、简体与繁体译文已加入 Fusion 源词表及本机合并词表，提取的页面词条英文覆盖检查通过。

本次真机验收步骤（待测）：

2026-10-04 补充日程行优化：日期与时间段／全天放在同一行，左日期、右时间；地点改为纯文字。跨日结束时间保留结束日期。完整开发版签名构建与产物审计通过，更新安装到同一 iPhone 的 Yima Dev，回读与安装回执一致，正式版安装元信息未变；未启动 App 或代测界面。本机证据为 build/recording-ai-actions-device/event-metadata-row-build.log、event-metadata-row-assembly.json、event-metadata-row-install.json 与 event-metadata-row-deployment.json。

1. 在首页及全部页比较待办／定时日程／全天日程：标题和来源对齐，字号、留白一致；日程日期靠左、时间段或“全天”靠右放在同一行，地点直接显示名称，无地点图标。跨日日程的结束时间包含结束日期，长标题和地点可读；日程无完成按钮，点击可查看详情。
2. 在全部页点击一个日期标题，确认年月日只列有事项的日期；测试跨月、跨年、闰年，确认跳转到所选日期标题，取消保留原滚动位置。
3. 取消某个来源、隐藏已完成待办，再打开日期选择：仅依赖这些事项的日期消失；若当天仍有其他事项，则日期保留。全部来源取消时仍显示筛选提示。
4. 只有无日期待办时显示“未安排”；完全无事项时只有整页空状态，无空日期占位。加载更多日程后新增日期可选择；权限未读取／失败仍显示原状态，不作无事项结论。
5. 测试深浅色、大字号、VoiceOver 和减少动态效果；关闭日期 Sheet 后全部页主 Tab 仍隐藏，返回首页恢复，完成／编辑待办仍沿用原生系统数据。

## 提醒命名与全局筛选（2026-10-04）

底部 Tab 与首页标题改为“提醒”。首页新增原生筛选 Sheet，与全部页复用相同的来源选择和完成状态控件。继续使用 AppStorage 的 yima.tasks.reminderSources、yima.tasks.eventSources、yima.reminders.showCompleted 三个既有全局 UserDefaults 偏好键，选择即时保存；没有新建页面局部的筛选副本或覆盖旧选择。首页待办、日程、数量、逾期摘要与日历点共同读取已选择来源；完成状态筛选适用于两页待办列表，已完成待办仍不产生红点。

Foundation 主机回归通过，覆盖未选来源在显示已完成／完成反馈时仍隐藏、两页共用完成状态谓词，以及独立 UserDefaults 测试域的新实例回读两种来源、完成偏好和全部取消。测试域随后移除，没有访问真实系统事项；这不等同于 iPhone 杀进程后的交互验收。完整 iPhoneOS 开发版签名构建通过。

真机待测：在全部页取消某个日历和待办来源，返回首页确认事项、数量及红绿点同步；在首页筛选反向修改，再进入全部页确认勾选同步。分别切换显示已完成、取消全部来源、切换 Tab 和重开 App，确认保存的选择仍在；刷新不重新勾选已取消来源。

更新已增量安装至同一 iPhone 的 Yima Dev 1.0 (7)，安装后回读与回执一致，正式版安装元信息前后相同；未启动 App、代测界面或修改真实系统事项。证据：本机 build/recording-ai-actions-device/shared-reminder-filter-host.log、shared-reminder-filter-build.log、shared-reminder-filter-assembly.json、shared-reminder-filter-install.json 与 shared-reminder-filter-deployment.json。新增命名／筛选词条覆盖英文、简体与繁体，页面提取词条的英文覆盖检查通过。

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

## 2026-10-04：reset 到 d8344f2，仅接入 EventKitUI

撤回官方 UICalendarView 以及相关翻月性能试用，执行 git reset --hard d8344f2 后，仅重新接入原生日程详情／编辑及来源选择。TaskCalendarView.swift 与基线一致；月／周折叠、双标记、“今天”、既有日期手势、统一事项列表及持久筛选保持基线实现。当前日程详情不再采用此前的只读 SwiftUI 详情页。

EKEventViewController 按来源和具体发生时间重新查询所选日程，防止打开同系列的其他发生日期；允许系统编辑，订阅／只读限制及重复日程编辑范围交由系统。关闭后刷新首页、全部页及标记。EKCalendarChooser 分别支持日历和提醒事项列表的多选：完成保存全局偏好，取消或划掉不保存。权限撤销及事项失效显示不可用界面。

主机回归：保留基线日历／周历／筛选／日期跳转测试；新增发生标识区分和原生来源保存的空选择、新来源主动取消、失效来源及序列化检查。无需访问真实系统事项。iPhoneOS 构建与安装不替代真机交互验收，不使用模拟器。

真机待验收：

1. 自绘月历与周历切换、左右翻页、顶部“今天”、双标记和已保存筛选保持原体验。
2. 从首页和全部页分别打开日程，检查所选重复日程的发生日期；用专用测试日程验证编辑保存／取消、只读限制和系统重复范围选择，关闭后两页及标记更新。
3. 两页分别选择日历及待办来源，完成后同步，取消／划掉保持原值；全部取消、新出现来源主动取消后刷新、重开 App 都保留选择。
4. 权限撤销、外部删除、深浅色、大字号、VoiceOver 和录音过程中打开原生 Sheet；二级页面保持主 Tab 隐藏。

本轮 iPhoneOS 签名构建、两组主机回归及融合装配检查通过；中英／简繁查看编辑权限说明和新增界面词条覆盖检查通过。已安装并回读 scottxz 的 Yima Dev 1.0 (7)，回执路径一致，正式版安装元信息相同。没有启动 App、代为操作真实日程或使用模拟器。证据：本机 build/recording-ai-actions-device/eventkit-only-{build.log,rules-test.log,access-test.log,assembly.json,install.json,deployment.json}。HEAD 保持 d8344f2，EventKitUI 改动留在工作树供验收。

## 2026-10-04：待办卡片仅显示到期日期

首页与全部页共用的 SystemReminderRow 移除提醒日期／铃铛行，只展示到期日期及已设置的到期时间。没有到期日期时不显示日期，不使用提醒日期替代。静态核对确认 ReminderEditor 及提醒保存逻辑与 d8344f2 一致；iPhoneOS 开发版构建通过。此处仅改展示，没有改动实际系统通知设置。

真机待测：同时设置到期与提醒的待办，两页都只显示到期；只有提醒、没有到期的待办不显示日期。进入编辑页确认定时提醒仍可查看和调整。

已安装并回读 scottxz 的 Yima Dev 1.0 (7)，回执一致，正式版安装元信息相同；未代为启动 App。记录：本机 build/recording-ai-actions-device/reminder-due-only-{build.log,install.json,deployment.json}。
