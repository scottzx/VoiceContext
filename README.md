# 一芥伙伴 · Yima

**手机上的个人助手 · Personal Agent.** 一芥伙伴（Yima）将聊天、录音与会议、系统提醒事项，以及 shell、Skills、浏览器能力整合在一个 iOS App 中，帮助你记录、理解和处理日常事务。

当前工程将源自 [OpenMinis](https://github.com/OpenMinis/OpenMinis)、经 `1agents_phone` 定制的完整 iOS Agent 平台接入原 `voice_type` 录音系统，保留正式产品身份和原有录音数据路径。

录音与本地转写沿用原实现；聊天、在线模型、浏览器及部分工具按用户配置访问网络。融合版不再适用“整个 App 100% 离线”的描述。

产品名称和兼容性约定见[产品身份](docs/design/product-identity.md)。仓库目录、工程入口与历史数据路径保留原命名，正式和开发 Bundle ID 均不改变。

## 产品入口

| Tab | 职责 |
|---|---|
| 聊天 | 模型对话、Agent 运行、shell、Skills、浏览器和原生工具 |
| 会议 | 原听记录音、转写、文稿、详情与智能体产物 |
| 待办事项 | 展示和管理 iPhone 系统提醒事项 |
| 拓展 | 模型与服务、Skills、终端、浏览器、我的与设置 |

录音实例由 App 层持有，跨 Tab 共用。音频协调优先保障录音；会议文稿可以作为 Agent 上下文，生成结果与原文分开保存。

## 融合后的项目结构

```text
voice_type/
├── VoiceContextAgent.xcworkspace/       # 融合版统一 Xcode 入口
├── Integration/                        # 两套系统之间的接入代码与配置
│   ├── App/                            # 四 Tab、音频桥、会议上下文、产物、提醒事项
│   ├── Recording/                      # 对外提供 VoiceRecordingWorkspace
│   ├── Shared/                         # 主 App / Agent 扩展共享的构建身份
│   ├── Resources/                      # 生成的合并图标、颜色与本地化资源
│   ├── Info.plist                      # 生成的正式 App 配置
│   ├── VoiceContextAgent.entitlements  # 生成的正式权限配置
│   ├── *Dev.Info.plist                 # 生成的开发 App / 扩展配置
│   ├── *Dev.entitlements               # 生成的独立开发容器与权限
│   └── README.md                       # 装配、依赖、数据契约和验证记录
├── Vendor/Phone/                       # 导入的 Phone iOS 源码快照及本地适配
│   ├── src/ios/
│   │   ├── MinisApp.swift              # 融合 App 启动骨架
│   │   ├── Agent/                      # 聊天、会话、shell、Skills、同步等
│   │   ├── AgentKit/                   # AgentKit 相关能力
│   │   ├── Providers/                  # 模型、认证与语音服务
│   │   ├── Views/                      # Phone 原有界面
│   │   ├── Shared/                     # 配置、共享容器、路由等公共实现
│   │   ├── iSH/                        # iOS shell 运行时接入
│   │   ├── NativeOffloads/             # 原生 Apple 工具桥接
│   │   ├── WebApp/                     # WebApp 与浏览器相关实现
│   │   ├── HardwareBridge/            # 硬件桥接能力
│   │   ├── ShareExtension/             # 分享扩展
│   │   ├── AgentWidget/                # Agent Widget / Live Activity
│   │   ├── FileProvider/               # 系统文件提供者
│   │   ├── Minis.xcodeproj/            # Phone 原工程，作为生成器输入
│   │   └── VoiceContextAgent.xcodeproj/ # 生成的融合工程与共享 Schemes
│   ├── src/apple/                      # Apple 平台共用领域代码
│   ├── src/shared/                     # 跨平台共用规则等
│   ├── deps/                           # iSH 等依赖源码；本机原生缓存另行忽略
│   ├── scripts/                        # Phone 构建与资源工具
│   └── SOURCE_SNAPSHOT.json            # 导入来源与子模块版本
├── speech_note/                        # 原听记代码，继续作为录音业务来源
│   ├── speech_note.xcodeproj/          # 可独立构建的原录音工程
│   ├── speech_note/
│   │   ├── App/                        # 原 App 入口、路由、本地化
│   │   ├── Features/                   # 录音、转写、说话人、文档、购买等
│   │   ├── Infrastructure/             # 推理运行时、权限、归档工具
│   │   ├── ModelResources/             # 离线模型资源
│   │   └── Frameworks/                 # 本机原生推理依赖
│   ├── RecordWidget/                   # 原录音 Widget，仍嵌入融合 App
│   ├── LiveActivityShared/             # 录音实时活动共享类型
│   ├── speech_noteTests/               # 原录音单元测试
│   ├── speech_noteUITests/             # 原 UI 测试与截图流程
│   └── Supporting/                     # 生成的公开 Skill / 模板包
├── tools/
│   ├── integration/                    # 导入、工程生成、设备编译与装配审计
│   ├── VoiceContext/                   # 公开 Skill / 模板源文件
│   ├── sync_version.py                 # VERSION → 原工程及发布文档
│   └── release.sh                      # 原独立录音工程发布脚本
├── docs/                               # 产品、设计、架构、测试和发布文档
├── build/                              # 本机构建产物、依赖缓存、设备证据；不提交
├── memory/                             # 本地工程排障记录
├── transcribe.cpp                      # 本地外部依赖符号链接
├── VERSION                             # 版本号与 Build 号来源
├── DESIGN.md                           # UI 设计规范
└── AGENTS.md                           # 仓库工作和真机验证约定
```

`voice_type` 是唯一产品开发与交付仓库。`Vendor/Phone` 保存 Agent 源码与本地适配，后续直接从 [OpenMinis/OpenMinis](https://github.com/OpenMinis/OpenMinis) 获取上游更新。`1agents_phone` 仅保留为首次导入的历史来源，不再单独维护，也不是构建依赖。当前已合入 OpenMinis v1.13 的 iOS 及共用依赖更新，保留本地定制。具体流程见[上游维护约定](docs/architecture/openminis-upstream.md)，本轮适配与验证见[v1.13 合并记录](docs/architecture/openminis-v1.13-integration.md)。

## 两套代码如何组成一个 App

- **App 骨架与 Agent 能力**：使用 `Vendor/Phone`，主 Swift 模块仍叫 `Minis`；启动后展示 `Integration/App/VoiceContextRootView.swift`。
- **录音业务**：融合工程将原 `speech_note` 源码及 `Integration/Recording` 编译成 `VoiceRecording.framework`。原 App 的 `@main` 在融合构建中停用，原独立工程仍保留。
- **接入层**：`Integration/App` 负责四 Tab、音频协调、会议文稿快照、产物预览和系统提醒事项；`Integration/Shared` 保证 App 与扩展使用对应版本的容器身份。
- **扩展**：主 App 嵌入原 RecordWidget，以及 Phone 的分享、Agent Widget 和 FileProvider 三个扩展。

模块边界、新增文件规则和生成文件约定见[工程目录说明](docs/architecture/project-structure.md)。

## 开发与构建

已验证环境为 Xcode 26.6，iOS deployment target 为 18.0；真机启动验证使用 iPhone 15 Pro / iOS 27.0。最低版本和其他机型兼容性仍需单独验证。

1. 按[融合工程说明](Integration/README.md#构建与依赖)准备原录音模型、原生推理框架、Phone 原生依赖和 SwiftPM 依赖。部分大文件与本机缓存不随 Git 提交。
2. 生成融合工程并打开统一入口：

   ```bash
   python3 tools/integration/generate_project.py
   open VoiceContextAgent.xcworkspace
   ```

3. 日常开发选择 `VoiceContextAgentDev` 和物理 iPhone。项目禁止模拟器；代理启动 App 或执行真机测试需获得用户明确授权。

| 用途 | Scheme | 配置 | Bundle ID |
|---|---|---|---|
| 开发版「一芥伙伴 Dev / Yima Dev」 | `VoiceContextAgentDev` | `Debug-Dev` | `YiJie.speech-note.dev` |
| 正式身份调试 / 覆盖升级验证 | `VoiceContextAgent` | `Debug` | `YiJie.speech-note` |
| TestFlight / App Store 归档 | `VoiceContextAgent` | `Release` | `YiJie.speech-note` |

开发版与正式版的 App 沙箱、iCloud、App Group 和 Keychain 分离；系统提醒事项仍是同一份系统数据。TestFlight 使用正式身份，安装时会替换同身份的已安装应用。

仅做未签名 iPhone 目标编译及装配检查：

```bash
# 默认开发身份，不安装、不运行
bash tools/integration/build_device.sh

# 正式身份的 Debug 编译检查；不是发行归档
bash tools/integration/build_device.sh production
```

版本更新链路为 `VERSION → tools/sync_version.py → 原 speech_note 工程 → tools/integration/generate_project.py → 融合工程`。旧的 `tools/release.sh` 仍归档原独立录音应用；融合版的 Release 归档和上传按[开发版、TestFlight 与正式版切换](docs/release/build-variants-and-release.md)执行。

## 验证状态与文档

已完成首轮融合、真机签名编译、正式身份覆盖安装、开发版并存安装和启动检查。完整 Agent 能力、长录音、升级恢复、设计与无障碍仍待逐项验收；尚未完成融合版的发行归档与 TestFlight / App Store 发布。编译通过与启动成功不代表完整功能验收通过。

- [文档索引](docs/README.md)
- [个人智能体融合设计](docs/design/personal-agent-integration.md)
- [融合工程说明与验证记录](Integration/README.md)
- [工程目录说明](docs/architecture/project-structure.md)
- [开发版、TestFlight 与正式版切换](docs/release/build-variants-and-release.md)
- [设计规范](DESIGN.md)

## 源码来源与许可证

原录音项目保留根目录 [MIT LICENSE](LICENSE)。导入的 Phone 源码保留其 [GPLv3 LICENSE](Vendor/Phone/LICENSE) 及[第三方许可证说明](Vendor/Phone/THIRD_PARTY_LICENSES.md)，原 MIT 声明不替代导入代码的许可证。具体来源版本见 [SOURCE_SNAPSHOT.json](Vendor/Phone/SOURCE_SNAPSHOT.json)。
