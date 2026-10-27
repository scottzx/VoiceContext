# DSH 远程聊天接入

## 确认与目标

2026-10-22，用户确认在聊天首页 header 切换本机/DSH 会话来源，随后授权实施首版。使用 `voice_type` 产品仓库，不维护第二产品仓库。

首版包含服务管理与授权、会话列表及搜索、新建、历史、文本收发、流式回复、停止、工具审批/提问、重连恢复和支持的模型设置。远程服务执行 Agent 和工具，手机复用聊天详情，不启动本机 Agent 替代执行。

不做公网穿透、VPN 管理、附件上传、远程文件管理、历史迁移、跨来源合并和远程历史的 iCloud 同步。未接入动作隐藏或明确禁用。

## UI/UX 风格确认

状态：已确认复用现有聊天页与 `DESIGN.md`，适用 Typography、Color、Layout、Settings、Accessibility 章节及 `docs/design/interface-language.md`。

方向为安静、原生、紧凑、内容优先；系统字体、动态字号、黑白导航、平面列表、44 pt 点击目标，继承深色模式与 Reduce Motion。不增加新 Tab、WebView 聊天壳或装饰卡片。本轮是现有页面局部扩展，独立低/高保真原型不适用。

## 页面与流程

1. 聊天列表 header 的原生 Menu 提供本机、各服务和管理服务；本机 iCloud 同步入口保留为独立按钮。
2. 来源选择持久保存；切换后搜索、新建、列表与打开会话均指向当前来源。列表显示连接中、无会话、失败、重试状态。
3. 管理服务使用原生 List/Form：名称、Tailscale HTTP/HTTPS origin、SecureField 启动 token、连接测试、编辑和删除。删除只移除本机连接，不删除远程会话。
4. 远程详情复用 `AIChatView`、消息列表与输入栏，显示来源与真实状态。未映射的本地终端/文件/附件/编辑历史/Skills/MCP 动作不得调用本机功能。
5. 返回列表、切换来源和关闭订阅不停止远程任务；只有用户停止才发远程取消。
6. 断线保留输入，重连补历史和运行状态并按序号去重；不自动重发未明确确认接收的消息。
7. 工具审批显示服务器原文与选项，必须明确允许/拒绝；远程问题提供回答入口。过期与失败状态真实显示，不能静默授权。

## 架构、数据与设置

- `ContentView` 承接来源 Menu、列表分派和路由。
- 路由、缓存和草稿以 `(service UUID, session ID)` 隔离；现有 `remoteDeviceId` 仍仅表示 iCloud 只读会话。
- `AIChatViewModel` 保留展示状态，DSH driver 在 load/send/cancel 边界分派，更新 `ChatMessage` / `AssistantBlock`。
- 远程历史以 DSH 为真源，不写手机 `ChatStore` 或 CloudKit，不启动手机 kernel/mount/Agent loop。
- 主题、字号、语言和文本呈现共享；模型、推理级别、ACP 参数、工作目录、权限和工具来自远程能力。DSH 文件不能按本地 `minis://` 路径解析。

### 原生呈现对齐（2026-10-23，用户授权修复并真机安装测试）

- 以服务器有序内容块保留文字、思考与工具的交错顺序；明确属于同一轮的连续助手步骤合并到一个原生消息，用户回复与新轮次分别拆开。未知轮次不猜测合并。
- 历史和已完成文字使用本机的 Markdown 完成缓存；正在生成的末尾文字保留流式处理。分页、重连及实时落盘尽量保留现有消息/块身份，重复服务端标识不导致 UIKit 标识冲突或丢弃不同日志正文。
- 已知工具复用本机的文件、浏览器、图片、记忆与任务图标，保留原始工具名称、输入和结果。详情只读，输入默认折叠、结果沿用本机富文本；不能打开手机路径、撤销手机记忆或跳转手机上的子任务。
- 远程控制区按连接、执行、分页和待处理交互显示，正常空闲时收起；实际高度与输入栏一起参与消息区和浮动按钮的留白计算。沿用现有颜色、字号和无障碍目标，不新增聊天皮肤。

