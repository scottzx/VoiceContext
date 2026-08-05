#!/bin/zsh
set -euo pipefail

root="${1:-speech_note/speech_note/ModelResources}"
mkdir -p "$root"

download() {
  local url="$1"
  local name="$2"
  curl --fail --location --continue-at - --output "$root/$name" "$url"
}

download "https://huggingface.co/handy-computer/SenseVoiceSmall-gguf/resolve/main/SenseVoiceSmall-Q8_0.gguf" "SenseVoiceSmall-Q8_0.gguf"
download "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx" "silero_vad.onnx"
download "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_eres2net_base_200k_sv_zh-cn_16k-common.onnx" "3dspeaker_speech_eres2net_base_200k_sv_zh-cn_16k-common.onnx"

"${0:A:h}/verify-model-resources.sh" "$root"
