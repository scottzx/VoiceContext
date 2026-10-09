# Local transcription model artifacts

The app downloads these data files from the public ModelScope repository
`scott887/SenseVoiceSmall-Q8_0.gguf`, revision
`0ac25de3b24eae49f5bf00dc485ef954b1f23a31`. ModelManifest.json pins each
artifact's byte count and SHA-256. Model weights are not included in the app.

| Artifact | Original / conversion source | License |
|---|---|---|
| SenseVoiceSmall-Q8_0.gguf | [SenseVoice](https://github.com/FunAudioLLM/SenseVoice), [GGUF conversion](https://huggingface.co/handy-computer/SenseVoiceSmall-gguf) | [FunASR model license](https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE) |
| silero_vad.onnx | [Silero VAD](https://github.com/snakers4/silero-vad), [Sherpa ONNX distribution](https://github.com/k2-fsa/sherpa-onnx/releases/tag/asr-models) | [MIT](https://github.com/snakers4/silero-vad/blob/master/LICENSE) |
| 3dspeaker_speech_eres2net_base_200k_sv_zh-cn_16k-common.onnx | [3D-Speaker](https://github.com/modelscope/3D-Speaker), [Sherpa ONNX distribution](https://github.com/k2-fsa/sherpa-onnx/releases/tag/speaker-recongition-models) | [Apache 2.0](https://github.com/modelscope/3D-Speaker/blob/main/LICENSE) |
| pyannote-segmentation-3.0.int8.onnx | [pyannote segmentation 3.0](https://huggingface.co/pyannote/segmentation-3.0), [Sherpa ONNX conversion](https://github.com/k2-fsa/sherpa-onnx/releases/tag/speaker-segmentation-models) | [MIT](https://huggingface.co/pyannote/segmentation-3.0/blob/main/LICENSE); included in pyannote-segmentation-3.0-LICENSE.txt |

The historical artifact ID `cam-plus` identifies the ERes2Net ONNX file above.
It does not identify the CAMPPlus PyTorch checkpoint in `scott887/speech`.
ModelScope mirrors distribute the pinned files; they do not change the
original authorship or license terms.
