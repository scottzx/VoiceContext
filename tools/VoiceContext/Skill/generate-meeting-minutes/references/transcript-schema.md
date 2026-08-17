# voice-context/transcript@1

Authoritative public transcript contract for generate-meeting-minutes.

## Required top-level fields

| Field | Type | Notes |
|---|---|---|
| `schema` | string | Must be `voice-context/transcript@1` |
| `recording_id` | UUID string | Source recording identity |
| `kind` | string | Skill accepts only `meeting` |
| `state` | string | Skill accepts only `complete` |
| `revision` | integer | Monotonic; recorded in generated minutes |
| `title` | string or null | Meeting title |
| `tags` | string[] | Optional labels |
| `started_at` / `ended_at` | RFC3339 | Millisecond precision allowed |
| `timezone` | string | e.g. `Asia/Shanghai` |
| `language` | string | e.g. `zh` |
| `audio` | object | `local_only`, `available_on_this_device`, `retention` |
| `speakers` | string[] | Meeting-local roster labels |
| `speaker_turns` | object[] | Optional offline turns |
| `segments` | object[] | Ordered transcript units |
| `speech_spans` / `gaps` | arrays | May be empty |

## Segment fields

`id`, `sequence`, `started_at`, `offset_milliseconds`, `text`, `start_sample`, `end_sample`, `source_ranges` (preferred), optional dual-written `source_chunk_id`, `speech_span_ids`.

## Markdown companion

`transcript.md` uses YAML frontmatter for schema/recording_id/revision/kind/state/title/tags/times/language. Body lines may include speaker labels such as `张三（已确认）` or `疑似李四`.

## Loading priority

1. Meeting directory containing `transcript.json` and/or `transcript.md`
2. Direct `transcript.json` path
3. Direct `transcript.md` path

When both JSON and Markdown exist, JSON wins.
