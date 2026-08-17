#!/usr/bin/env python3
"""Deterministic VoiceContext transcript loader for generate-meeting-minutes."""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

SCHEMA = "voice-context/transcript@1"
JSON_NAME = "transcript.json"
MD_NAME = "transcript.md"


class LoadError(Exception):
    """Raised when a transcript cannot be accepted by the skill."""


@dataclass
class LoadedTranscript:
    source_path: str
    source_kind: str  # json | markdown
    meeting_dir: str
    document: dict[str, Any]

    @property
    def recording_id(self) -> str:
        return str(self.document.get("recording_id", ""))

    @property
    def revision(self) -> int:
        return int(self.document.get("revision", 0))

    @property
    def state(self) -> str:
        return str(self.document.get("state", ""))

    @property
    def kind(self) -> str:
        return str(self.document.get("kind", ""))


def _strip_quotes(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        return value[1:-1]
    return value


def _parse_yaml_scalar(value: str) -> Any:
    value = value.strip()
    if value == "" or value.lower() in {"null", "~"}:
        return None
    if value.startswith("[") and value.endswith("]"):
        inner = value[1:-1].strip()
        if not inner:
            return []
        parts = [p.strip() for p in inner.split(",")]
        return [_strip_quotes(p) for p in parts if p]
    if re.fullmatch(r"-?\d+", value):
        return int(value)
    if value.lower() in {"true", "false"}:
        return value.lower() == "true"
    return _strip_quotes(value)


def parse_markdown_transcript(text: str) -> dict[str, Any]:
    if not text.startswith("---"):
        raise LoadError("transcript.md missing YAML frontmatter")
    match = re.match(r"^---\n(.*?)\n---\n?(.*)$", text, re.DOTALL)
    if not match:
        raise LoadError("transcript.md has invalid YAML frontmatter")
    frontmatter_text, body = match.group(1), match.group(2)
    doc: dict[str, Any] = {
        "segments": [],
        "speakers": [],
        "tags": [],
        "speech_spans": [],
        "gaps": [],
        "speaker_turns": [],
    }
    for raw_line in frontmatter_text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or ":" not in line:
            continue
        key, value = line.split(":", 1)
        doc[key.strip()] = _parse_yaml_scalar(value)

    # Body blocks: optional "[time · offset] speaker" header then text lines.
    header_re = re.compile(r"^\[(?P<clock>[^\]]+?)\](?:\s+(?P<speaker>.+))?\s*$")
    current_speaker = None
    current_text: list[str] = []
    sequence = 0

    def flush() -> None:
        nonlocal sequence, current_speaker, current_text
        if not current_text and current_speaker is None:
            return
        sequence += 1
        text_joined = "\n".join(current_text).strip()
        doc["segments"].append(
            {
                "sequence": sequence,
                "speaker": current_speaker,
                "text": text_joined,
            }
        )
        if current_speaker:
            # Keep suspected wording intact in the roster snapshot.
            label = current_speaker
            if label not in doc["speakers"]:
                doc["speakers"].append(label)
        current_speaker = None
        current_text = []

    for line in body.splitlines():
        header = header_re.match(line)
        if header:
            flush()
            current_speaker = (header.group("speaker") or "").strip() or None
            continue
        if line.strip() == "":
            if current_text:
                flush()
            continue
        current_text.append(line)
    flush()
    return doc


def resolve_input(path: Path) -> tuple[Path, Path | None, Path | None]:
    """Return (meeting_dir, json_path|None, md_path|None)."""
    path = path.expanduser().resolve()
    if not path.exists():
        raise LoadError(f"path does not exist: {path}")

    if path.is_dir():
        json_path = path / JSON_NAME if (path / JSON_NAME).exists() else None
        md_path = path / MD_NAME if (path / MD_NAME).exists() else None
        if not json_path and not md_path:
            raise LoadError(f"meeting directory lacks {JSON_NAME} or {MD_NAME}: {path}")
        return path, json_path, md_path

    if path.name == JSON_NAME or path.suffix.lower() == ".json":
        meeting_dir = path.parent
        md_path = meeting_dir / MD_NAME if (meeting_dir / MD_NAME).exists() else None
        return meeting_dir, path, md_path

    if path.name == MD_NAME or path.suffix.lower() == ".md":
        meeting_dir = path.parent
        json_path = meeting_dir / JSON_NAME if (meeting_dir / JSON_NAME).exists() else None
        return meeting_dir, json_path, path

    raise LoadError(f"unsupported input path: {path}")


def validate_document(doc: dict[str, Any], *, require_complete: bool = True) -> None:
    schema = doc.get("schema")
    if schema != SCHEMA:
        raise LoadError(f"unsupported schema: {schema!r}; expected {SCHEMA!r}")
    kind = doc.get("kind")
    if kind != "meeting":
        raise LoadError(f"skill only accepts kind=meeting; got {kind!r}")
    state = doc.get("state")
    if require_complete and state != "complete":
        raise LoadError(
            f"state is {state!r}, not complete; transcription still unfinished, stopping"
        )
    if "recording_id" not in doc:
        raise LoadError("missing recording_id")
    if "revision" not in doc:
        raise LoadError("missing revision")
    try:
        int(doc["revision"])
    except (TypeError, ValueError) as exc:
        raise LoadError("revision must be an integer") from exc
    segments = doc.get("segments")
    if not isinstance(segments, list) or not segments:
        raise LoadError("transcript has no segments")


def load_transcript(path: str | Path, *, require_complete: bool = True) -> LoadedTranscript:
    meeting_dir, json_path, md_path = resolve_input(Path(path))
    if json_path is not None:
        try:
            document = json.loads(json_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            raise LoadError(f"invalid JSON: {json_path}: {exc}") from exc
        if not isinstance(document, dict):
            raise LoadError("transcript.json must be an object")
        validate_document(document, require_complete=require_complete)
        return LoadedTranscript(
            source_path=str(json_path),
            source_kind="json",
            meeting_dir=str(meeting_dir),
            document=document,
        )

    assert md_path is not None
    document = parse_markdown_transcript(md_path.read_text(encoding="utf-8"))
    validate_document(document, require_complete=require_complete)
    return LoadedTranscript(
        source_path=str(md_path),
        source_kind="markdown",
        meeting_dir=str(meeting_dir),
        document=document,
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", help="Meeting directory, transcript.json, or transcript.md")
    parser.add_argument(
        "--allow-incomplete",
        action="store_true",
        help="Load without requiring state=complete (debug only)",
    )
    args = parser.parse_args(argv)
    try:
        loaded = load_transcript(args.path, require_complete=not args.allow_incomplete)
    except LoadError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    payload = {
        "source_path": loaded.source_path,
        "source_kind": loaded.source_kind,
        "meeting_dir": loaded.meeting_dir,
        "recording_id": loaded.recording_id,
        "revision": loaded.revision,
        "kind": loaded.kind,
        "state": loaded.state,
        "title": loaded.document.get("title"),
        "segment_count": len(loaded.document.get("segments") or []),
        "speakers": loaded.document.get("speakers") or [],
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
