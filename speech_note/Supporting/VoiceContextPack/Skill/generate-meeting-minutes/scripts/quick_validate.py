#!/usr/bin/env python3
"""Validate skill packaging and deterministic transcript loading/generation."""

from __future__ import annotations

import hashlib
import re
import shutil
import sys
import tempfile
import os
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
SKILL_DIR = Path(os.environ["GMM_SKILL_DIR"]).resolve() if os.environ.get("GMM_SKILL_DIR") else SCRIPT_DIR.parent
FIXTURES = SKILL_DIR / "fixtures"
sys.path.insert(0, str(SCRIPT_DIR))

from e2e_validate import run_e2e  # noqa: E402
from generate_minutes import generate  # noqa: E402
from load_transcript import LoadError, load_transcript  # noqa: E402

ALLOWED_FRONTMATTER = {
    "name",
    "description",
    "license",
    "allowed-tools",
    "metadata",
    "compatibility",
}


def fail(message: str) -> None:
    raise AssertionError(message)


def validate_skill_md(skill_path: Path) -> None:
    skill_md = skill_path / "SKILL.md"
    if not skill_md.exists():
        fail("SKILL.md not found")
    content = skill_md.read_text(encoding="utf-8")
    if not content.startswith("---"):
        fail("No YAML frontmatter found")
    match = re.match(r"^---\n(.*?)\n---", content, re.DOTALL)
    if not match:
        fail("Invalid frontmatter format")
    frontmatter: dict[str, object] = {}
    for raw in match.group(1).splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or ":" not in line:
            continue
        key, value = line.split(":", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key in {"name", "description", "license", "compatibility", "allowed-tools"}:
            frontmatter[key] = value
        elif key == "metadata":
            frontmatter[key] = {}
        else:
            # Nested metadata keys appear indented; ignore body of metadata block.
            if not raw.startswith(" ") and not raw.startswith("\t"):
                frontmatter[key] = value
    unexpected = set(frontmatter) - ALLOWED_FRONTMATTER
    if unexpected:
        fail(f"Unexpected frontmatter keys: {sorted(unexpected)}")
    name = str(frontmatter.get("name", "")).strip()
    description = str(frontmatter.get("description", "")).strip()
    if not name:
        fail("Missing name in frontmatter")
    if not description:
        fail("Missing description in frontmatter")
    if not re.match(r"^[a-z0-9-]+$", name):
        fail(f"Name '{name}' should be kebab-case")
    if name.startswith("-") or name.endswith("-") or "--" in name:
        fail(f"Name '{name}' has invalid hyphen placement")
    if len(name) > 64:
        fail("Name too long")
    if "<" in description or ">" in description:
        fail("Description cannot contain angle brackets")
    if len(description) > 1024:
        fail("Description too long")
    if name != skill_path.name:
        fail(f"Frontmatter name {name!r} must match directory {skill_path.name!r}")


def fingerprint(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_fingerprints(meeting_dir: Path) -> dict[str, str]:
    result = {}
    for name in ("transcript.json", "transcript.md"):
        path = meeting_dir / name
        if path.exists():
            result[name] = fingerprint(path)
    return result


def copy_fixture(name: str, dest_root: Path) -> Path:
    src = FIXTURES / name
    dest = dest_root / name
    shutil.copytree(src, dest)
    return dest


def test_load_fixtures(tmp: Path) -> None:
    for name, expect_kind in (
        ("complete-meeting", "json"),
        ("json-only", "json"),
        ("md-only", "markdown"),
    ):
        fixture = copy_fixture(name, tmp / "load")
        # Prefer directory input when available.
        target = fixture if (fixture / "transcript.json").exists() or (fixture / "transcript.md").exists() else fixture
        if name == "json-only":
            loaded = load_transcript(fixture / "transcript.json")
        elif name == "md-only":
            loaded = load_transcript(fixture / "transcript.md")
        else:
            loaded = load_transcript(fixture)
        assert loaded.source_kind == expect_kind, f"{name}: expected {expect_kind}, got {loaded.source_kind}"
        assert loaded.state == "complete"
        assert loaded.kind == "meeting"
        assert loaded.revision == 3
        print(f"PASS load {name} via {loaded.source_kind}")

    # Directory with both JSON and MD must prefer JSON.
    both = copy_fixture("complete-meeting", tmp / "prefer")
    loaded = load_transcript(both)
    assert loaded.source_kind == "json"
    assert loaded.source_path.endswith("transcript.json")
    print("PASS directory prefers JSON")


def test_non_complete_fails(tmp: Path) -> None:
    fixture = copy_fixture("processing-meeting", tmp / "processing")
    before = source_fingerprints(fixture)
    try:
        load_transcript(fixture)
        fail("processing fixture should fail")
    except LoadError as exc:
        message = str(exc)
        assert "complete" in message or "processing" in message
        print(f"PASS non-complete fails: {message}")
    after = source_fingerprints(fixture)
    assert before == after
    print("PASS non-complete leaves sources unchanged")


def test_generate_preserves_sources(tmp: Path) -> None:
    fixture = copy_fixture("complete-meeting", tmp / "generate")
    # Point VoiceContext root discovery at repo Tools/VoiceContext by nesting.
    voice_root = tmp / "VoiceContext"
    meeting_parent = voice_root / "Meetings" / "2026" / "08" / "demo"
    meeting_parent.parent.mkdir(parents=True, exist_ok=True)
    meeting_dir = voice_root / "Meetings" / "2026" / "08" / "2026-08-03_10-30-00_BA485C93"
    shutil.copytree(fixture, meeting_dir)
    shutil.copytree(SKILL_DIR.parents[1] / "Templates", voice_root / "Templates")
    (voice_root / "Skill").mkdir(exist_ok=True)

    before = source_fingerprints(meeting_dir)
    output = generate(meeting_dir)
    after = source_fingerprints(meeting_dir)
    assert before == after, "source files changed"
    assert output.exists()
    text = output.read_text(encoding="utf-8")
    assert "source_recording_id: BA485C93-6D6E-42E9-ADDA-B8DA50B2CA7C" in text
    assert "source_revision: 3" in text
    assert "default-meeting-minutes" in str(output)
    assert output.parent.name == "default-meeting-minutes"
    assert re.fullmatch(r"\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\.md", output.name)
    rel = Path(output).resolve().relative_to(Path(meeting_dir).resolve())
    print(f"PASS generate wrote {rel} without touching sources")


def validate_required_paths(skill_path: Path) -> None:
    required = [
        skill_path / "SKILL.md",
        skill_path / "agents" / "openai.yaml",
        skill_path / "scripts" / "load_transcript.py",
        skill_path / "scripts" / "generate_minutes.py",
        skill_path / "scripts" / "quick_validate.py",
        skill_path / "scripts" / "e2e_validate.py",
        skill_path / "references" / "transcript-schema.md",
        skill_path / "references" / "generation-rules.md",
        skill_path / "fixtures" / "complete-meeting" / "transcript.json",
        skill_path / "fixtures" / "complete-meeting" / "transcript.md",
        skill_path / "fixtures" / "processing-meeting" / "transcript.json",
        skill_path / "fixtures" / "json-only" / "transcript.json",
        skill_path / "fixtures" / "md-only" / "transcript.md",
        skill_path.parents[1] / "Templates" / "default-meeting-minutes.md",
    ]
    missing = [str(p) for p in required if not p.exists()]
    if missing:
        fail("missing required files:\n- " + "\n- ".join(missing))
    print("PASS required paths present")


def main() -> int:
    try:
        validate_required_paths(SKILL_DIR)
        validate_skill_md(SKILL_DIR)
        print("PASS SKILL.md frontmatter")
        with tempfile.TemporaryDirectory(prefix="gmm-quick-validate-") as tmp:
            tmp_path = Path(tmp)
            test_load_fixtures(tmp_path)
            test_non_complete_fails(tmp_path)
            test_generate_preserves_sources(tmp_path)
            run_e2e(tmp_path / "e2e")
            print("PASS e2e default+custom / suspected / provenance")
    except AssertionError as exc:
        print(f"FAIL: {exc}")
        return 1
    except Exception as exc:  # pragma: no cover - unexpected
        print(f"FAIL: unexpected error: {exc}")
        return 1
    print("Skill is valid!")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
