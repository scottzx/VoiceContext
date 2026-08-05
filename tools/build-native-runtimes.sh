#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
transcribe="$root/transcribe.cpp"
frameworks="$root/speech_note/speech_note/Frameworks"
tmp="${TMPDIR:-/tmp}/voicecontext-native-runtimes"

[[ -d "$transcribe" ]] || { print -u2 "Missing transcribe.cpp source at $transcribe"; exit 2; }
mkdir -p "$frameworks" "$tmp"

# transcribe.cpp publishes its Swift binding as a device + simulator
# XCFramework. Metal is embedded in the device slice and absent in the
# simulator slice, matching the lifecycle policy enforced by the app.
(cd "$transcribe" && TRANSCRIBE_XCFRAMEWORK_SLICES='ios-device ios-sim' scripts/ci/build_xcframework.sh)
ditto "$transcribe/bindings/swift/build-apple/TranscribeCpp.xcframework" "$frameworks/TranscribeCpp.xcframework"

# sherpa-onnx distributes a static C API XCFramework which must be linked with
# the matching static ONNX Runtime XCFramework. Both artifacts are fixed URLs
# and digests rather than a mutable latest URL.
sherpa_zip="$tmp/sherpa-onnx-v1.13.4-ios-static.xcframework.zip"
curl --fail --location --output "$sherpa_zip" \
  "https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v1.13.4-ios-static.xcframework.zip"
[[ "$(shasum -a 256 "$sherpa_zip" | awk '{print $1}')" == "b48ec217952a5b82242ce7d8323fcbc8de54ff900a72df1f0b20bfcf7b08881d" ]] || {
  print -u2 "sherpa-onnx archive digest mismatch"
  exit 1
}
unzip -oq "$sherpa_zip" -d "$tmp/sherpa-onnx"
sherpa_framework="$(find "$tmp/sherpa-onnx" -type d -name '*.xcframework' -print -quit)"
[[ -n "$sherpa_framework" ]] || { print -u2 "sherpa-onnx archive did not contain an XCFramework"; exit 1; }
ditto "$sherpa_framework" "$frameworks/SherpaOnnx.xcframework"

onnxruntime_zip="$tmp/onnxruntime-ios-static-xcframework-1.27.1.xcframework.zip"
curl --fail --location --output "$onnxruntime_zip" \
  "https://github.com/csukuangfj/onnxruntime-libs/releases/download/v1.27.1/onnxruntime-ios-static-xcframework-1.27.1.xcframework.zip"
[[ "$(shasum -a 256 "$onnxruntime_zip" | awk '{print $1}')" == "985deaff345c7bcfbe4979b2daeec09d7a745b1e9cb73f37f4077364eb578e62" ]] || {
  print -u2 "onnxruntime archive digest mismatch"
  exit 1
}
unzip -oq "$onnxruntime_zip" -d "$tmp/onnxruntime"
onnxruntime_framework="$(find "$tmp/onnxruntime" -type d -name 'onnxruntime.xcframework' -print -quit)"
[[ -n "$onnxruntime_framework" ]] || { print -u2 "onnxruntime archive did not contain an XCFramework"; exit 1; }
ditto "$onnxruntime_framework" "$frameworks/OnnxRuntime.xcframework"

print "Native runtimes written to $frameworks"
