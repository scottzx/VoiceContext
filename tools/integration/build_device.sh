#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
case "${1:-development}" in
    development) SCHEME=VoiceContextAgentDev; CONFIGURATION=Debug-Dev; VARIANT=development ;;
    production) SCHEME=VoiceContextAgent; CONFIGURATION=Debug; VARIANT=production ;;
    *) echo 'Usage: build_device.sh [development|production]' >&2; exit 2 ;;
esac
python3 tools/integration/generate_project.py
xcodebuild -workspace VoiceContextAgent.xcworkspace -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" -destination 'generic/platform=iOS' \
    -derivedDataPath build/VoiceContextAgent \
    -clonedSourcePackagesDirPath build/PhonePackages \
    -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO build
python3 tools/integration/verify_fusion.py \
    --variant "$VARIANT" --products "build/VoiceContextAgent/Build/Products/$CONFIGURATION-iphoneos"
