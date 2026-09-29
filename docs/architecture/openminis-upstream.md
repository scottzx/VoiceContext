# OpenMinis 上游维护约定

决策日期：2026-09-29。

## 单仓开发

`voice_type` 是唯一产品开发、提交、构建与交付仓库：录音代码在 `speech_note/`，Agent 代码在 `Vendor/Phone/`，融合代码在 `Integration/`。Agent 的后续上游来源为 [OpenMinis/OpenMinis](https://github.com/OpenMinis/OpenMinis)，跟踪 `main`。

`1agents_phone` 不再作为独立产品仓库维护，也不再承担上游更新中转。原本地目录和远端可以作为历史留档保留；本次没有删除目录或归档远端。已有定制能力由 `voice_type` 承接。

## 来源与基线

| 记录 | 值 / 含义 |
|---|---|
| 官方上游 | `https://github.com/OpenMinis/OpenMinis.git` |
| 本地上游 remote | `openminis`，用于读取和比较 |
| 产品 remote | `origin`，继续指向现有 VoiceContext 产品仓库 |
| 首次导入仓库 | `https://github.com/scottzx/1agents_phone.git`，仅历史来源 |
| 首次导入提交 | `02956e269857e32335b16b4d5e6af999ff14c6e1` |
| 首次导入的 OpenMinis 基线 | `09fc199928de0f26685e766c34e6d541c7a69e5a` |
| 当前 iOS 合入基线 | `4ef29002e88db1e20e462ec2ff46916e8a7dcb45`（v1.13；保留本地适配）|

首次导入包含 fork 的 AgentKit、硬件桥、云端子 Agent 等定制，不能将首次导入 SHA 改写成 OpenMinis SHA，也不能直接用官方源码覆盖现有目录。上游基线来自导入提交与原 `upstream/main` 的共同祖先；它不表示已跟上当前最新上游。

[SOURCE_SNAPSHOT.json](../../Vendor/Phone/SOURCE_SNAPSHOT.json) 记录来源地址、原始 SHA、上游基线与维护策略；[phone-source-manifest.json](../../tools/integration/phone-source-manifest.json) 保留首次导入文件指纹。后者是历史审计依据，不为消除本地修改提示而重算。原生缓存指纹也不等于源码版本验证。

## 获取上游

Git remote 配置仅保存在本地 `.git/config`，不会随普通克隆传递。新检出仓库时，先查看已有 remotes；尚无 `openminis` 时再添加：

```bash
git remote -v
git remote add openminis https://github.com/OpenMinis/OpenMinis.git
git fetch --no-tags openminis main
```

已有该 remote 时只执行 fetch。获取远端提交不会更新 `Vendor/Phone`，也不会改变当前工作分支。正常提交与推送仍面向产品 `origin`。

查看上游相对当前 iOS 合入基线的变化（首次导入与 v1.13 的对比保留在下方历史记录）：

```bash
git log --oneline 4ef29002e88db1e20e462ec2ff46916e8a7dcb45..openminis/main
git diff --stat 4ef29002e88db1e20e462ec2ff46916e8a7dcb45 openminis/main -- src/ios src/apple src/shared deps scripts
```

## 合入更新

1. 在 `voice_type` 创建本次更新分支，固定目标 OpenMinis SHA，记录需要的修复或功能范围。
2. 对照上游基线、目标上游和本地源码，按文件合入。上游 `src/ios/` 对应本地 `Vendor/Phone/src/ios/`，其他已导入目录按相同前缀映射；新增文件还需检查融合工程成员关系。部分目录可能是 fork 新增，应保留。
3. 保留产品身份、Dev 隔离、录音优先、会议上下文、已导入的 fork 能力和凭据移除等本地适配。上游更新涉及 iSH 或其他子模块时，单独审核对应源码、固定版本和原生库重建需求。
4. 重新生成融合工程，执行静态装配审计，再按变更范围进行设备编译和获得授权的真机验证。遵守项目禁止模拟器的约定。
5. 将目标 SHA、实际合入的提交 / 文件范围、冲突处理和验证结果记录在 `docs/`，与代码一起提交。只有完成相应范围的合并后才能推进该范围的基线；选择性修复不能记作完整升级。

```bash
python3 tools/integration/generate_project.py
python3 tools/integration/verify_fusion.py --variant development
python3 tools/integration/verify_fusion.py --variant production
```

两仓库根目录布局和 Git 历史不同，不在产品分支直接执行 `git pull openminis main`、整体 merge 或未经路径适配的 cherry-pick。`import_phone.py` 是首次导入工具，会拒绝覆盖已有 Vendor，不作为更新工具使用。

最初配置阶段仅确定单仓维护策略、配置直接上游并补充来源记录；没有升级 Agent 源码，也没有移除既有功能。

## 2026-09-29 上游拉取记录

已成功执行 `git fetch --no-tags openminis main`，建立本地 `openminis/main`：

- 上游提交：`4ef29002e88db1e20e462ec2ff46916e8a7dcb45`，`Merge pull request #289 from OpenMinis/v1.13`。
- 上游提交时间：2026-09-02 02:19:16 +08:00；这是提交时间，不是本次拉取时间。
- 已确认原基线 `09fc199928de0f26685e766c34e6d541c7a69e5a` 是该提交的祖先，两者之间新增 11 个提交。
- 上游整仓差异为 483 个文件，新增 107,203 行、删除 5,063 行，包含 Android 变更；此数字不代表融合产品需要全部移植。
- iOS 相关变化主要涉及备份恢复（文件夹 / rclone、流式包写入）、模型服务与语音、thinking 与模型路由、聊天 / 同步 / 用量 / Intents / 界面，以及 iSH 内核与终端相关更新。以上按提交说明归类，尚未逐项评估融合兼容性。

本次利用本机保留的历史上游对象减少重复下载，随后从官方 remote 完成增量传输；这些对象已进入 `voice_type` 自身的 Git 对象库，不依赖旧仓库的对象链接。后续直接 fetch `openminis` 即可。

上述拉取阶段只获取上游历史并核对差异，没有 merge、cherry-pick 或覆盖 `Vendor/Phone`。产品实际合入基线仍为原记录，既有定制与工作区未提交代码继续保留；后续按上面的更新流程选择并合入具体变更。

后续已按用户要求将 v1.13 的 iOS 及共用依赖更新合入融合工程。当前适配、检查和运行验证边界见 [v1.13 合并记录](openminis-v1.13-integration.md)。
