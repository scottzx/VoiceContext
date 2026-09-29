#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
python3 tools/integration/generate_project.py
xcodebuild -workspace VoiceContextAgent.xcworkspace -scheme VoiceContextAgent \
    -configuration Debug -destination 'generic/platform=iOS' \
    -derivedDataPath build/VoiceContextAgent \
    -clonedSourcePackagesDirPath build/PhonePackages \
    -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO build
python3 tools/integration/verify_fusion.py \
    --products build/VoiceContextAgent/Build/Products/Debug-iphoneos
