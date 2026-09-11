# VoiceContext 🎙️

> **100% 离线、隐私优先的 iOS 个人语音记事本与会议转写上下文引擎**  
> *Privacy-First, On-Device Voice Context & Transcription for Apple Ecosystem.*

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: iOS 18+](https://img.shields.io/badge/Platform-iOS%2018%2B-orange.svg)](https://developer.apple.com/ios/)
[![Swift 5.10+](https://img.shields.io/badge/Swift-5.10%2B-brightgreen.svg)](https://swift.org)

---

## 🌟 核心特性 (Key Features)

- 🔒 **100% 本地离线与极致隐私 (100% On-Device & Private)**
  - 音频录制、语音活动检测 (VAD)、SenseVoice 语音识别与说话人聚类全在 iPhone 本地运行。
  - 零音频上传、无需登录账号、无需联网、无云端订阅依赖。

- ⚡ **分段流式转写 (Chunk-based Streaming Transcription)**
  - 采用无缝 60 秒绝对采样边界分块（AAC-LC 16kHz），录音过程中并发增量转写。
  - 告别长时间录音后漫长的等待，文稿几乎实时产生（延迟仅 0–60 秒）。

- 👥 **智能说话人分离 (Speaker Diarization & Voiceprints)**
  - 支持说话人聚类与声纹识别，无缝支持个人单人闪念速记、多人会议与访谈对话。

- 📑 **开放文档与 AI 工作流原生 (Open Formats & AI-Ready)**
  - 不做封闭数据孤岛，输出纯净的 **Markdown** 逐字稿与带有时间戳的 **JSON** 数据。
  - 一键导出 TXT / SRT 字幕，或直通桌面端 Codex / LLM（支持自定义会议纪要 Prompt / Codex Skill）。

- 📱 **原生 iOS 体验 (Native iOS Experience)**
  - 现代 SwiftUI 架构与流畅动效，支持桌面 Widget 锁屏/小组件一键开录。
  - 支持文件 App 与公开 `iCloud Drive/VoiceContext` 目录双向同步。

---

## 🏗️ 架构与技术栈 (Architecture & Tech Stack)

- **UI & 架构**：SwiftUI (iOS 18+), Swift Concurrency (`async/await`, `actor`)
- **音频引擎**：`AVAudioEngine`, `AVAudioFile` (AAC-LC 16 kHz 采样率)
- **ASR & AI 引擎**：
  - [SenseVoice](https://github.com/FunAudioLLM/SenseVoice) 本地轻量化多语言语音识别模型
  - [Sherpa-Onnx](https://github.com/k2-fsa/sherpa-onnx) / C/C++ 跨平台加速绑定
- **数据持久化**：本地文件系统沙盒 + 可选 iCloud Drive 文档镜像

---

## 🚀 快速上手与构建 (Getting Started)

### 环境要求 (Prerequisites)
- **Xcode**：16.0 及以上版本
- **系统要求**：macOS Sequoia / iOS 18.0+
- **推荐硬件**：iPhone 15 / iPhone 15 Pro 及以上（搭载 Apple Neural Engine 与 A16/A17/A18 芯片以获得最佳离线推理性能）

### 本地编译运行 (Build Steps)

1. **克隆仓库**：
   ```bash
   git clone https://github.com/<your-username>/VoiceContext.git
   cd VoiceContext
   ```

2. **打开 Xcode 工程**：
   ```bash
   open speech_note/speech_note.xcodeproj
   ```

3. **模型与依赖准备**：
   - 本项目依赖 SenseVoice 与相关推理模型文件，放置在 `speech_note/speech_note/ModelResources/` 目录中。
   - 依赖的 C/C++ 动态框架或静态库位于 `speech_note/speech_note/Frameworks/`（可通过相关脚本或 Release 下载）。

4. **运行与测试**：
   - 本项目禁止使用 iOS Simulator；经用户明确授权后，选择物理 iPhone，点击 **Run (⌘ + R)**。
   - 真机测试同样需要明确授权；未授权时仅执行静态检查和非运行时验证。

---

## 📂 项目结构 (Project Structure)

```text
VoiceContext/
├── speech_note/
│   ├── speech_note.xcodeproj/   # Xcode 工程，自动同步源码子目录
│   ├── speech_note/
│   │   ├── App/                # 应用入口、路由、本地化
│   │   ├── Features/           # 按业务功能组织的源码
│   │   │   ├── Home/           # 首页与录音筛选
│   │   │   ├── Recording/      # 录音、详情、持久化与 Live Activity
│   │   │   ├── Transcription/  # 转写调度、分句、前后台处理
│   │   │   ├── Speakers/       # 说话人识别、聚类与声纹
│   │   │   ├── Documents/      # 文稿、检索、公开文档与同步
│   │   │   ├── Import/         # 音视频导入
│   │   │   ├── Export/         # 音频与文稿导出
│   │   │   ├── Clients/        # 客户资料
│   │   │   ├── Folders/        # 文件夹管理与同步
│   │   │   ├── Purchase/       # 购买、试用与共享权限
│   │   │   └── Onboarding/     # 引导与隐私说明
│   │   ├── Infrastructure/     # 推理运行时、系统权限、归档工具
│   │   ├── Assets.xcassets/    # 应用图标与颜色资源
│   │   ├── ModelResources/    # 离线模型
│   │   └── Frameworks/        # 原生推理依赖
│   ├── RecordWidget/           # 独立 Widget target
│   ├── speech_noteTests/       # 按功能分组的单元测试及共享 Fixtures
│   ├── speech_noteUITests/     # UI 测试与商店截图流程
│   └── Supporting/            # 生成的公开 Skill/模板包
├── docs/                       # 产品、设计、架构、测试、发布与公开站点
├── tools/                      # 构建、发布、模型和资源包脚本
├── memory/                     # 本地工程排障记录
├── DESIGN.md                   # UI 设计规范
└── README.md
```

目录职责和新增文件规则见 [工程目录说明](docs/architecture/project-structure.md)。

---

## 📄 开源许可证 (License)

本项目基于 **[MIT License](LICENSE)** 开源。您可以自由地使用、修改和分发本项目代码。

---

## 🤝 贡献与反馈 (Contributing)

欢迎提交 Issue 和 Pull Request！
- 提交 Bug 或功能建议：请前往 [GitHub Issues](https://github.com/issues)
- 提交代码：欢迎 Fork 本项目并提交 Pull Request
