#!/usr/bin/env python3
"""End-to-end validation for generate-meeting-minutes (#33).

Loads a fixture meeting, generates with default + custom templates, and asserts:
- suspected speakers are not upgraded to confirmed
- output records source recording_id / revision
- output lives under generated/ and leaves transcript sources untouched
"""

from __future__ import annotations

import hashlib
import os
import re
import shutil
import sys
import tempfile
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

SCRIPT_DIR = Path(__file__).resolve().parent
SKILL_DIR = Path(os.environ["GMM_SKILL_DIR"]).resolve() if os.environ.get("GMM_SKILL_DIR") else SCRIPT_DIR.parent
VOICE_CONTEXT_SRC = SKILL_DIR.parents[1]
FIXTURES = SKILL_DIR / "fixtures"
sys.path.insert(0, str(SCRIPT_DIR))

from generate_minutes import generate  # noqa: E402
from load_transcript import LoadError, load_transcript  # noqa: E402

CUSTOM_TEMPLATE = """---
name: custom-brief
slug: custom-brief
description: Minimal custom template for e2e validation.
---

# 简报 · {{title}}

## Provenance
- id: {{recording_id}}
- rev: {{revision}}
- template: {{template_slug}}

## 参与人
{{speakers_section}}

## 摘录
{{excerpts_section}}
"""


def fail(message: str) -> None:
    raise AssertionError(message)


def fingerprint(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_fingerprints(meeting_dir: Path) -> dict[str, str]:
    result = {}
    for name in ("transcript.json", "transcript.md"):
        path = meeting_dir / name
        if path.exists():
            result[name] = fingerprint(path)
    return result


def prepare_voice_context(tmp: Path) -> tuple[Path, Path]:
    voice_root = tmp / "VoiceContext"
    meeting_dir = voice_root / "Meetings" / "2026" / "08" / "2026-08-03_10-30-00_BA485C93"
    meeting_dir.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(FIXTURES / "complete-meeting", meeting_dir)
    shutil.copytree(VOICE_CONTEXT_SRC / "Templates", voice_root / "Templates")
    # Public layout Skill tree (what App/iCloud export should look like).
    shutil.copytree(SKILL_DIR, voice_root / "Skill" / "generate-meeting-minutes")
    custom = voice_root / "Templates" / "custom-brief.md"
    custom.write_text(CUSTOM_TEMPLATE, encoding="utf-8")
    return voice_root, meeting_dir


def assert_provenance(text: str, recording_id: str, revision: int, slug: str) -> None:
    assert f"source_recording_id: {recording_id}" in text, "missing source_recording_id"
    assert f"source_revision: {revision}" in text, "missing source_revision"
    assert f"template_slug: {slug}" in text, "missing template_slug"
    assert "schema: voice-context/meeting-minutes@1" in text


def assert_suspected_not_upgraded(text: str) -> None:
    assert "疑似李四" in text, "suspected speaker missing from output"
    # Must not rewrite 疑似李四 as bare confirmed 李四 in the speakers section.
    speakers_block = text
    if "## 参与人" in text:
        after = text.split("## 参与人", 1)[1]
        speakers_block = after.split("##", 1)[0]
    if re.search(r"(?m)^-\s*李四\s*$", speakers_block):
        fail("suspected speaker upgraded to confirmed bare 李四")
    if "李四（已确认）" in speakers_block and "疑似李四" not in speakers_block:
        fail("suspected speaker replaced by confirmed label")
    assert "未升级为已确认" in text or "疑似李四" in speakers_block


def assert_separate_from_sources(meeting_dir: Path, output: Path) -> None:
    meeting_resolved = meeting_dir.resolve()
    output_resolved = output.resolve()
    # macOS temp dirs may appear as /var vs /private/var; compare via commonpath.
    if Path(os.path.commonpath([str(meeting_resolved), str(output_resolved)])) != meeting_resolved:
        # Fall back through realpath for symlink prefixes.
        meeting_resolved = Path(os.path.realpath(meeting_dir))
        output_resolved = Path(os.path.realpath(output))
    rel = output_resolved.relative_to(meeting_resolved)
    parts = rel.parts
    assert parts[0] == "generated", f"output not under generated/: {rel}"
    assert output.name != "transcript.json"
    assert output.name != "transcript.md"
    assert "transcript.json" not in str(rel)
    assert "transcript.md" not in str(rel)
    # Output must not replace or sit beside sources at meeting root.
    assert output.parent != meeting_dir


def run_e2e(tmp: Path) -> None:
    voice_root, meeting_dir = prepare_voice_context(tmp)
    loaded = load_transcript(meeting_dir)
    assert loaded.state == "complete"
    assert loaded.revision == 3
    recording_id = loaded.recording_id

    before = source_fingerprints(meeting_dir)
    fixed = datetime(2026, 8, 12, 12, 0, 0, tzinfo=ZoneInfo("Asia/Shanghai"))

    default_out = generate(
        meeting_dir,
        template="default-meeting-minutes",
        generated_at=fixed,
    )
    custom_out = generate(
        meeting_dir,
        template="custom-brief",
        generated_at=fixed.replace(second=1),
    )
    after = source_fingerprints(meeting_dir)
    assert before == after, "source transcript files were modified"

    assert default_out.exists()
    assert custom_out.exists()
    assert default_out.parent.name == "default-meeting-minutes"
    assert custom_out.parent.name == "custom-brief"
    assert default_out != custom_out

    default_text = default_out.read_text(encoding="utf-8")
    custom_text = custom_out.read_text(encoding="utf-8")

    assert_provenance(default_text, recording_id, 3, "default-meeting-minutes")
    assert_provenance(custom_text, recording_id, 3, "custom-brief")
    assert_suspected_not_upgraded(default_text)
    assert_suspected_not_upgraded(custom_text)
    assert_separate_from_sources(meeting_dir, default_out)
    assert_separate_from_sources(meeting_dir, custom_out)

    # Public Skill install path is readable for Mac Codex.
    skill_md = voice_root / "Skill" / "generate-meeting-minutes" / "SKILL.md"
    assert skill_md.exists(), "exported Skill/SKILL.md missing"
    assert (voice_root / "Templates" / "default-meeting-minutes.md").exists()

    print(f"PASS default template -> {Path(os.path.realpath(default_out)).relative_to(Path(os.path.realpath(meeting_dir)))}")
    print(f"PASS custom template  -> {Path(os.path.realpath(custom_out)).relative_to(Path(os.path.realpath(meeting_dir)))}")
    print("PASS suspected speakers not upgraded")
    print("PASS provenance source id/revision present")
    print("PASS output separated from transcript sources")
    print("PASS public VoiceContext Skill/Templates layout present")


def main() -> int:
    try:
        with tempfile.TemporaryDirectory(prefix="gmm-e2e-") as tmp:
            run_e2e(Path(tmp))
    except AssertionError as exc:
        print(f"FAIL: {exc}")
        return 1
    except LoadError as exc:
        print(f"FAIL: load/generate error: {exc}")
        return 1
    except Exception as exc:  # pragma: no cover
        print(f"FAIL: unexpected error: {exc}")
        return 1
    print("E2E valid!")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
