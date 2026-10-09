#!/usr/bin/env python3
"""Compile and execute production transcript/retry logic on the macOS host.

No iOS app, simulator, or device is launched. Speaker helper declarations are
copied verbatim from production to avoid linking the unrelated Sherpa runtime.
"""
from pathlib import Path
import argparse
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--legacy-only", action="store_true", help="Run only production-decoder legacy compatibility cases")
args = parser.parse_args()

root = Path(__file__).resolve().parents[1]
source = root / "speech_note"


def declaration(path, marker):
    text = (source / path).read_text()
    start = text.index(marker)
    opening = text.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]


helpers = "import Foundation\nimport AVFoundation\n" + declaration(
    "Features/Speakers/OfflineSpeakerReclustering.swift", "nonisolated struct SpeakerTurn:"
) + "\nnonisolated enum TemporarySpeakerLabeling {\n" + "\n".join(
    declaration("Features/Speakers/SpeakerClustering.swift", marker)
    for marker in ("static func mergeRosters(", "private static func speakerSortKey(")
) + "\n}\n" + "\n".join(
    declaration("Features/Speakers/SpeakerFinalizationCoordinator.swift", marker)
    for marker in ("nonisolated struct SpeakerFinalizationJob:", "nonisolated struct SpeakerEmbeddingJob:")
) + "\nnonisolated enum PCM16KMonoLoader {\n" + declaration(
    "Infrastructure/Inference/SenseVoiceInferenceService.swift", "nonisolated static func isReadable("
) + "\n}\n" + declaration("App/AppLocalization.swift", "extension Date {") + "\n"
helpers += "nonisolated enum OfflineSpeakerReclustering {\n" + declaration(
    "Features/Speakers/OfflineSpeakerReclustering.swift", "struct Result: Equatable, Sendable {"
) + "\n}\nnonisolated enum SpeakerFinalizationCoordinator {\n" + declaration(
    "Features/Speakers/SpeakerFinalizationCoordinator.swift", "enum FinalizationError: LocalizedError {"
) + "\n" + declaration(
    "Features/Speakers/SpeakerFinalizationCoordinator.swift", "private static func completedDocument("
).replace("private static func", "static func", 1) + "\n}\n"

files = [
    "Features/Transcription/TranscriptionLanguageMode.swift",
    "Features/Recording/RecordingDomain.swift",
    "Features/Import/ImportedAudioAsset.swift",
    "Features/Import/ImportAudioRangeDecoder.swift",
    "Features/Transcription/ProcessingRange.swift",
    "Features/Transcription/TranscriptionRetryPreflight.swift",
    "Features/Transcription/TranscriptionAdmissionPolicy.swift",
    "Features/Transcription/ForegroundTranscriptionScheduler.swift",
    "Infrastructure/Inference/InferenceLifecycleGate.swift",
    "Features/Speakers/SpeakerIdentity.swift",
    "Features/Documents/TranscriptDocumentV1.swift",
    "Features/Documents/TranscriptDocumentEdits.swift",
    "Features/Documents/TranscriptSearchIndex.swift",
    "Features/Recording/Persistence/RecordingIndex.swift",
    "Features/Recording/Persistence/RecordingJournal.swift",
    "Features/Recording/Persistence/RecordingRepository.swift",
    "Features/Transcription/CompletionReconciler.swift",
]
with tempfile.TemporaryDirectory(prefix="yima-transcript-protection-") as temporary:
    temporary = Path(temporary)
    helper_file = temporary / "ProductionSpeakerHelpers.swift"
    helper_file.write_text(helpers)
    binary = temporary / "verify-transcript-protection"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-default-isolation", "MainActor",
        "-module-cache-path", str(temporary / "module-cache"),
        *[str(source / file) for file in files], str(helper_file),
        str(root / "HostTests/TranscriptProtectionChecks.swift"),
        str(root / "HostTests/TranscriptLegacyCompatibilityChecks.swift"),
        str(root / "HostTests/FreeTranscriptionCompatibilityChecks.swift"), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary), *(["--legacy-only"] if args.legacy_only else [])], check=True)
