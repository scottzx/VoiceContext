#!/usr/bin/env bash
set -e

# ==============================================================================
# VoiceContext 一键发布与统一版本递增脚本
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

AUTO_BUMP=true
SYNC_ONLY=false
AUTO_GIT=false
OPEN_ORGANIZER=true
CUSTOM_VERSION=""
CUSTOM_BUILD=""

usage() {
    cat << "HELP"
使用说明:
  ./tools/release.sh [选项]

选项:
  (无参数)               默认自动将 Build 递增 +1，同步工程并执行 Archive 归档
  -v, --version <版本号>  指定 Marketing Version (如: 1.0.1)
  -b, --build <构建号>    指定 Build Number (如: 6)
  --no-bump              不自增 Build，直接使用当前 VERSION 文件中的版本与构建号
  --sync-only            仅同步版本号到 Xcode 工程和文档，不执行 Archive 归档
  -g, --git              自动将版本变更进行 git commit 和 git push
  --no-open              构建完成后不自动打开 Xcode Organizer
  -h, --help             显示此帮助信息

示例:
  ./tools/release.sh                    # 默认: Build 自增 +1 并打包
  ./tools/release.sh -v 1.1             # 升级到 1.1 并自动自增 Build 打包
  ./tools/release.sh --sync-only        # 仅根据 VERSION 文件同步各 Target
  ./tools/release.sh -g                 # 打包后自动提交并推送 Git
HELP
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--version)
            CUSTOM_VERSION="$2"
            shift 2
            ;;
        -b|--build)
            CUSTOM_BUILD="$2"
            shift 2
            ;;
        --no-bump)
            AUTO_BUMP=false
            shift
            ;;
        --sync-only|--no-archive)
            SYNC_ONLY=true
            shift
            ;;
        -g|--git)
            AUTO_GIT=true
            shift
            ;;
        --no-open)
            OPEN_ORGANIZER=false
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "❌ 未知参数: $1"
            usage
            ;;
    esac
done

echo "========================================================"
echo "🚀 VoiceContext 发布与版本管理"
echo "========================================================"

# 1. 统一版本更新
SYNC_ARGS=()
if [ -n "$CUSTOM_VERSION" ]; then
    SYNC_ARGS+=(--set-version "$CUSTOM_VERSION")
fi

if [ -n "$CUSTOM_BUILD" ]; then
    SYNC_ARGS+=(--set-build "$CUSTOM_BUILD")
fi

if [ "$SYNC_ONLY" = true ] && [ -z "$CUSTOM_VERSION" ] && [ -z "$CUSTOM_BUILD" ]; then
    SYNC_ARGS+=(--sync-only)
elif [ "$AUTO_BUMP" = true ] && [ -z "$CUSTOM_BUILD" ]; then
    SYNC_ARGS+=(--bump-build)
fi

python3 "$SCRIPT_DIR/sync_version.py" "${SYNC_ARGS[@]}"

CURRENT_VER=$(python3 "$SCRIPT_DIR/sync_version.py" --get-version)
CURRENT_BLD=$(python3 "$SCRIPT_DIR/sync_version.py" --get-build)

if [ "$SYNC_ONLY" = true ]; then
    echo "✅ 版本同步已完成 (未执行 Archive 打包)"
    exit 0
fi

# 2. 执行 Xcode Archive 归档打包
echo ""
echo "📦 正在执行 Xcode Archive 归档打包 (Version: $CURRENT_VER, Build: $CURRENT_BLD)..."
mkdir -p build

ARCHIVE_PATH="$ROOT_DIR/build/speech_note.xcarchive"
rm -rf "$ARCHIVE_PATH"

xcodebuild -project speech_note/speech_note.xcodeproj \
           -scheme speech_note \
           -destination 'generic/platform=iOS' \
           -archivePath "$ARCHIVE_PATH" \
           clean archive

if [ $? -ne 0 ]; then
    echo "❌ Xcode Archive 归档失败，请检查编译错误。"
    exit 1
fi

# 3. 复制到 Xcode Organizer 系统目录
TODAY=$(date +%Y-%m-%d)
TIME_STR=$(date +%H-%M-%S)
ORGANIZER_DIR="$HOME/Library/Developer/Xcode/Archives/$TODAY"
ORGANIZER_ARCHIVE="$ORGANIZER_DIR/speech_note $TODAY $TIME_STR.xcarchive"

mkdir -p "$ORGANIZER_DIR"
cp -R "$ARCHIVE_PATH" "$ORGANIZER_ARCHIVE"

echo "✅ 生产包归档成功:"
echo "   - 临时路径: $ARCHIVE_PATH"
echo "   - Xcode Organizer 路径: $ORGANIZER_ARCHIVE"

# 4. Git 提交与推送 (如果启用了 --git)
if [ "$AUTO_GIT" = true ]; then
    echo ""
    echo "🐙 正在提交版本变更到 Git..."
    git add VERSION speech_note/speech_note.xcodeproj/project.pbxproj docs/release/1.0-app-store-submission.md
    git commit -m "chore(release): bump version to $CURRENT_VER ($CURRENT_BLD)" || true
    echo "⬆️ 正在推送到远端仓库..."
    git push origin main
fi

# 5. 调起 Xcode Organizer
if [ "$OPEN_ORGANIZER" = true ]; then
    echo ""
    echo "🖥️ 正在打开 Xcode Organizer..."
    open -a Xcode "$ORGANIZER_ARCHIVE"
fi

echo ""
echo "========================================================"
echo "🎉 发布准备就绪！"
echo "📱 版本: $CURRENT_VER ($CURRENT_BLD)"
echo "👉 后续步骤: 在已弹出的 Xcode Organizer 窗口中点击 'Distribute App' -> 'Upload' 上传至 App Store Connect。"
echo "========================================================"
