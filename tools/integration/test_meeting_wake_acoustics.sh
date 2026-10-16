#!/bin/bash
# File-only Mac test; say writes WAV fixtures and never plays or records audio.
# Requires a host Python environment with sherpa-onnx==1.13.4 installed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_PYTHON="${MEETING_KWS_PYTHON:-python3}"
OUT="$ROOT/build/meeting-kws-host"
HOST_PACKAGE="$("$TEST_PYTHON" -c 'from pathlib import Path; import sherpa_onnx; print(Path(sherpa_onnx.__file__).parent)')"
mkdir -p "$OUT"
clang++ -std=c++17 "$ROOT/tools/integration/test_meeting_wake_acoustics.cpp" \
  -I "$HOST_PACKAGE/include" -L "$HOST_PACKAGE/lib" -lsherpa-onnx-c-api \
  -Wl,-rpath,"$HOST_PACKAGE/lib" -o "$OUT/acoustics"
for fixture in wake-only wake-command wake-short negative; do
  case "$fixture" in
    wake-only) phrase='小蓝同学。';;
    wake-command) phrase='小蓝同学，查一下今天的日程。';;
    wake-short) phrase='小蓝同学查日程';;
    negative) phrase='我们先讨论会议的日程，今天下午两点开始。';;
  esac
  say -v Tingting -r 155 -o "$OUT/$fixture.aiff" "$phrase"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$OUT/$fixture.aiff" "$OUT/$fixture.wav"
done
"$OUT/acoustics" "$ROOT/speech_note/speech_note/MeetingWakeModels" \
  "$ROOT/speech_note/speech_note/ModelResources/silero_vad.onnx" \
  wake_only "$OUT/wake-only.wav" 0 timedOut \
  wake_command "$OUT/wake-command.wav" 0 command \
  wake_short "$OUT/wake-short.wav" 0 command \
  silence30_wake_only "$OUT/wake-only.wav" 30 timedOut \
  silence30_wake_command "$OUT/wake-command.wav" 30 command \
  negative "$OUT/negative.wav" 0 noWake > "$OUT/fixtures.json.partial"
mv "$OUT/fixtures.json.partial" "$OUT/fixtures.json"
python3 - "$OUT/fixtures.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1]))
assert data['runtimeVersion'] == '1.13.4'
for case in data['cases']:
    hits = [hit for frame in case['frames'] for hit in frame['hits']]
    assert len(hits) == (0 if case['expected'] == 'noWake' else 1), (case['name'], hits)
    assert all(hit['keyword'] == '小蓝同学' for hit in hits)
    print(case['name'], [(round(hit['hitEndSample'] / 16000, 3), hit['timestamps']) for hit in hits])
print('Real KWS/Silero file fixtures passed; this does not measure microphone or phone performance')
PY
