# VoiceContext 文档

本目录保存 VoiceContext 的产品、设计和工程文档。文档中的产品边界以 PRD 为准，PM 看板用于跟踪需求、任务、依赖和里程碑。

## 产品文档

- [VoiceContext v1 产品需求文档（PRD）](./PRD.md)：v1 产品边界、用户流程、信息架构、页面清单、状态矩阵、功能需求、验收标准，以及原型任务 `#39` / `#40` 的输入与交付定义。
- [消费级对标增补 PRD](./PRD-consumer-parity-addendum.md)：相对离线转写竞品的增补需求（执行基线；含首次打开起 72 小时试用、文件夹 iCloud、视频无上限、v1 不做 Share Extension）。
- [v1 信息架构与低保真原型](./design/v1/information-architecture.md)：已通过的统一 Recording 页面树、流程、状态矩阵与可点击低保真交付。
- [v1 设计系统与高保真原型](./design/v1/design-system.md)：个人语言记事本、多人对话与会议共用的视觉 token、语音胶囊、音频播放器、SwiftUI 标注、无障碍要求与高保真原型入口。
- [0.1.0 录音核心设计](./architecture/recording-core.md)：可靠采集、60 秒 AudioChunk、journal、恢复、gap 与音频保留边界。
- [0.2.0 分钟级增量转写设计](./architecture/incremental-transcription.md)：closed chunk 立即入队、跨 chunk carry/source ranges、前后台门禁、录音与处理解耦及幂等恢复。
- [generate-meeting-minutes Codex Skill](./features/generate-meeting-minutes-skill.md)：公开 VoiceContext Skill/模板导出、Mac Codex 安装与端到端验证（`#33`）。
- [听记 1.0 App Store 发布设计与提交清单](./release/1.0-app-store-submission.md)：首发永久解锁定价、商店元数据、隐私合规、审核说明与手动发布验收。

## 工程导航

- [工程目录说明](./architecture/project-structure.md)：源码模块职责、测试分组、资源路径与新增文件规则。

## 文档约定

- PRD 是产品范围和交互输入的仓库内单一事实源。
- PM 需求与任务使用 `#编号` 标识；修改产品范围时，需要同时更新 PRD 和对应 PM 条目。
- 原型、UI/UX 和设计走查产物后续统一放在 `docs/design/v1/`。
- 工程实现与 PRD 不一致时，不允许静默选择其中一方；先记录差异，再由产品负责人确认。

## PM 任务读取注意

`project-items list` 是摘要视图，会省略任务说明和验收标准。执行任务前必须使用详情和关系图命令：

```bash
/Users/scott/Documents/01-开发项目/1agents/1agents_app/build/1agents project-items get '#39' --json
/Users/scott/Documents/01-开发项目/1agents/1agents_app/build/1agents project-items graph '#39' --json
/Users/scott/Documents/01-开发项目/1agents/1agents_app/build/1agents project-items get '#40' --json
/Users/scott/Documents/01-开发项目/1agents/1agents_app/build/1agents project-items graph '#40' --json
```

对 `#39`，详情应包含 `docs/PRD.md` 输入、四类仓库内设计产物和独立验收标准；关系图应显示 `#39 → #38`，以及后续 `#40 → #39`。对 `#40`，以 `docs/design/v1/design-system.md` 和 `docs/design/v1/prototype/` 为高保真交付事实，并确认后续 `#41` 仍依赖 `#40`。
