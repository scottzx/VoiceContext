# Preinstalled meeting wake-word model

These files are bundled with the app and require no model download. They are
independent of the large, user-downloaded transcription models in ModelResources.

- Model: `sherpa-onnx-kws-zipformer-zh-en-3M-2025-12-20`, by pkufool.
- Runtime: sherpa-onnx 1.13.4, CPU, 16 kHz mono PCM.
- Variant: chunk 8, left context 64; original upstream int8 encoder and joiner,
  fp32 decoder. Files were renamed only; no additional quantization or conversion.
- Original release:
  https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/sherpa-onnx-kws-zipformer-zh-en-3M-2025-12-20.tar.bz2
- Release archive SHA-256:
  `68447f4fbc67e70eee3a93961f36e81e98f47aef73ce7e7ca00885c6cd3616a6`.
- Author's model repository:
  https://www.modelscope.cn/models/pkufool/icefall-kws-zipformer-zh-en-3M-2025-12-20
- Pinned model repository revision: `afc4a534ef85f2db4f84f05ed78eaac385b3387e`.
  The selected weights and tokens match the SHA-256 values in that revision's
  file metadata. Its model card is retained as `UPSTREAM_MODEL_CARD.md`.
- License: Apache License 2.0, declared in the author's model card and confirmed
  by pkufool on 2026-10-08:
  https://github.com/k2-fsa/sherpa-onnx/issues/3802#issuecomment-6052663364
  The license text is retained in `LICENSE.txt`.

`MeetingWakeManifest.json` pins byte counts and SHA-256 for all five runtime
files. The app validates them once per process before enabling keyword spotting.
The complete runtime payload is 5,449,083 bytes (about 5.20 MiB), excluding
manifest, model card, attribution, and license.

`keywords.txt` is generated from `keywords_raw.txt` using sherpa-onnx 1.13.4's
`text2token` with `tokens_type="phone+ppinyin"` and pypinyin 0.55.0:

```text
x iǎo l án t óng x ué @小蓝同学
```

The tokenizer source is:
https://github.com/k2-fsa/sherpa-onnx/blob/v1.13.4/sherpa-onnx/python/sherpa_onnx/utils.py

The English lexicon in the upstream archive is used only during development to
run that tokenizer; it is not bundled. The keyword is Chinese, and all its tokens
are present in the original model vocabulary. “小兰同学” has the same phonetic
sequence as “小蓝同学”; KWS detects that sequence without depending on ASR's
choice of Chinese characters.

The 160 ms chunk-8 figure in upstream documentation is the acoustic model's
algorithmic chunk latency, not a measured phone wake-up or task-response time.
Accuracy, false triggers, and recording continuity require physical-device tests.
