# 小蓝同学与 Yima：共用运行时、独立配置

本轮用户确认：两者共用 Agent 执行引擎，差异集中到配置和策略。复杂任务沿用 `spawn_subagent`，子任务完成通过 notice 二次唤醒父会话；此前的 Yima 主会话专线已撤销。

| 配置 | 小蓝同学 | Yima |
|---|---|---|
| 身份与人格 | `agent-xiaolan`、自己的 SOUL | 原 `agent-default` 与人格 |
| 入口 | 独立语音或会议语音 | 原聊天入口 |
| 工作策略 | 简短原生操作；复杂工作派子任务 | 保留用户已配置的工具策略与模型 |
| 交付 | 实际调用 `answer_user`；语音宿主管理播报 | 原有聊天交付 |
| notice | 主会话可交付时二次唤醒，只答复已验证结果 | 保留原通知机制 |
| 记忆 | 默认关闭，保留已有个人设置 | 保留现有配置与数据 |

架构及验收详见[运行时策略设计](../architecture/agent-runtime-policies.md)。应用配置在 `Integration/App/VoiceAgentConfiguration.swift`，角色提示词在 `VoiceAgentPrompt.swift`；核心只读取 `AgentRuntimePolicy`，不根据产品身份或语音 source 字面值决定权限。普通身份、模型服务、工具循环、存储、压缩及 notice 总线共用。

小蓝与 Yima 的会话历史各自保留；新的执行子会话归属真实父会话和发起 Agent，不创建 Yima 主会话来承接小蓝任务。工具启动只表示开始，小蓝先通过 `answer_user` 交付启动状态并结束当前轮；真实终态由原子 notice 队列去重、预约宿主交付后唤醒原会话。

公开任务答复、追问和失败说明均须实际调用 `answer_user`，普通文字或写出工具名不算交付。只有一次补交付机会，只使用已验证结果，不重做业务。即时“我在”“收到，开始处理”继续由本地宿主处理。

子任务不能控制语音或页面。图片/HTML 按调用方要求保留本子会话 workspace/attachments 的预览副本，提供真实 task/source_session_id 和路径；标准文件交付仍用既有 task delivery 目录。主会话后续明确请求展示时校验直属子会话和当前页面版本；notice 回合不抢页、不重做操作。

保留拓展入口、单色胶囊与两字状态，不新增小蓝前端。PM 服务不可用情况及具体构建、安装、真机验收边界见[交付记录](../testing/xiaolan-voice-delivery.md)。
