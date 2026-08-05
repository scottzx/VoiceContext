# 0.0.1 技术验证基线

## 可重复准备

在仓库根目录执行：

```zsh
tools/build-native-runtimes.sh
tools/fetch-model-resources.sh
```

`build-native-runtimes.sh` 生成 device + simulator 的 `TranscribeCpp.xcframework`，并下载固定为 sherpa-onnx `v1.13.4` 与其 ONNX Runtime `v1.27.1` 的 iOS static XCFramework。三个 framework 与模型二进制均被 Git 忽略；原生运行时来源、版本与 SHA-256 由脚本固化，模型 SHA-256 由 `ModelResources/ModelManifest.json` 固化。

运行以下命令必须全部输出 `OK`，否则不得加载模型：

```zsh
tools/verify-model-resources.sh
```

## 真实设备验收记录

真机已连接，但下列项目仍必须在真机收集专门证据，不能由模拟器替代或以运行时成功链接替代：

| 验证项 | 设备步骤 | 记录 |
| --- | --- | --- |
| AAC 后台连续性 | 真机启动录音，锁屏/切 App ≥30 分钟，播放所有 `.m4a` 分片并对照中断时间 | 分片数、总时长、缺口、系统中断 |
| SenseVoice 生命周期 | 前台提交真实样本，进入后台后检查 `InferenceLifecycleGate` 拒绝新增 Metal 工作，回前台再恢复 | RTF、峰值内存、热状态、Metal command buffer 计数 |
| VAD/CAM++ | 同一段短语音及 2 人/多人样本重复运行 | VAD spans、embedding 维度、阈值、任何明确失败原因 |

`AACSegmentRecorder` 只负责录音和 AAC-LC 分片；它不会在音频 tap 中提交推理。`SenseVoiceInferenceService` 会先在 CPU 执行 VAD/CAM++，再经 `InferenceLifecycleGate` 取得 Metal 提交许可；App 进入后台后该门禁会拒绝新的 GPU 推理。CAM++ 无法产生合法 embedding 时必须返回 `unavailable`，不能生成随机向量。下方 2026-08-03 的“尚未接入”内容均为当时的历史快照。

## 真机证据

### 2026-08-03 — AAC 短时冒烟

- 设备：iPhone 15 Pro（iOS 26.5）。系统版本高于 `#12` 指定的 iOS 18，不能替代该版本基线。
- 构建、签名、安装和启动：通过。App 包嵌入 `CTranscribe.framework`，其动态依赖包括 Metal、MetalKit 与 Accelerate。
- 录音结果：从 App Documents 导出 3 个 `.m4a` 文件，均可解析为 AAC、单声道、16 kHz：75.776 秒、61.056 秒、61.376 秒，合计 198.208 秒。
- 验收变更：产品负责人于 2026-08-03 明确批准跳过原定的 30 分钟长时等待，以本次短时真机 AAC 冒烟替代 `#12` 的完成条件。
- 结论：AAC 采集、编码和落盘冒烟通过，`#12` 可按该豁免关闭；原定 iOS 18、30 分钟锁屏/切 App 长时连续性覆盖未执行，不能据此推断为已验证，后续发布级 QA 如需该保障须重新单列验证。

### 2026-08-03 — 原生运行时与模型预检（接入前快照）

- iPhone 15 Pro 仍处于配对可用状态；为 `arm64-apple-ios18.0` 构建的 Debug App 通过签名校验，包内已嵌入 `CTranscribe.framework`。`TranscribeRuntimeProbe` 在启动时调用 `transcribe_version()`；此前安装的 App 进程已在真机观察到运行。
- 当时 `SherpaOnnx.xcframework` 不在工程的 `Frameworks` 目录、Xcode 链接项或最终 App 包中。因此当时 VAD/CAM++ 所需的 sherpa-onnx C API 尚不可调用；该缺口已由下一节记录的接入工作消除。
- `tools/verify-model-resources.sh` 失败：SenseVoice Q5 文件的实测 SHA-256 为 `18e1ef023f5c375ed66067292943214c9ee346dbccb980d630f6809a8b626ccf`，不等于清单固定值 `f222666d92614b21386056e8069f5eba06311752018078b9c068fa52ab75c3e9`；Silero VAD 和 CAM++ 的 SHA-256 未固定。远程内容长度分别为 172,474,880、643,854、39,593,765 字节，本地 SenseVoice/CAM++ 文件也明显不完整或不可追溯。
- 源码扫描确认 `InferenceLifecycleGate` 目前只有独立 actor 和单元测试引用，尚未连接到 App 生命周期或真实 Metal 推理提交点；`SpeakerEmbeddingResult.unavailable` 同样尚未接到 CAM++ 调用。这些实现占位不构成 #13/#14 的真机推理证据。
- 已尝试在真机运行 `speech_noteTests`，但 Xcode 因设备锁屏拒绝部署测试包（“Unlock scottxz to Continue”），故没有记录任何测试通过结果。
- 当时结论：#11 仅完成 transcribe.cpp 的构建、签名和启动基线；仍缺 sherpa-onnx 与可校验的完整模型。后续运行时接入和最新剩余阻塞见下一节。

