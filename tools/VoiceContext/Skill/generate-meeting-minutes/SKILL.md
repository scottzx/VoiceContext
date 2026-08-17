---
name: generate-meeting-minutes
description: Generate meeting minutes from a complete VoiceContext meeting transcript into generated/template-slug/timestamp.md using a user or default template. Use whenever the user asks for 会议纪要, meeting minutes, summarize a VoiceContext meeting folder, process transcript.json/transcript.md from iCloud Drive/VoiceContext/Meetings, or run generate-meeting-minutes. Prefer JSON when both exist, stop if state is not complete, never modify source transcripts, and never upgrade suspected speakers to confirmed.
compatibility: Python 3.10+; reads local VoiceContext meeting directories and Templates/
metadata:
  short-description: VoiceContext meeting minutes from complete transcripts
---

# generate-meeting-minutes

Turn one complete VoiceContext meeting transcript into a derived minutes file. Original `transcript.json` / `transcript.md` stay read-only.

## When this applies

- Input is a meeting directory, `transcript.json`, or `transcript.md`
- Document `kind` is `meeting` and `state` is `complete`
- Output belongs under that meeting's `generated/` directory

Do not use this skill for daily timeline search, non-meeting recordings, or rewriting source transcripts.

## Quick start

1. Resolve the input path the user gave (directory / JSON / Markdown).
2. Run the loader to validate schema/state/revision before drafting:

```bash
python3 scripts/load_transcript.py /path/to/meeting-or-transcript
```

3. Choose a template:
   - user-specified path or slug under `VoiceContext/Templates/`
   - otherwise `Templates/default-meeting-minutes.md`
4. Generate the deterministic provenance stub (safe, no invented decisions):

```bash
python3 scripts/generate_minutes.py /path/to/meeting --template default-meeting-minutes
```

5. Fill summary / decisions / actions only from evidence in the transcript. Leave sections empty or mark them unconfirmed when the transcript does not support them.
6. Keep the output path returned by the script: `generated/<template-slug>/<YYYY-MM-DD_HH-mm-ss>.md`.

## Hard rules

Read `references/generation-rules.md` and `references/transcript-schema.md` before writing minutes.

- Prefer `transcript.json` when JSON and Markdown both exist.
- Stop immediately when `state != complete`.
- Never modify source JSON/Markdown.
- Never rewrite `疑似…` speakers as confirmed.
- Never invent attendees, decisions, owners, or deadlines.
- Always record source `recording_id`, `revision`, template slug, and `generated_at` in the output.

## Validation

From this skill directory:

```bash
python3 scripts/quick_validate.py
python3 scripts/e2e_validate.py
```

`quick_validate` checks SKILL frontmatter, fixture loading (directory / JSON / Markdown), non-complete failure, and source-file immutability. `e2e_validate` generates with default + custom templates, asserts suspected speakers are not upgraded, and checks source id/revision plus separation from transcript sources.

Mac Codex install / export steps: `docs/features/generate-meeting-minutes-skill.md`.

## Layout

```text
VoiceContext/
├── Templates/default-meeting-minutes.md
└── Skill/generate-meeting-minutes/
    ├── SKILL.md
    ├── agents/openai.yaml
    ├── scripts/
    ├── references/
    └── fixtures/
```
