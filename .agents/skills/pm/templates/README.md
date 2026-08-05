# 项目看板条目模板

项目设计文档和每种看板条目（bug / requirement / task / discussion）的骨架。先写设计依据，再更新功能蓝图和创建任务。

| 类型 | 文件 | 何时用 |
|---|---|---|
| 设计文档 | [design-doc.md](./design-doc.md) | 大需求/Epic/用户流程/跨模块功能在功能蓝图和任务之前使用 |
| bug | [bug.md](./bug.md) | 已观察到的错误现象，需要修 |
| requirement | [requirement.md](./requirement.md) | 有明确交付物的目标，先对齐并关联设计依据 |
| task | [task.md](./task.md) | 从已确认功能点拆出的最小可执行单元 |
| discussion | [discussion.md](./discussion.md) | 方向 / 概念性记录，可能不转化成交付物 |

## 用法

1. 确认 requirement/bug；大需求先用 `design-doc.md` 写入仓库。
2. 依据设计文档增量更新功能蓝图。
3. 打开对应条目模板，复制空骨架并填写。
4. 把填好的整段作为 `--description '...'`（或 `--json` 里的 `description`）传给 `project-items create`。
5. 可执行 task 还必须填 `--acceptance`，否则会被判为 `not_ready` 不进调度队列。
6. 任务清单和依赖成形后再编排里程碑与日期。

## 共用原则（与 SKILL.md 一致）

- **不要凭空补用户没给的细节**。不确定就问，或在 description 里明确标 `TBD`。
- **标题**：bug / requirement 一句话说症状或目标，**不写方案**。
- **验收标准必须可检验**——执行 agent 完成后能逐条对照。
- **归口**：可执行 task 在 description 里写 `#需求编号`（或用 `--json links`）追溯到源 requirement / bug。
- **设计依据**：大功能在顶层 requirement/模块关联主文档，子功能默认继承；仅在有独立设计时给子功能增加文档。
- **风格门禁**：用户可见功能需要原型时，先讨论并确认 UI/UX 风格，把结论写入设计文档，再启动低保真或高保真原型。
- **设计任务检查**：用户可见大功能必须显式判断产品设计、信息架构、低保真原型、UI/UX、无障碍和设计走查是否需要任务。