### 2026-08-03 — sherpa-onnx / ONNX Runtime 真机链接

- 通过 `root@100.92.59.9` 从官方 GitHub Release 下载并 SCP 回传后，已校验两个归档：sherpa-onnx `v1.13.4` iOS static XCFramework（16,956,621 bytes，SHA-256 `b48ec217952a5b82242ce7d8323fcbc8de54ff900a72df1f0b20bfcf7b08881d`）与其官方 `build-ios.sh` 指定的 ONNX Runtime static XCFramework `v1.27.1`（32,797,772 bytes，SHA-256 `985deaff345c7bcfbe4979b2daeec09d7a745b1e9cb73f37f4077364eb578e62`）。两个 ZIP 均通过本地完整性测试。
- `SherpaOnnx.xcframework`（`SherpaOnnxC`）和 `OnnxRuntime.xcframework`（`onnxruntime`）均为静态 archive，只加入 Xcode 的 Frameworks build phase，不嵌入 App bundle。`SherpaOnnxRuntimeProbe` 在 App 初始化时调用 `SherpaOnnxGetVersionStr()`，以强制链接并实际触及 C ABI。
- iPhone 15 Pro / iOS 26.5：干净 `arm64-apple-ios18.0` 构建、签名验证、安装和启动均通过。链接后 App 二进制导出 `_SherpaOnnxGetVersionStr` 与 `_OrtGetApiBase`；新安装包在设备上运行，PID 为 2286。
- 结论：sherpa-onnx 与其 ONNX Runtime 链接依赖已接入并完成真机启动验证。`#11` 仍不能关闭，因为 SenseVoice、Silero VAD、CAM++ 模型完整性校验仍未通过；因此 #13/#14 仍不可宣称为真实推理验证通过。

### 2026-08-04 — 模型资源完整性与 Q8_0 预检

- 产品负责人决定以 SenseVoice Small `Q8_0` 替代原计划的 `Q5_K_M`，作为先行性能验证版本。`ModelManifest.json` 与 `tools/fetch-model-resources.sh` 已同步为官方发布文件 `SenseVoiceSmall-Q8_0.gguf`，大小为 252,684,608 bytes，SHA-256 为 `6c759ee4c9748c9b3f7a5a60ca74f0f7e685fb9d45d1378fce7cfd62f59adf29`。Hugging Face 的 `x-linked-etag` 与本机 SHA-256 一致，发布提交为 `4a08b8e900b38a977e32eb08d5d0697d6e72ba04`。
- Silero VAD 从 sherpa-onnx 官方 release 重新取得，大小为 643,854 bytes，SHA-256 为 `9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6`。CAM++ 从同一 release 重新取得，大小为 39,593,765 bytes，SHA-256 为 `e2d2048292e055f7b61cdec3db010503f35369b245bf0b3bbad021c9a91e4053`；回传过程中按 1 MiB 分块复核并在本机重组后再次计算完整文件哈希。
- `tools/verify-model-resources.sh` 对 `sensevoice-q8-0`、`silero-vad` 与 `cam-plus` 均输出 `OK`。旧的 41,401,529-byte Q5 文件、693,006-byte Silero 文件及 24,723,456-byte CAM++ 文件均没有被用来固定新的哈希。
- 在 Apple M3 的 transcribe.cpp Metal 路径上，Q8_0 成功转写 5.616 秒中文样本为“开放时间早上九点至下午五点”；模型加载 563.49 ms，编码加解码 92.7 ms（约 61x realtime），进程峰值内存 365,888,256 bytes。该结果只证明 GGUF 可加载、可使用 Metal 转写，不能替代 iPhone 15 上的真实 RTF、峰值内存、热状态和后台生命周期验收。
- iPhone 15 Pro / iOS 26.5：以更新后的资源重新完成 Debug device 构建和 `codesign --verify --deep --strict`。Xcode 的文件系统同步资源步骤已将且仅将 `SenseVoiceSmall-Q8_0.gguf`（252,684,608 bytes）、`silero_vad.onnx`（643,854 bytes）、CAM++（39,593,765 bytes）和清单打入 App；旧的 41,401,529-byte 不完整 Q5 文件已移至 `/tmp` 隔离区，未被打包。App 安装到设备成功；随后的启动请求被 SpringBoard 以设备锁屏拒绝，故没有将此次安装误记为 Q8_0 真机加载或性能验证。
- 设备解锁后重新启动：`YiJie.speech-note` 已在同一真机成功启动，设备进程列表显示 `speech_note` PID 为 2518。对最终 `.app` 目录再次运行 `tools/verify-model-resources.sh`，三个模型均输出 `OK`。这验证的是签名包内资源完整性与 App 进程存活；当前 App 尚未实际调用 SenseVoice、Silero 或 CAM++，因此仍不是模型推理性能结论。
- 结论：`#11` 的模型完整性阻塞已解除。`#13` 与 `#14` 仍需将真实推理接入 App 并在真机测量，不能因资源校验通过或桌面预检而关闭。

