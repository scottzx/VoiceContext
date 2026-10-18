#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
INDEPENDENT_INPUT_CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/independent-input.XXXXXX")
trap 'rm -rf "$INDEPENDENT_INPUT_CHECK_DIR"' EXIT
# Production input orchestration and classifier, with an in-memory PCM producer
# and ASR boundary. No microphone, model, iOS runtime or simulator is opened.
sed '/^\/\/\/ The real-time callback/,$d; /^@preconcurrency import AVFoundation$/d' \
    Integration/Recording/IndependentVoiceInput.swift > "$INDEPENDENT_INPUT_CHECK_DIR/Input.swift"
xcrun swiftc -default-isolation MainActor -swift-version 5 \
    speech_note/speech_note/Features/Recording/MeetingWakeCommandText.swift \
    "$INDEPENDENT_INPUT_CHECK_DIR/Input.swift" \
    tools/integration/test_independent_voice_input.swift \
    -o "$INDEPENDENT_INPUT_CHECK_DIR/check"
"$INDEPENDENT_INPUT_CHECK_DIR/check"
# Exercise the production ASR orchestration with an in-memory native boundary:
# the real background Metal gate stays closed while explicit commands use CPU.
sed '/^@preconcurrency import AVFoundation$/d; /^import TranscribeNative$/d; /^enum PCM16KMonoLoader/,$d' \
    speech_note/speech_note/Infrastructure/Inference/SenseVoiceInferenceService.swift \
    > "$INDEPENDENT_INPUT_CHECK_DIR/Inference.swift"
xcrun swiftc -default-isolation MainActor -swift-version 5 -D VOICE_AGENT_FUSION \
    speech_note/speech_note/Infrastructure/Inference/InferenceLifecycleGate.swift \
    "$INDEPENDENT_INPUT_CHECK_DIR/Inference.swift" \
    tools/integration/test_independent_command_asr.swift \
    -o "$INDEPENDENT_INPUT_CHECK_DIR/command-asr-check"
"$INDEPENDENT_INPUT_CHECK_DIR/command-asr-check"
# Compile the iOS-only model-protection preparation without touching files.
xcrun swiftc -typecheck -default-isolation MainActor -swift-version 5 \
    -target arm64-apple-ios17.0 -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" \
    speech_note/speech_note/Features/Recording/MeetingWakeCommandText.swift \
    "$INDEPENDENT_INPUT_CHECK_DIR/Input.swift" tools/integration/test_independent_voice_input.swift
# Compile the real microphone against the iPhoneOS SDK without opening it, so
# voice-processing and ducking API usage is checked alongside the host tests.
{
    printf '@preconcurrency import AVFoundation\nimport Foundation\n'
    sed -n '/^\/\/\/ The real-time callback/,$p' Integration/Recording/IndependentVoiceInput.swift
} > "$INDEPENDENT_INPUT_CHECK_DIR/Microphone.swift"
xcrun swiftc -typecheck -default-isolation MainActor -swift-version 5 \
    -target arm64-apple-ios17.0 -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" \
    "$INDEPENDENT_INPUT_CHECK_DIR/Microphone.swift"
