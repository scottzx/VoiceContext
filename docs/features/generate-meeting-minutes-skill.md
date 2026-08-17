# generate-meeting-minutes（Codex Skill）

任务归口：PM `#8` / `#32` / `#33`。应用不内置 LLM 总结；Mac 上的 Codex 读取公开 `VoiceContext` 文档，按用户模板生成会议纪要。

## 公开布局

本地优先（无 iCloud 也能用）：

```text
Documents/VoiceContext/          # 文件 App → 我的 iPhone → VoiceContext
├── Meetings/.../transcript.json
├── Meetings/.../transcript.md
├── Meetings/.../generated/
├── Templates/
│   └── default-meeting-minutes.md
└── Skill/
    └── generate-meeting-minutes/
        ├── SKILL.md
        ├── agents/openai.yaml
        ├── scripts/
        ├── references/
        └── fixtures/
```

开启「同步 Markdown 与 JSON 文档」且 ubiquity 容器可用时，同一相对路径会镜像到 iCloud Documents。当前 entitlements **不**写入具体 `iCloud.*` container id（避免真机签名失败）；ubiquity 常为 `nil`，本地 Documents 已足够验证。

## App 侧导出

1. 打开 App →「我的」→「会议纪要 Skill」。
2. 点「导出 / 刷新 Skill 与模板」。
3. Skill 目录会从应用内 `VoiceContextPack` 刷新；用户自定义 `Templates/*.md` 不会被覆盖；缺失的默认模板会被补齐。

仓库内规范来源：`tools/VoiceContext/`。同步进 App bundle 资源 `speech_note/speech_note/VoiceContextPack.zip`（STORED zip，避免同名 fixture 被 Xcode flatten；启动时解包到公开目录）：

```bash
./tools/sync-voicecontext-pack.sh
```

## 在 Mac Codex 上运行

### A. 直接指向公开目录（推荐）

若 iPhone 已通过 iCloud / Finder 同步，或你从 Files 拷贝了整个 `VoiceContext`：

```bash
# 例：iCloud Drive
export VC="$HOME/Library/Mobile Documents/com~apple~CloudDocs/VoiceContext"
# 或本机拷贝
# export VC="$HOME/Documents/VoiceContext"

ls "$VC/Skill/generate-meeting-minutes/SKILL.md"
ls "$VC/Templates/default-meeting-minutes.md"
```

在 Codex 中安装 / 引用该 Skill 目录（把 `generate-meeting-minutes` 目录放到 Codex skills 路径，或在会话中 `@` 该 `SKILL.md`）。

生成（确定性 stub，不调用云端 LLM）：

```bash
cd "$VC/Skill/generate-meeting-minutes"
python3 scripts/load_transcript.py "$VC/Meetings/YYYY/MM/<meeting-dir>"
python3 scripts/generate_minutes.py "$VC/Meetings/YYYY/MM/<meeting-dir>"
python3 scripts/generate_minutes.py "$VC/Meetings/YYYY/MM/<meeting-dir>" --template custom-brief
```

输出路径：

```text
<meeting-dir>/generated/<template-slug>/<YYYY-MM-DD_HH-mm-ss>.md
```

原文 `transcript.json` / `transcript.md` 只读。

### B. 使用仓库开发副本

```bash
cd /Users/scott/Documents/01-开发项目/AI应用/voice_type
cd tools/VoiceContext/Skill/generate-meeting-minutes
python3 scripts/quick_validate.py
python3 scripts/e2e_validate.py
```

`quick_validate.py` 覆盖 packaging + loader；`e2e_validate.py` 覆盖默认/自定义模板、suspected 不升级、source id/revision、输出与原文分离。

## 硬规则

- 仅 `kind=meeting` 且 `state=complete`
- JSON 优先于 Markdown
- `疑似…` 不得写成已确认
- 不虚构决定 / 行动项 / 负责人
- 输出必须带来源 `recording_id` 与 `revision`

## 验收对照（#33）

| 项 | 验证方式 |
| --- | --- |
| 默认 / 自定义模板均可生成 | `python3 scripts/e2e_validate.py` |
| suspected 不升级 confirmed | e2e 检查输出仍含 `疑似李四` |
| 输出带 source ID/revision 且与原文分离 | e2e 检查 frontmatter + `generated/` 路径 |
| App 可导出 Skill/Templates | 单元测试 `PublicSkillPackTests` + 设置页按钮 |
