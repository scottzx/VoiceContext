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

私有入口：[当前 Mac 的 DSH 服务](https://scott-mac.tailfb4720.ts.net:3080)。只在 Tailnet 内开放；DSH 继续要求自己的原生授权。（2026-10-27 起由 8451 统一到 3080）

- 当前 Serve：`3080` → `http://127.0.0.1:3080`（曾用独立 `8451`，已废弃）。未覆盖 443 现有配置，没有启用 Funnel。
- 适配源码：`tools/integration/dsh_tailnet_trust.mjs`；当前 profile 使用其独立副本 `local/yima-tailnet-trust.mjs`。只将上述精确 authority 加入安装版 Connection 的 trustedHosts，不替换认证或放开通配。
- 当前主机既有的 LAN 管理适配已启用 remote authorities；新主机应优先在 DSH 启动时通过公开的 `--trusted-host <Tailnet域名:端口>` 配置，并使用私有 Serve，不依赖本机的其他私密配置。
- 回退时仅关闭 `tailscale serve --https=3080 off`，移除 profile 的 `yima-tailnet-trust` 独立条目；不整体恢复旧 profile 备份，以免覆盖其他并行工作。

## 待真机验收

本轮未创建、启动或运行任何 iOS Simulator，也未运行真机 App。取得用户明确授权后，验证手机 Tailscale 连通、配置/切换、真实文本收发/停止、审批问答、普通模型/ACP 设置、分页、前后台恢复、动态字体和 VoiceOver。

附件与远程文件管理不在首版范围；安装版没有公开 session/delete RPC，因此不提供假删除。API v2 Peer cookie 不是跨进程永久凭据，服务重启且启动 token 改变时需更新连接令牌。

PM 本地 daemon 未启动，仓库设计与任务表已记录；未编造看板编号、里程碑或发布日期。

## 远程安装排查与修正（2026-10-22）

用户自行打开 Dev 后，关于页仍为 `1.0 (7)`、构建于 `2026-10-20 13:19:03`。手机已完整取得两次新 IPA，但没有完成覆盖安装；聊天页因此仍是旧标题，来源入口不要求先登录、配置模型或连接 Tailscale。

旧 IPA 的 ZIP 内夹带 14 个 `._*` AppleDouble 附属文件。使用普通 ZIP 解包并恢复 Unix 权限后，`codesign --verify --deep --strict` 报 `file added` / `a sealed resource is missing or invalid`；仅删除这些附属文件、不重新签名，校验立即通过。之前用 `ditto` 解包会自动还原这类元数据，掩盖最终 ZIP 的问题。此类资源签名故障也见 Apple [TN2250](https://developer.apple.com/library/archive/technotes/tn2250/_index.html)。

`package_ipa.py` 现禁止复制与打包资源叉/扩展属性，拒绝 AppleDouble，并对成品普通解包后再次验签，通过后才原子替换。`python3 tools/integration/test_package_ipa.py` 的 10 项宿主检查通过，包含真实签名 fixture 的旧逻辑失败/修复后通过回归；现有签名 Dev App 的完整临时打包也通过，未保留临时 `.app` 或 IPA。

已通过通用 iOS 目标归档与 Xcode `debugging` 自动签名导出生成替换包，保留 Dev 身份、构建号 `8` 和 Development iCloud 环境。新包不含 AppleDouble，普通 ZIP 解包后的完整签名检查通过，五个描述文件均覆盖既有 iPhone 15 Pro。未修改聊天页面代码，也未启动手机 App 或模拟器。

固定产物为 `build/distribution/development/public/app.ipa`，大小 `103,992,136` 字节，SHA-256 `b57fb54f055c057cb5449ecc6d870fb334b46466218b2d47c4d771c634223038`。`8454` 安装页和旧 `8453` 入口均已指向此修正版；清单与 IPA URL 使用新的 revision，完整 HTTPS 下载的 SHA-256 一致，保留其他 Serve 路由且未开启 Funnel。旧包服务已停止，旧 IPA 已移除，仅保留日志与故障证据。

复现记录：`build/distribution/yima-dev-dsh-build8-20261022/appledouble-audit/`；归档：`build/archives/VoiceContextAgentDev-DSH-build8.xcarchive`；导出、签名与网络交付记录：`build/distribution/development/`。手机覆盖安装和 DSH 交互仍待用户反馈，不把本机校验或完整下载记为设备安装完成。

### 按用户要求重新发布 2.0（9）

用户仍反馈手机是旧版本，明确要求清除此前分发并将新版本改为 `2.0`。已通过统一版本文件及生成器同步主 App、四个扩展和 VoiceRecording 为 `2.0 (9)`，清理固定构建目录的编译输出后，使用 `build_device.sh development --signed` 重新构建并通过装配审计，再由修正后的打包器生成唯一的 `development/public/app.ipa`。保留 Dev 身份和设备数据，未卸载或启动手机 App。

旧 `8453` / `8454` 分发入口、对应后台服务和全部公开安装文件已清除；诊断记录、归档及依赖缓存保留。新入口为 `https://scott-mac.tailfb4720.ts.net:8456/`，安装页仅提供「安装 2.0」按钮，清单指向带 `version=2.0-9` 的新包。其他服务与 Tailnet 路由未改动，未启用 Funnel。

2.0 安装包为 `104,070,248` 字节，SHA-256 `989e6b101b192f1aab5a5809f52a4c1b4a3c7d5e647216cab49c02de82ddec28`。成品普通解包后的签名检查、10 项宿主回归、安装页/清单版本、HTTPS 完整下载 SHA-256 和 Range 均通过。交付记录在 `build/distribution/development/2.0-9/`；手机端安装仍待用户通过「关于」中的 `2.0 (9)` 确认。

## 点击会话闪退排查（2026-10-23）

通过 USB / CoreDevice 只读连接到既有 iPhone 15 Pro，实际读取已安装的 `Yima Dev / YiJie.speech-note.dev / 2.0 (9)`。从 `systemCrashLogs` 取回 10 月 22 日 22:31–22:32 的四份 `VoiceContextAgent` 崩溃报告，未启动或操作手机 App。

四份报告的崩溃主线程均为相同的 219 帧：`EXC_BAD_ACCESS / KERN_PROTECTION_FAILURE`，地址位于 stack guard；`swift_getTypeByMangledName` / `decodeMangledType` / `decodeGenericArgs` 重复递归，随后进入 `AIChatView.inputBar` 的类型实例化。应用镜像 UUID 与本地 2.0 (9) 的 `VoiceContextAgent.debug.dylib` 一致，已保存匹配的 dSYM；此处不是根据源码风险推测的 diffable 重复 ID 异常。

对现场调用点的反汇编和 type reference 展开显示，运行时正在解析输入框末端 `simultaneousGesture` 的整条类型链，其中含 28 个 `ModifiedContent` 节点。将原内层输入框内容及语音观察者原文移入 `inputComposerContent: AnyView`，在这条链中间建立类型擦除边界；后续的 overlay、背景、尺寸、geometry 和滑动手势仍保留原顺序。内联还原检查与独立审查确认，原有状态、布局及回调内容没有变化。

`test_dsh_remote_chat.sh` 全部离线检查通过；`build_device.sh development` 的通用 iOS 目标编译成功，`verify_fusion` 的产品身份、容器及设备产物检查通过，原 448 个 Phone 编译输入保留。另通过源码内联还原检查和独立 diff 审查，确认新增边界之外没有改动输入框原有内容。

修复后真实二进制的调用点及 type reference 对照确认，原链已分为内容段的 12 个节点和后半段的 16 个节点；后半段以单个 `AnyView` 为基底，不再展开附件与订阅类型。对照记录为 `build/dsh-crash-20261023/after-metadata-comparison.md`，这是类型边界的静态验证，不是手机运行结果。

崩溃原件、读取回执、匹配 dSYM、符号化摘要及类型展开证据保存在 `build/dsh-crash-20261023/`。编译和离线检查仅验证源码及装配，不能代替真机复测；本轮尚未覆盖安装或运行修复版，也未订阅真实会话或启动任何 iOS Simulator。

### 用户授权后的安装与真机复测（2026-10-23）

用户明确授权安装修复版并打开 DSH 会话。通过 `build_device.sh development --signed` 签名构建，主 App 与四个扩展的签名检查通过，五个描述文件均覆盖既有手机；保持 `YiJie.speech-note.dev / 2.0 (9)` 同版本覆盖安装，没有卸载或清除数据。CoreDevice 安装回执及应用信息回读成功，安装目录已更新；修复二进制 UUID 为 `ACA21CE7-1159-32F5-B4BA-64422781C534`，匹配 dSYM 已保存。没有将同版本重装表述为版本号升级，也未更新既有 OTA 安装页的 IPA。

初次启动后，已保存的 Mac DSH 地址报 DNS 失败；Mac 服务可达，手机 Tailnet 状态为离线。用户连接手机 Tailscale 后，真实远程列表恢复。经用户在手机批准本次临时调试配对，使用列表行的 accessibility 激活打开既有 DSH 会话，未伪造本地会话或发送新消息。

| 场景 | 观察结果 |
| --- | --- |
| 首次点击远程会话 | 历史正文与原生输入框显示，约 95 秒后仍能读取截图；进程 PID 17134 保持存活 |
| 主动重新启动后再次点击 | 新进程 PID 17164 打开会话，约 37 秒后历史正文、远程状态和输入框仍可见，加载卡已消失 |
| 系统崩溃记录对照 | 测试前后均为 16 份匹配记录，新增 0 份；主动重启与异常退出分别记录 |

这两轮真实进入测试没有复现原来的点击闪退，不代表所有历史会话或其他远程操作均已验收。原日志捕获开关为关闭，测试没有改变该设置。没有发送、审批、取消或删除远程任务；已撤销本次客户端的临时配对凭据、删除本地凭据并关闭本轮 USB 端口转发，保留 App 和 Tailscale 供用户继续使用。

证据包括 `install-receipt.json`、`installed-app.json`、`runtime-verification.json`、两轮截图/界面树、前后系统崩溃清单及两版匹配 dSYM，均位于 `build/dsh-crash-20261023/`。未创建或运行 iOS Simulator。

## 原生呈现适配修复（2026-10-23）

用户要求远程 DSH 与本机会话保持一致，修复后覆盖安装到手机验证。继续沿用现有 `AIChatView`、消息列表、Markdown 渲染器、工具胶囊和全局主题/字号，未引入另一套聊天样式。

- 保留服务器文字、思考和工具的原始交错顺序，按明确轮次合并连续助手步骤；用户回复、新轮次和未知轮次分别处理。
- 历史与已完成正文调用本机 Markdown 缓存方法；正在生成的末尾正文维持流式处理。相同正文从生成中转为完成时也会完成渲染。
- 文件、浏览器、图片、记忆及已知任务工具复用对应原生图标和标题，保留原始工具名及输入；只读详情将输入折叠、结果独立显示，JSON 和 Markdown 可读。远程操作不能撤销手机记忆、打开手机路径或跳转手机子任务。
- 远程状态/分页/审批控制区按实际需要显示，并计入消息列表及浮动按钮的底部留白；保留输入框的 `AnyView` 防栈溢出边界。
- 服务端重复标识按日志位置隔离，不丢弃不同正文；重放去重、分页补入用户边界、未知工具分隔同轮及重连时维持展示身份。

`test_dsh_remote_chat.sh` 全套宿主检查通过；扩展的 driver 回归能在旧实现上捕捉拆消息问题，在新实现上通过。新增边界用例单独复跑通过。四个新文案已补中英文。`build_device.sh development --signed`、设备产物/容器检查及严格签名校验通过，五个描述文件覆盖手机；主镜像 UUID 为 `36B08F9C-66CD-3B11-A7CE-1BD42C23813A`，匹配 dSYM 已保存。

CoreDevice 同版本覆盖安装和应用信息回读成功，保持 Dev 身份及原数据。安装/签名/离线检查记录在 `build/dsh-ui-parity-20261023/`；真机呈现结果另记，不由构建通过推断。

### 真机反馈：连续思考分块

用户进入远程会话后确认正文正常，但连续出现多个「深度思考」胶囊。界面树同样记录到连续小块；同轮消息已经合并，缺口是不同 reasoning part 仍各建一个原生 block。

展示层现只合并同一助手组内相邻的思考片段，遇正文、工具、用户或轮次边界结束；每次从完整快照重算，保留段落和已有展开状态，不重复累加。分页前插通过成员别名复用已有块。流式转历史可能压缩片段索引，因此所有输出块统一防止重复 UUID，正文或工具不能直接改写共享思考块。协议内容及远程执行均不改变。

合并回归在旧逐片段实现上失败，新实现通过；流式历史重排回归在移除别名隔离保护的临时副本上失败，最终实现通过。`test_dsh_remote_chat.sh` 全套宿主检查、签名设备目标构建、严格签名校验及五个设备描述文件检查通过。连续思考修复镜像 UUID 为 `29AC7FA2-FDE9-3A86-AA10-21BF7CA7B91E`，匹配 dSYM 已保存。CoreDevice 安装回执及应用信息回读确认同版本 `2.0 (9)` 覆盖成功，随后用户在手机上确认连续思考已修复。证据为同目录下 `thinking-*` 记录。

用户解锁并使用后明确反馈连续思考已修复。随后在「生成英文版项目说明」会话的 README.md 工具结果页发现新呈现缺口：`<path>/<type>/<content>` 封装和 `N: ` 行号未经拆解进入 Markdown，标题、代码及段落挤成普通文本。现场截图和界面树保存为 `tool-result-user-report*`。

工具结果现识别完整的已知文件封装，只移除协议行号，保留正文缩进与空行；Markdown 文件复用原生文档渲染，源码和终端结果按原始换行等宽显示。EOF/截断说明独立保留，未知或不完整封装按原文显示；复制仍保留原始结果。没有复用会读取手机磁盘的本机工具执行页。

新增文件封装回归覆盖 CRLF、Unicode、读取偏移、空行与缩进、内嵌标签、EOF/截断、未知格式，以及 `<content>` 后直接跟编号或先换行两种形式；完整 DSH 宿主套件通过。构建因另一项同目录构建占用数据库失败一次，待其结束后签名设备构建通过。严格验签、五个设备描述文件及匹配 dSYM 检查通过；工具结果修复镜像 UUID 为 `8D963244-7414-31D0-B5D5-5FAB5AE98706`。CoreDevice 覆盖安装及应用信息回读成功；安装后启动被系统以 Locked 拒绝，等待解锁后复核工具页。证据为同目录下 `tool-result-*` 记录，不把锁屏拒绝当成应用崩溃。

用户随后确认 README 已修复，继续指出 `pwd` 输入/输出仍未适配。`pwd-user-report*` 现场显示纯路径完整，但使用通用输入折叠及较大字号文本，缺少本机终端的命令头与紧凑层级。现从 `ToolLiveSheet` 提取纯展示的 `ShellToolTextContent`，本机与远程共用命令、输出、13pt 等宽字体、分块、ANSI/控制字符和超长行处理；本机原有资源栏、分页及外层布局保持原处，远程不创建本机工具或资源监控。真实 `command` 参数直接显示为 `$ command`，原 JSON 仍可展开并复制。

UI 审核同时发现本机旧终端详情的固定绿色配色与现行 `DESIGN.md` 的语义色约束冲突；这次远程采用已有黑白语义色及 grouped 表面，不复制固定绿字。DSH Web 启动检查确认本机 `3080` 与 Tailnet `3080`（原 `8451`，2026-10-27 统一）均返回正常认证拒绝，HTTPS 验证通过；未认证不冒称会话接口或手机链路已验收，未改变服务。证据为 `dsh-web-status.json`。
