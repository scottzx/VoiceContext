#!/usr/bin/env python3
"""Compile and check the real story library on macOS without launching iOS."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="yima-story-library-checks-") as temporary:
    temporary = Path(temporary)
    binary = temporary / "checks"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "6", "-default-isolation", "MainActor",
        "-module-cache-path", str(temporary / "module-cache"),
        str(root / "Integration/App/StoryLibraryStore.swift"),
        str(root / "tools/integration/test_story_library.swift"),
        "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
