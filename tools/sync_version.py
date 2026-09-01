#!/usr/bin/env python3
"""
VoiceContext Unified Version Manager
Syncs version & build number from the root `VERSION` file to:
- speech_note.xcodeproj/project.pbxproj (all targets)
- Release documentation (docs/release/1.0-app-store-submission.md)
"""

import sys
import os
import re
import argparse
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
VERSION_FILE = ROOT_DIR / "VERSION"
PBXPROJ_FILE = ROOT_DIR / "speech_note" / "speech_note.xcodeproj" / "project.pbxproj"
RELEASE_DOC_FILE = ROOT_DIR / "docs" / "release" / "1.0-app-store-submission.md"

def read_version_file():
    if not VERSION_FILE.exists():
        raise FileNotFoundError(f"VERSION file not found at {VERSION_FILE}")
    
    version = None
    build = None
    with open(VERSION_FILE, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("VERSION="):
                version = line.split("=", 1)[1].strip().strip('"').strip("'")
            elif line.startswith("BUILD="):
                build = int(line.split("=", 1)[1].strip().strip('"').strip("'"))
    
    if not version or build is None:
        raise ValueError("VERSION or BUILD missing in VERSION file")
    return version, build

def write_version_file(version: str, build: int):
    content = f"""# VoiceContext Version Configuration
# 统一版本控制文件：修改此处或运行 ./tools/release.sh 即可自动同步所有 Target 与发布文档
VERSION={version}
BUILD={build}
"""
    with open(VERSION_FILE, "w", encoding="utf-8") as f:
        f.write(content)

def sync_pbxproj(version: str, build: int):
    if not PBXPROJ_FILE.exists():
        print(f"Warning: {PBXPROJ_FILE} not found, skipping Xcode project update.")
        return
    
    with open(PBXPROJ_FILE, "r", encoding="utf-8") as f:
        content = f.read()

    # Update MARKETING_VERSION across all targets
    content = re.sub(
        r'(\t+MARKETING_VERSION = )[^;]+;',
        rf'\g<1>{version};',
        content
    )

    # Update CURRENT_PROJECT_VERSION for speech_note and RecordWidget and test targets
    content = re.sub(
        r'(\t+CURRENT_PROJECT_VERSION = )[^;]+;',
        rf'\g<1>{build};',
        content
    )

    with open(PBXPROJ_FILE, "w", encoding="utf-8") as f:
        f.write(content)
    print(f"✓ Updated Xcode project settings -> Version: {version}, Build: {build}")

def sync_release_doc(version: str, build: int):
    if not RELEASE_DOC_FILE.exists():
        return
    
    with open(RELEASE_DOC_FILE, "r", encoding="utf-8") as f:
        content = f.read()

    # Update: iOS `1.0 (5)`
    content = re.sub(
        r'iOS `\d+\.\d+(\.\d+)? \(\d+\)`',
        f'iOS `{version} ({build})`',
        content
    )

    # Update: MARKETING_VERSION=...
    content = re.sub(
        r'MARKETING_VERSION=\d+\.\d+(\.\d+)?',
        f'MARKETING_VERSION={version}',
        content
    )

    # Update: CURRENT_PROJECT_VERSION=...
    content = re.sub(
        r'CURRENT_PROJECT_VERSION=\d+',
        f'CURRENT_PROJECT_VERSION={build}',
        content
    )

    with open(RELEASE_DOC_FILE, "w", encoding="utf-8") as f:
        f.write(content)
    print(f"✓ Updated release documentation -> Version: {version}, Build: {build}")

def main():
    parser = argparse.ArgumentParser(description="VoiceContext Version Manager")
    parser.add_argument("--bump-build", action="store_true", help="Auto-increment build number by 1")
    parser.add_argument("--set-version", type=str, help="Set marketing version (e.g. 1.0.1)")
    parser.add_argument("--set-build", type=int, help="Set specific build number (e.g. 6)")
    parser.add_argument("--sync-only", action="store_true", help="Sync without changing VERSION file")
    parser.add_argument("--get-version", action="store_true", help="Print current version and exit")
    parser.add_argument("--get-build", action="store_true", help="Print current build number and exit")
    
    args = parser.parse_args()

    version, build = read_version_file()

    if args.get_version:
        print(version)
        return
    if args.get_build:
        print(build)
        return

    modified = False
    if args.set_version:
        version = args.set_version
        modified = True
    if args.set_build is not None:
        build = args.set_build
        modified = True
    elif args.bump_build:
        build += 1
        modified = True

    if modified:
        write_version_file(version, build)
        print(f"✓ Updated VERSION file -> VERSION={version}, BUILD={build}")

    sync_pbxproj(version, build)
    sync_release_doc(version, build)
    print(f"\n🎉 Successfully synchronized VoiceContext version: {version} ({build})")

if __name__ == "__main__":
    main()
