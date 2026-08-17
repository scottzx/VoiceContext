#!/usr/bin/env python3
"""Validate a meeting transcript and write a templated minutes stub under generated/."""

from __future__ import annotations

import argparse
import hashlib
import re
import sys
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from load_transcript import LoadError, load_transcript

UNCONFIRMED = "（未从逐字稿确认，留空）"


def template_slug_from_path(path: Path) -> str:
    stem = path.stem
    slug = re.sub(r"[^a-zA-Z0-9_-]+", "-", stem).strip("-").lower()
    return slug or "template"


def find_voice_context_root(meeting_dir: Path) -> Path | None:
    current = meeting_dir.resolve()
    for candidate in [current, *current.parents]:
        if (candidate / "Templates").is_dir() and (candidate / "Skill").is_dir():
            return candidate
        if (candidate / "Templates").is_dir() and candidate.name == "VoiceContext":
            return candidate
    return None


def resolve_template(
    meeting_dir: Path,
    template: str | None,
    voice_context_root: Path | None,
) -> Path:
    if template:
        path = Path(template).expanduser()
        if path.exists():
            return path.resolve()
        if voice_context_root is not None:
            nested = voice_context_root / "Templates" / template
            if nested.exists():
                return nested.resolve()
            if not template.endswith(".md"):
                nested_md = voice_context_root / "Templates" / f"{template}.md"
                if nested_md.exists():
                    return nested_md.resolve()
        raise LoadError(f"template not found: {template}")

    if voice_context_root is not None:
        default = voice_context_root / "Templates" / "default-meeting-minutes.md"
        if default.exists():
            return default.resolve()

    # Skill-bundled fallback when installed beside Templates/.
    skill_root = Path(__file__).resolve().parents[1]
    repo_templates = skill_root.parents[1] / "Templates" / "default-meeting-minutes.md"
    if repo_templates.exists():
        return repo_templates.resolve()
    raise LoadError("default template not found; pass --template")


def extract_template_body(text: str) -> str:
    if text.startswith("---"):
        match = re.match(r"^---\n.*?\n---\n?(.*)$", text, re.DOTALL)
        if match:
            return match.group(1).lstrip("\n")
    return text


def speaker_lines(doc: dict) -> str:
    speakers = doc.get("speakers") or []
    if not speakers:
        return "- （逐字稿未提供说话人名单）"
    lines = []
    for speaker in speakers:
        label = str(speaker)
        if "疑似" in label:
            lines.append(f"- {label}  — 保持疑似，未升级为已确认")
        elif "已确认" in label:
            lines.append(f"- {label}")
        else:
            lines.append(f"- {label}")
    return "\n".join(lines)


def excerpt_lines(doc: dict, limit: int = 12) -> str:
    lines = []
    for segment in (doc.get("segments") or [])[:limit]:
        speaker = segment.get("speaker")
        text = (segment.get("text") or "").strip()
        if not text:
            continue
        if speaker:
            lines.append(f"- {speaker}: {text}")
        else:
            lines.append(f"- {text}")
    if not lines:
        return "- （无摘录）"
    return "\n".join(lines)


def fill_template(template_body: str, values: dict[str, str]) -> str:
    result = template_body
    for key, value in values.items():
        result = result.replace("{{" + key + "}}", value)
    # Any leftover placeholders stay visible rather than inventing content.
    result = re.sub(r"\{\{[a-zA-Z0-9_]+\}\}", UNCONFIRMED, result)
    return result


def fingerprint_file(path: Path) -> str:
    digest = hashlib.sha256()
    digest.update(path.read_bytes())
    return digest.hexdigest()


def generate(
    input_path: str | Path,
    *,
    template: str | None = None,
    timezone_name: str = "Asia/Shanghai",
    generated_at: datetime | None = None,
) -> Path:
    loaded = load_transcript(input_path, require_complete=True)
    meeting_dir = Path(loaded.meeting_dir).resolve()
    source_paths = []
    for name in ("transcript.json", "transcript.md"):
        candidate = meeting_dir / name
        if candidate.exists():
            source_paths.append(candidate)
    before = {str(p): fingerprint_file(p) for p in source_paths}

    voice_root = find_voice_context_root(meeting_dir)
    template_path = resolve_template(meeting_dir, template, voice_root)
    slug = template_slug_from_path(template_path)
    tz = ZoneInfo(timezone_name)
    stamp = generated_at.astimezone(tz) if generated_at else datetime.now(tz)
    stamp_name = stamp.strftime("%Y-%m-%d_%H-%M-%S")
    generated_at_text = stamp.isoformat(timespec="seconds")

    doc = loaded.document
    values = {
        "title": str(doc.get("title") or "未命名会议"),
        "recording_id": loaded.recording_id,
        "revision": str(loaded.revision),
        "template_slug": slug,
        "generated_at": generated_at_text,
        "started_at": str(doc.get("started_at") or ""),
        "ended_at": str(doc.get("ended_at") or ""),
        "timezone": str(doc.get("timezone") or timezone_name),
        "language": str(doc.get("language") or ""),
        "tags": ", ".join(doc.get("tags") or []) or "（无）",
        "speakers_section": speaker_lines(doc),
        "summary_section": UNCONFIRMED,
        "discussion_section": UNCONFIRMED,
        "decisions_section": UNCONFIRMED,
        "actions_section": UNCONFIRMED,
        "open_questions_section": UNCONFIRMED,
        "excerpts_section": excerpt_lines(doc),
    }

    body = extract_template_body(template_path.read_text(encoding="utf-8"))
    rendered = fill_template(body, values)
    # Provenance header prepended so consumers can verify source revision.
    header = "\n".join(
        [
            "---",
            "schema: voice-context/meeting-minutes@1",
            f"source_recording_id: {loaded.recording_id}",
            f"source_revision: {loaded.revision}",
            f"source_kind: {loaded.source_kind}",
            f"template_slug: {slug}",
            f"generated_at: {generated_at_text}",
            "---",
            "",
        ]
    )
    output_dir = meeting_dir / "generated" / slug
    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / f"{stamp_name}.md"
    output_path.write_text(header + rendered, encoding="utf-8")

    after = {str(p): fingerprint_file(p) for p in source_paths}
    if before != after:
        raise LoadError("source transcript files changed during generation")
    return output_path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", help="Meeting directory, transcript.json, or transcript.md")
    parser.add_argument("--template", help="Template path or slug under VoiceContext/Templates")
    parser.add_argument("--timezone", default="Asia/Shanghai")
    args = parser.parse_args(argv)
    try:
        output = generate(args.path, template=args.template, timezone_name=args.timezone)
    except LoadError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
