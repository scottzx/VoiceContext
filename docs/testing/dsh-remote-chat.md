# DSH 远程聊天实施检查

日期：2026-10-22。设计依据：[DSH 远程聊天](../design/dsh-remote-chat.md)。

## 已实现

- 聊天首页原生 header Menu 切换本机与已保存的 DSH 服务；iCloud 状态入口独立保留。
- 服务原生增删改、连接测试、地址校验、Keychain token/cookie；删除只移除本机配置。
- 独立远程列表、服务器全文搜索、新建与详情；沿用消息列表、输入、主题、字号、语言与无障碍控制。
- 服务器历史、流式消息、思考和多工具状态、停止、远程审批/问答、普通模型及 ACP 设置、分页与重连。
- 服务/会话/草稿身份隔离、草稿到真实会话别名、origin/凭据变化时缓存失效。
- 远程不启动本机 kernel、Agent、工具、文件挂载或 ChatStore/iCloud 写入；远程工具只读展示，阻断本地文件资源解析。

## 自动检查

`tools/integration/test_dsh_remote_chat.sh` 在 macOS 宿主运行，已通过：

1. 安装版 wire/RPC、cookie 兑换、请求相关 ID、发送不盲重试、流与历史去重/缺口、工具结果、投影顺序、审批过期。
2. 服务配置持久化、地址与凭据校验、故障一致性、坏数据保护、origin 匹配和删除选择恢复。
3. 生产 driver 的稳定消息/block 身份、断线与离开、发送结果不确定、草稿/多工具与本地资源隔离。
4. 实际缓存方法的来源/会话隔离、origin 失效、草稿别名和不取消远程任务。
5. Tailnet 适配的精确域名、拒绝通配与路径、卸载清理和既有授权保留。

开发版和生产版静态装配检查均通过，保留原 448 个 Phone 编译输入。新增 Swift 文件通过生成器加入融合工程。中英文文案目录追加 98 个键，保留原有键与译文。

整工程设备目标编译已通过：`VoiceContextAgentDev / Debug-Dev / generic/platform=iOS / CODE_SIGNING_ALLOWED=NO`。编译过程中修正 SwiftUI 长表达式推断超时，按原顺序拆分页面呈现和生命周期；另修正工具 sheet 的 weak VM 可选解包。没有签名、安装或运行 iOS App。

收尾补充了原生远程页面的 app 字号设置，并保留复制选中文字到输入框的纯前端动作。最终增量编译再次通过；开发版产物身份/容器检查通过，原 448 个 Phone 编译输入和全部 9 个新增 DSH Swift 编译单元均在工程中。

## 真实服务只读验证

- 当前安装 DSH `0.2.1-rc.2` 的 loopback 与 Tailnet 原生登录、轻量 RPC 和会话列表均通过。
- 实际生产 `DSHClient` 经 Tailnet 执行 `connect() → listSessions()`，返回 137 个摘要，实测约 0.226 秒。输出仅数量/状态，不打印会话正文或凭据，不创建或发送消息。
- URLSession 真实 WebSocket 升级与 mux 通路通过；声明 `interactions=none` 时 `$events` 按安装版规则返回 `gateway/interactions-forbidden`，验证权限拒绝路径后立即关闭。
- 未将这个拒绝结果记作 ready/历史流验收。安装版 follow 冷会话会调用 `resumeObserved` 恢复 Agent，因此本轮未对真实历史做 follow，也未发送或取消真实会话。ready、历史 opening、工具确认和完整问答由 schema/离线测试检查，端到端仍待授权验收。

## 网络交付

私有入口：[当前 Mac 的 DSH 服务](https://scott-mac.tailfb4720.ts.net:8451)。只在 Tailnet 内开放；DSH 继续要求自己的原生授权。

- 新增独立 Serve `8451` → `http://127.0.0.1:3080`，未覆盖 443、8443–8450 的现有配置，没有启用 Funnel。
- 适配源码：`tools/integration/dsh_tailnet_trust.mjs`；当前 profile 使用其独立副本 `local/yima-tailnet-trust.mjs`。只将上述精确 authority 加入安装版 Connection 的 trustedHosts，不替换认证或放开通配。
- 当前主机既有的 LAN 管理适配已启用 remote authorities；新主机应优先在 DSH 启动时通过公开的 `--trusted-host <Tailnet域名:端口>` 配置，并使用私有 Serve，不依赖本机的其他私密配置。
- 回退时仅关闭 `tailscale serve --https=8451 off`，移除 profile 的 `yima-tailnet-trust` 独立条目；不整体恢复旧 profile 备份，以免覆盖其他并行工作。

## 待真机验收

本轮未创建、启动或运行任何 iOS Simulator，也未运行真机 App。取得用户明确授权后，验证手机 Tailscale 连通、配置/切换、真实文本收发/停止、审批问答、普通模型/ACP 设置、分页、前后台恢复、动态字体和 VoiceOver。

附件与远程文件管理不在首版范围；安装版没有公开 session/delete RPC，因此不提供假删除。API v2 Peer cookie 不是跨进程永久凭据，服务重启且启动 token 改变时需更新连接令牌。

PM 本地 daemon 未启动，仓库设计与任务表已记录；未编造看板编号、里程碑或发布日期。
