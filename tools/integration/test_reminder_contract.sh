#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TASK_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/yima-reminder-contract.XXXXXX")"
trap 'rm -rf "$TASK_BUILD"' EXIT
xcrun --sdk macosx clang -fobjc-arc -fblocks \
    -I "$TASK_ROOT/Vendor/Phone/src/ios/NativeOffloads" \
    "$TASK_ROOT/tools/integration/test_reminder_contract.m" \
    -framework Foundation -framework EventKit -o "$TASK_BUILD/test_reminder_contract"
"$TASK_BUILD/test_reminder_contract"