## 协议基线

核对当前安装版 DSH `0.2.1-rc.2`，构建 `332895e0f7c9d4dbfb29729f5eb367fa263ff986` 的 generated schema 与编译产物。本机 DSH 源码提交不同，不替代安装版契约。

- `GET /connect?token=…&interactions=answer` 兑换与 authority 绑定的 cookie，后续 HTTP/WS 共用；不能假设 Bearer 登录。
- API v2 cookie 属于进程内 Peer；每条 WS 兑换独立 Peer，关闭连接后旧 cookie 可失效。Keychain 不代表 cookie 能跨服务重启使用；启动 token 改变后需要更新连接凭据。
- 一元调用 `POST /api/session/<method>` 使用 DSH RPC envelope；`/api/remote.mux` WebSocket 承载连接事件与 `follow` 流。
- `list/create/follow/page/prompt/cancel` 构成最小链。`prompt` 只确认接收入队，正文来自 follow；发送有稳定 requestId，不盲重发。
- follow opening 提供历史窗口和序号，page 向前翻页；重连按连接代次和历史窗口重新对齐。
- 普通模型使用 `modelCatalog/selectModel`；ACP 会话参数按 `/api/1agents-acp/session` 的能力描述处理，不能当成本地模型配置。

## 网络与隐私

当前 DSH 仅监听 `127.0.0.1:3080`。使用独立 Tailnet HTTPS 入口转发，保留现有 Serve 路由，并满足 DSH Host/Origin 信任与授权。无需手机嵌入 VPN SDK 或部署公网穿透。

实施时本机服务已由另一项工作增加 LAN 监听，予以保留。早期私有 HTTPS 曾用 `8451` → `127.0.0.1:3080`；**2026-10-27 起统一为 `https://scott-mac.tailfb4720.ts.net:3080` → `127.0.0.1:3080`**（tailnet only，无 Funnel），`yima-tailnet-trust` authority / `TAILNET_AUTHORITY` 同步改为 `scott-mac.tailfb4720.ts.net:3080`。不修改 DSH 认证或原有 443 Serve 路由。

元数据只存 UUID、名称、origin；token/cookie 存 Keychain，日志与错误不得泄露。更换 origin 不复用旧凭据；删除配置清理对应凭据。连接失败不得回退本机发送。

## 任务与验收

| 交付 | 执行人 | 依赖 | 验收 |
|---|---|---|---|
| 设计与接口基线 | Codex | 用户确认 | 本文可恢复范围、UI、协议与验证边界 |
| 服务管理与凭据 | Codex | 设计 | URL/名称校验、持久化、Keychain、编辑/删除与失败一致性 |
| 协议与事件投影 | Codex | 接口基线 | HTTP/WS 契约、历史/增量、发送/取消、审批和重连离线测试通过 |
| header、列表和详情 | Codex | 以上接口 | 来源隔离，复用界面，无本地执行/持久化副作用 |
| 编译与验收记录 | Codex | 实现 | 静态装配、设备目标编译和宿主测试，记录未验真机项 |

无障碍走查覆盖动态字号、VoiceOver、键盘焦点、对比度和 Reduce Motion。无购买、新系统权限或服务器删除流程。

## 验证与追踪边界

禁止模拟器。首版实施时仅授权静态检查、宿主协议/存储逻辑检查及 `generic/platform=iOS` 编译；用户已于 2026-10-23 明确授权修复版覆盖安装和打开真实 DSH 会话测试。真机结果及仍未验收的远程操作分别记录在测试文档，不能由编译通过推断。

启动时 PM CLI 的本地 daemon `127.0.0.1:38080` 不可达，无法读取既有蓝图或同步需求/任务。上表为待同步记录，不编造条目编号、里程碑或日期，也不重建已有蓝图。检查结果记录在 `docs/testing/dsh-remote-chat.md`。