### 2026-08-04 — SenseVoice Q8_0 真机推理与生命周期

- 为分离麦克风输入质量与模型推理链路，使用产品负责人提供的 `1agents_intro.mp3` 生成了打包测试录音 `SenseVoiceFixture.m4a`：AAC、16 kHz、单声道、17.485 秒。该资源仅用于 Debug 技术验证，不作为模型资源或用户录音数据。
- iPhone 15 Pro / iOS 26.5、Q8_0、Metal（`MTL0`）第一次真实转写成功，返回非空中文文本。音频 17.48 秒，输入平均功率 -21.7 dBFS，模型加载 97.0 ms，推理 304.9 ms，RTF 57.35x，模型驻留时 `phys_footprint` 为 389.1 MiB，热状态为 `nominal`，应用提交数为 1。
- 锁屏/切换 App 后回到前台，`InferenceLifecycleGate` 记录“后台门禁：已拒绝新增提交（1 → 1）”，即没有经应用的新增推理提交。回到前台后同一资源第二次成功转写：加载 85.0 ms，推理 290.6 ms，RTF 60.17x，`phys_footprint` 381.1 MiB，热状态 `nominal`，提交数增至 2。
- 早先两段麦克风 AAC 的平均功率约 -71 至 -72 dBFS，Q8_0 在 iPhone 与桌面都正确返回空文本；现在低于 -45 dBFS 的输入会在提交 Metal 前明确拒绝，避免将静音误记为转写成功。AAC 文件读取亦已修复为按剩余帧读取，避免对 EOF 额外 `read` 导致的 `Foundation._GenericObjCError.nilError`。
- 结论：`#13` 的直接验收“真实转写成功、后台零新增提交、回前台可继续、形成速度/内存/发热基准”已在当前 iPhone 15 Pro / iOS 26.5 上完成。此结果不替代 #2 中仍待补的 iOS 18 设备兼容性基线；`#14` 的 Silero VAD/CAM++ 真机推理仍未验证。

### 2026-08-04 — Silero VAD 与 CAM++ 真机基线

- 在同一台 iPhone 15 Pro / iOS 26.5 上，使用打包的 `SenseVoiceFixture.m4a`（AAC、16 kHz、单声道、17.485 秒）执行完整路径：Silero VAD 在 CPU 检测语音片段，将可相邻合并的片段组成转写 utterance；SenseVoice Q8_0 仅对 utterance 提交 `MTL0`；CAM++ 对检测到的真实语音计算 speaker embedding。
- 2026-08-04 16:02 的真机输出：Q8_0 返回非空转写；`audio=17.48s`、`utterances=16.30s`、输入 `-21.7 dBFS`、`load=68.7ms`、`inference=193.6ms`、`RTF=84.24x`、`memory=501.8MiB`、热状态 `nominal`、应用提交数 `2`。Silero VAD 得到 `spans=3`、合并为 `utterances=2`、原始有声时长 `15.62s`、耗时 `47.8ms`。
- CAM++ 真实成功返回 `dim=512` 的向量，计算耗时 `714.4ms`。运行时先记录原始 L2 范数 `rawNorm=36.790`，再将向量逐元素除以该范数；对外供相似度和阈值使用的向量复测为 `norm=1.000`。因此幅度不会影响余弦比较，且界面同时保留原始数值以便排查模型输出变化。
- 失败契约保持严格：CAM++ 初始化、输入流、就绪检查、原生返回、有限值或归一化任一环节失败时，结果为带原因的 `unavailable`；不会生成随机、零值或伪造的 512 维向量。
- 结论：Silero VAD、CAM++ embedding 和 L2 归一化已获得真实设备、真实模型、真实音频的性能基线。`#14` 仍不能关闭：还需要一段正常强度的手动麦克风长句，及至少两位真人说话人的重复样本，才能实测余弦相似度并校准/验证最终阈值。

