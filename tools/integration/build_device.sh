#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
usage() {
    echo 'Usage: build_device.sh [development|production] [--signed]'
    echo '  --signed  Build a signed iPhone app for packaging; does not install or run it.'
}
VARIANT=development
SIGNING_ARGS=(CODE_SIGNING_ALLOWED=NO)
for argument in "$@"; do
    case "$argument" in
        development|production) VARIANT="$argument" ;;
        --signed) SIGNING_ARGS=(-allowProvisioningUpdates CODE_SIGN_STYLE=Automatic CODE_SIGNING_ALLOWED=YES) ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
case "$VARIANT" in
    development) SCHEME=VoiceContextAgentDev; CONFIGURATION=Debug-Dev; VARIANT=development ;;
    production) SCHEME=VoiceContextAgent; CONFIGURATION=Debug; VARIANT=production ;;
esac
python3 tools/integration/generate_project.py
xcodebuild -workspace VoiceContextAgent.xcworkspace -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" -destination 'generic/platform=iOS' \
    -derivedDataPath build/VoiceContextAgent \
    -clonedSourcePackagesDirPath build/PhonePackages \
    -disableAutomaticPackageResolution "${SIGNING_ARGS[@]}" build
python3 tools/integration/verify_fusion.py \
    --variant "$VARIANT" --products "build/VoiceContextAgent/Build/Products/$CONFIGURATION-iphoneos"
