#!/usr/bin/env python3
"""Check production model installation/recovery on macOS, without iOS or network."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = root / "speech_note"
with tempfile.TemporaryDirectory(prefix="yima-model-download-") as temporary:
    temporary = Path(temporary)
    binary = temporary / "checks"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-default-isolation", "MainActor",
        "-module-cache-path", str(temporary / "module-cache"),
        str(source / "App/AppLocalization.swift"),
        str(source / "Infrastructure/Inference/ModelIntegrity.swift"),
        str(source / "Infrastructure/Models/TranscriptionModelStore.swift"),
        str(source / "Infrastructure/Models/TranscriptionModelDownloadService.swift"),
        str(root / "HostTests/ModelDownloadChecks.swift"), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