### 2026-08-05 — 麦克风采样率修复与真实语音回归

- 对修复前真机 AAC 的同源诊断确认：iPhone 输入节点提供 48 kHz PCM，原实现却将这些帧直接写入标记为 16 kHz 的 AAC，未执行重采样。一份实际写盘约 7.4 秒的录音解码为 23.232 秒，音频因而被拉慢、降调约 3 倍。
- 将同一段错误音频直接送入官方 Silero ONNX 时，仅 5 帧超过 `0.25` 语音概率阈值，且连续时间不足 0.3 秒；将该信号恢复为 3 倍速度/音高后，峰值概率为 `1.000`。这证明失败源于录音时基，不是 RMS 过低、C API 队列错误或 `0.25` 阈值过高。
- `AACSegmentRecorder` 现在以麦克风实际输入格式创建 `AVAudioConverter`，在 AAC 编码前执行持续的 48 kHz → 16 kHz、单声道 Float32 转换；保留 `.default` 语音采集模式，Silero 仍使用 `threshold=0.25`、`min_speech_duration=0.3s`。修复版完成 Debug device build、严格签名校验和真机安装；三个模型资源哈希仍全部为 `OK`。
- 2026-08-05 10:20，产品负责人在同一台 iPhone 15 Pro / iOS 26.5 上完成正常麦克风长句回归：Q8_0 返回可读中文“嗯开始录音啊我们已经确认说设备解设备解锁…”；`audio=10.19s`、`utterances=9.14s`、输入 `-23.7 dBFS`、峰值 `-0.2 dBFS`；Silero 得到 `spans=2`、合并为 `utterances=1`、`voiced=8.53s`。CAM++ 成功生成 embedding，并将这份首段手动录音保存为说话人参考。
- 结论：`#13` 已完成的真机 SenseVoice 验收新增了真实麦克风输入的回归证据。`#14` 的“正常麦克风长句”和“首段参考 embedding”已完成；尚需同一说话人复录与另一位真人复录，以记录同人/异人余弦相似度并校准阈值。本轮尝试再次导出 AAC 时 CoreDevice 连接被设备重置，因此上述回归数值以产品负责人提供的真机界面结果为证，不追加伪造的离线数据。

### 2026-08-05 — CAM++ 余弦阈值保护带

- 产品负责人在修复后的真机麦克风链路上重复采样：同一说话人相对参考 embedding 的 cosine 约为 `0.6–0.8`，不同说话人约为 `0.5–0.6`。两组在 `0.60` 附近没有已验证的安全间隔，因此不使用单一 `0.60` 硬阈值，也不宣称已经得到生物识别级别的准确率。
- 技术验证界面使用可复测的三段策略：cosine `>= 0.65` 显示“同一人候选”，`<= 0.55` 显示“不同人候选”，中间区间显示“不确定，需重录”。`0.55–0.65` 是基于当前粗粒度样本范围设置的保守保护带，不是通用模型常数；换设备、麦克风路由、模型或目标人群后必须重新校准。
- 真机 Swift Testing 共执行 11 个测试且全部通过；边界回归明确验证 `0.65` 为同人候选、`0.60` 为不确定、`0.55` 为异人候选，并拒绝 NaN 和超出 `[-1, 1]` 的输入。干净 Debug App 随后重新构建、严格签名、安装并在同一真机成功启动。
- 2026-08-05，产品负责人确认当前结果无问题，明确批准将 `#14` 标记为通过。因此 `#14` 的“VAD/CAM++ 稳定输出、失败无随机向量、阈值和性能可复测”验收完成；保护带的数据局限仍保留为后续产品化校准约束。
