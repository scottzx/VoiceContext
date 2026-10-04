#!/usr/bin/env python3
"""Run the production Skill seeder on macOS with temporary local/cloud directories.

No iOS app, device, simulator, real iCloud container, or user document is opened.
Mirror/attention value declarations are copied verbatim from production. Unused
onboarding and transcript declarations only satisfy unrelated default/layout APIs;
the checks always inject sync configuration and never call those defaults.
"""
from pathlib import Path
import subprocess
import tempfile

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


helpers = "import Foundation\n" + declaration(
    "Features/Documents/PublicDocumentiCloudMirror.swift", "nonisolated struct PublicDocumentMirrorResult:"
) + "\n" + declaration(
    "Features/Documents/DocumentSyncAttention.swift", "nonisolated struct DocumentSyncAttention:"
) + """
nonisolated struct OnboardingPreferences {
    var documentSyncEnabled: Bool { fatalError("Tests must inject sync configuration") }
}
nonisolated struct TranscriptDocumentV1 {
    let kind: String
    let recordingID: UUID
    let startedAt: Date
    let timezone: String
}
"""
files = [
    "Features/Documents/PublicDocumentLayout.swift",
    "Features/Documents/PublicDocumentFileIO.swift",
    "Features/Documents/PublicDocumentContainer.swift",
    "Features/Documents/PublicSkillPackSeeder.swift",
    "Infrastructure/Archives/StoredZipExtractor.swift",
]
with tempfile.TemporaryDirectory(prefix="yima-skill-preservation-") as temporary:
    temporary = Path(temporary)
    helper_file = temporary / "ProductionValueDeclarations.swift"
    helper_file.write_text(helpers)
    binary = temporary / "verify-skill-preservation"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-default-isolation", "MainActor",
        "-module-cache-path", str(temporary / "module-cache"),
        *[str(source / file) for file in files], str(helper_file),
        str(root / "HostTests/SkillPackPreservationChecks.swift"), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True)
