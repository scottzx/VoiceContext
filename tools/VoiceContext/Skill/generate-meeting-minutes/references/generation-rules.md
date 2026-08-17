# Generation rules

## Hard stops

- Stop if `schema` is not `voice-context/transcript@1`.
- Stop if `kind` is not `meeting`.
- Stop if `state` is not `complete`. Explain that transcription is still unfinished.
- Never modify `transcript.json` or `transcript.md`.
- Never write outside the meeting directory's `generated/` folder.

## Speaker fidelity

- Preserve `suspected` vs confirmed wording from the source.
- Do not rewrite `疑似X` as confirmed `X`.
- Do not invent attendees, decisions, owners, or deadlines absent from the transcript.

## Output path

Write exactly:

```text
generated/<template-slug>/<YYYY-MM-DD_HH-mm-ss>.md
```

Timestamp uses the generation local/time-zone stamp chosen by the script (Asia/Shanghai by default for this product). Include provenance in the output:

- source `recording_id`
- source `revision`
- `template_slug`
- `generated_at`

## Template selection

1. Prefer an explicit template path or slug from the user.
2. Otherwise use `VoiceContext/Templates/default-meeting-minutes.md` next to the Skill install root, or climb from the meeting directory to find `Templates/`.
3. Template slug defaults to the template file stem.
