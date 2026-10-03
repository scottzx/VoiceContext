#!/bin/bash
set -euo pipefail
task_root=$(cd "$(dirname "$0")/../.." && pwd)
task_tmp=$(mktemp -d)
trap 'rm -rf "$task_tmp"' EXIT
xcrun --sdk macosx swiftc -parse-as-library "$task_root/tools/integration/recording_ai_canonical_reference.swift" "$task_root/tools/integration/test_recording_ai_hash.swift" -o "$task_tmp/swift-hash"
xcrun --sdk macosx clang -fobjc-arc -framework Foundation "$task_root/tools/integration/recording_ai_canonical_reference.m" "$task_root/tools/integration/test_recording_ai_hash.m" -o "$task_tmp/objc-hash"
"$task_tmp/swift-hash" "$task_root/docs/design/recording-ai-actions-schema/canonical-hash.vectors.json"
"$task_tmp/objc-hash" "$task_root/docs/design/recording-ai-actions-schema/canonical-hash.vectors.json"
