#!/usr/bin/env python3
"""Run real recording repository/SQLite/journal recovery checks on macOS only."""
from pathlib import Path
import argparse
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--repository-source", type=Path, help="Optional baseline repository source for regression reproduction")
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
source = root / "speech_note"


def declaration(text, marker):
    start = text.index(marker)
    opening = text.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]


speaker_source = (source / "Features/Speakers/SpeakerFinalizationCoordinator.swift").read_text()
helpers = "import Foundation\n" + "\n".join(
    declaration(speaker_source, marker) for marker in (
        "nonisolated struct SpeakerFinalizationJob:",
        "nonisolated struct SpeakerEmbeddingJob:",
    )
)
files = [
    "Features/Transcription/TranscriptionLanguageMode.swift",
    "Features/Recording/RecordingDomain.swift",
    "Features/Import/ImportedAudioAsset.swift",
    "Features/Transcription/ProcessingRange.swift",
    "Features/Recording/Persistence/RecordingIndex.swift",
    "Features/Recording/Persistence/RecordingJournal.swift",
]
with tempfile.TemporaryDirectory(prefix="yima-disk-recovery-checks-") as temporary:
    temporary = Path(temporary)
    helper_file = temporary / "ProductionSpeakerJobIdentities.swift"
    helper_file.write_text(helpers)
    binary = temporary / "checks"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-default-isolation", "MainActor",
        "-module-cache-path", str(temporary / "module-cache"),
        *[str(source / file) for file in files],
        str(args.repository_source or source / "Features/Recording/Persistence/RecordingRepository.swift"),
        str(helper_file), str(root / "HostTests/RecordingDiskRecoveryChecks.swift"),
        "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
