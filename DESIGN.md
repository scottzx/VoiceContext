# Design System — 一芥伙伴 / Yima

> Status: approved source of truth  
> Approved by: Human product owner  
> Date: 2026-08-03  
> Reference direction: Apple Voice Memos-style native recording utility

This file is the project-wide source of truth for visual and interaction design. Screen-specific documents may add implementation detail, but they must not contradict this file. Any departure requires explicit product-owner approval and a dated entry in the decision log below.

## Product Context

- **Name:** 一芥伙伴 (Chinese), Yima (English).
- **Positioning:** Your personal assistant on your phone — Personal Agent.
- **What this is:** An iPhone personal agent combining chat, reliable recording, meetings, system reminders, shell, Skills, and browser tools. It captures a personal thought, a conversation, or a meeting as one `Recording`, then connects open Markdown/JSON context with chat and agent execution. Recording reliability remains the priority.
- **Who it is for:** Privacy-conscious Apple users who value reliable recording, local processing, open documents, and one-time purchase over cloud AI spectacle or subscriptions.
- **Product type:** Native iOS personal assistant (Personal Agent).
- **Core promise:** The user's recording is private, understandable, recoverable, and under their control.
- **Memorable impression:** It feels as simple and trustworthy as an Apple system recording tool.

## Aesthetic Direction

- **Direction:** Quiet native utility.
- **Thesis:** The interface is quiet like a blank sheet of paper until recording begins; then a single red control makes the active state unmistakable.
- **Mood:** Calm, precise, private, durable, and immediately understandable.
- **Decoration level:** Minimal. Typography, spacing, separators, and state transitions provide hierarchy.
- **Reference:** Apple Voice Memos for restraint, list hierarchy, whitespace, and a singular red recording action. Do not copy macOS window chrome or desktop split-view geometry into the iPhone app.

### Design principles

1. **Content before containers.** Recordings, timestamps, transcript text, and controls are the interface. Do not wrap every section in a card.
2. **Color must explain state.** Saturated color indicates recording, warning, success, or an external system link; it is never decoration.
3. **One dominant action.** The red recording control is the only persistent high-saturation visual anchor.
4. **Native before novel.** Prefer familiar iOS navigation, lists, sheets, controls, typography, materials, and haptics.
5. **State must be honest.** Text and iconography must distinguish recording, paused, processing, interrupted, failed, locked, and complete states. Color is never the only signal.
6. **Personal and professional share one language.** A personal thought and a formal meeting use the same Recording hierarchy; metadata changes, not the visual identity.
7. **Whitespace is functional.** Space separates ideas and creates focus. Do not fill empty areas with decorative panels, illustrations, or promotional copy.

## Typography

Using Apple system typography is an explicit product decision, not an unconsidered default.

- **Display and navigation:** San Francisco through SwiftUI semantic styles; PingFang SC is selected automatically for Simplified Chinese.
- **Body and transcript:** San Francisco / PingFang SC through `.body` and Dynamic Type.
- **UI labels:** Same family, normally medium or semibold.
- **Time and duration:** System font with `.monospacedDigit()` so changing timers do not shift horizontally.
- **Code and file paths:** System monospaced font only where a literal path or structured export value is shown.
- **External font loading:** None. The app must work offline and remain visually native.

### Semantic scale

| Role | SwiftUI style | Guidance |
|---|---|---|
| Screen title | `.largeTitle.weight(.bold)` | Use on top-level screens when space permits |
| Recording title | `.title3.weight(.semibold)` or `.headline` | Maximum two lines in lists; unrestricted in detail |
| Section title | `.headline` | Sentence case; do not use decorative all-caps |
| Transcript | `.body` | Comfortable line height; allow Dynamic Type growth |
| Metadata | `.subheadline` | Date, duration, participant count, retention |
| Caption/status | `.caption` | Always paired with clear wording and, when useful, an icon |
| Recording timer | `.system(size: 48, weight: .regular, design: .rounded).monospacedDigit()` | Scale down only when Dynamic Type or width requires it |

Use regular, medium/semibold, and bold intentionally. If most text is bold, hierarchy has failed.

## Color

- **Approach:** Restrained monochrome with semantic accents.
- **Brand color:** None. Identity comes from the red recording control, typography, layout, and behavior.
- **Primary action:** Black in light mode and white in dark mode.
- **Recording action:** System red only.

### Core tokens

| Token | Light | Dark | Usage |
|---|---|---|---|
| `vc.canvas` | `#FFFFFF` | `#000000` | Main page background |
| `vc.surface` | `#FFFFFF` | `#1C1C1E` | Sheets, grouped controls, isolated panels |
| `vc.grouped` | `#F2F2F7` | `#1C1C1E` | Settings groups and secondary regions |
| `vc.elevated` | `#FFFFFF` | `#2C2C2E` | Temporary elevated controls |
| `vc.ink` | `#1C1C1E` | `#F2F2F7` | Primary text and monochrome primary controls |
| `vc.muted` | `#636366` | `#98989D` | Secondary text; maintains AA contrast for small metadata |
| `vc.tertiary` | `#8E8E93` | `#636366` | Disabled and tertiary metadata |
| `vc.line` | `rgba(60,60,67,.18)` | `rgba(84,84,88,.65)` | Hairline separators |
| `vc.recording` | `#FF3B30` | `#FF453A` | Start, active recording, stop, destructive confirmation |
| `vc.recordingText` | `#D70015` | `#FF6961` | Small recording/status text where system red lacks light-mode text contrast |
| `vc.recordingSoft` | `#FFF1F0` | `#3A1513` | Rare recording/error notice background |
| `vc.warning` | `#FF9F0A` | `#FF9F0A` | Processing, suspected identity, attention |
| `vc.warningSoft` | `#FFF7E8` | `#332309` | Warning notice background |
| `vc.success` | `#34C759` | `#30D158` | Confirmed success only |
| `vc.successSoft` | `#EEF9F0` | `#123019` | Success notice background |
| `vc.info` | `#007AFF` | `#0A84FF` | System settings and external/system-link semantics only |
| `vc.infoText` | `#0066CC` | `#409CFF` | Small system/external-link text |
| `vc.infoSoft` | `#EFF6FF` | `#0D2743` | Informational notice background |

### Color discipline

- Red is reserved for recording, stopping, and genuinely destructive actions. It is not a general navigation tint.
- Tasks calendar exception (2026-10-01, explicit product-owner request): a small red dot below a date indicates unfinished due reminders; a small green dot indicates calendar events. Show both when both types are present. Keep date selection monochrome and provide accessible counts/source status; the dot does not imply urgency or a notification.
- Ordinary selected dates and segmented controls use ink/white contrast rather than a brand color.
- Complete records remain neutral by default. Green appears only when confirming a successful action matters, except for the explicitly approved Tasks calendar event dot.
- Processing and suspected identity may use a small orange dot or orange text, never an orange card covering the whole row.
- Blue is limited to system settings, permissions, or external/system links. In-app navigation remains monochrome.
- Never use purple/violet tokens, decorative gradients, gradient buttons, or colored glows.
- Dark mode is a surface redesign, not a mechanical color inversion. Preserve semantic meaning and at least WCAG AA text contrast.

## Spacing

- **Base unit:** 4 pt.
- **Density:** Comfortable-compact, comparable to native Apple utility apps.
- **Scale:** `2xs 2`, `xs 4`, `sm 8`, `md 12`, `lg 16`, `xl 20`, `2xl 24`, `3xl 32`, `4xl 48`, `5xl 64`.
- **Page horizontal inset:** 20 pt by default; 16 pt is allowed for native lists.
- **Recording row:** 64–72 pt minimum depending on metadata and Dynamic Type.
- **Primary button:** 50–52 pt visual height, minimum 44 pt hit target.
- **Recording button:** 60–64 pt visible diameter with a hit target of at least 72 pt.
- **Section separation:** Prefer 24–32 pt whitespace over an additional container.

## Layout

- **Approach:** Grid-disciplined, single-column iPhone layout.
- **Navigation:** `NavigationStack`, native sheets, and value-based destinations.
- **Integration navigation (approved 2026-09-29):** Four tabs in order: 聊天, 会议, 待办事项, 拓展. Chat reuses the full phone agent capabilities; Meetings hosts the recording workspace; Tasks uses system Reminders; Extensions contains 我的 and settings. See `docs/design/personal-agent-integration.md` for confirmed scope and remaining page details.
- **Shared tab layout and preferences (2026-09-29):** Match Chat and Meetings with inline navigation titles, flat lists, system canvas backgrounds, and neutral navigation icons on Tasks and Extensions. Extensions offers one Settings entry; language and appearance are app-wide. Recording-specific preferences remain a subsection. Do not show an Agent-list shortcut in Extensions.
- **Records screen within Meetings:** Large title, restrained calendar strip, flat Recording rows, and a fixed bottom recording control. In the integration version, profile/settings move to Extensions. Recording state and a stop action remain reachable across tabs.
- **Recording details:** Title and metadata, audio player, transcript, then secondary metadata/actions. Audio always precedes transcript.
- **Settings:** Native `List` / `Form` grouping. Do not create a custom card for every setting row.
- **Empty states:** One concise message and the recording control. No decorative illustration is required.
- **Future larger platforms:** A split view may be used on iPad/macOS later, but v1 iPhone navigation must not imitate desktop columns.

### Shape hierarchy

| Role | Radius |
|---|---|
| Flat list row | `0` |
| Small control or field | `10–12` pt |
| Isolated player/control panel | `14–16` pt |
| System sheet | System-provided |
| Recording button/status dot | Circle |
| Status capsule | Full radius, only when the content is truly a compact status label |

Do not apply border, fill, radius, and shadow to the same element by default. Cards are reserved for real grouping or a control surface that must read as one unit.

## Core Components

### Recording list row

- Flat, full-width, and separated by a hairline.
- Title is the first scan target; date, duration, participant count, and state are secondary.
- Personal, conversation, and meeting recordings use the same row component.
- A transcript excerpt may appear as one muted line, but it must not turn the row into a colored personal-note card.
- Processing and attention states use explicit text plus a small semantic indicator.

### Recording control

- An isolated red circle centered in the bottom safe area is the default start control.
- The empty/first-use state may show the visible label `开始录音`; established screens may use the circle alone with a complete accessibility label.
- Starting recording changes the control into an unmistakable active/stop state with haptic feedback.
- No gradient, glow, orange alternative, or oversized promotional dock.

### Global recording bar

- Visible outside the recording screen while capture is active.
- Uses a red dot, status text, elapsed time, backlog truth, and an independently focusable stop action.
- The bar may use a very light red surface, but it must not become a floating promotional card.

### Audio player

- Monochrome controls and track; the current position may use recording red.
- Provides play/pause, 15-second seek controls, speed, elapsed time, and duration.
- Uses one restrained control surface, never a decorative gradient.
- If audio has expired, retain the player's location as a plain explanatory block so transcript continuity is preserved.

### Transcript

- Reads like a document, not a card feed.
- Use time, speaker, text, whitespace, and separators for hierarchy.
- Suspected and confirmed identities must have different text and semantic treatment.
- Editing and navigation affordances must remain at least 44×44 pt even when visually quiet.

### Buttons

- Primary: ink fill with inverse text.
- Secondary: surface/transparent with a thin neutral border or native bordered style.
- Text action: ink for in-app actions; system blue only for genuine system/external links.
- Destructive/recording: system red with explicit wording.
- Disabled: reduced contrast plus an explanation where the reason is not obvious.

## Motion and Haptics

- **Approach:** Minimal-functional.
- **Duration:** micro `80–120 ms`, short `160–240 ms`, medium `240–360 ms`.
- **Easing:** System ease or SwiftUI `snappy` for short state changes; avoid custom theatrical curves.
- The recording circle may morph into a stop shape over 180–240 ms.
- Timer, backlog, and transcript updates must not shift surrounding layout.
- New transcript text may fade in subtly; do not animate word-by-word.
- Start, pause, resume, stop, success, and error should use appropriate native haptic feedback.
- With Reduce Motion, remove pulsing, waveform travel, and positional motion while preserving text and static state indicators.

## Accessibility

- Every interactive target is at least 44×44 pt.
- Support Dynamic Type through at least `.accessibility3`; rows grow vertically and metadata wraps.
- Color never carries state alone. Pair it with wording and, when useful, an SF Symbol.
- VoiceOver order on the records screen: navigation, active recording bar, date selection, Recording list, fixed recording control.
- VoiceOver order in details: title, player, transcript, metadata/actions.
- Announce meaningful state transitions politely; stopping uses clear destructive semantics.
- Use readable elapsed-time accessibility values such as `12 分 48 秒`, not digit-by-digit timer noise.

## Prohibited Patterns

- Purple/violet brand systems or gradients.
- Orange gradient recording buttons.
- Colored shadows or glows.
- A rounded card around every list row or content section.
- Colored icon tiles for every setting.
- Decorative status pills for ordinary complete states.
- Centering every screen or filling blank space with illustration.
- Claiming processing is complete before the underlying state is complete.
- Copying macOS window controls, two-column geometry, or traffic-light decoration into the iPhone UI.

## Safe Choices and Deliberate Risks

### Safe choices

- Native type, navigation, list patterns, and controls reduce learning cost.
- Red recording semantics match established user expectations.
- Flat Recording rows improve scanning and scale to long histories.
- Monochrome layout keeps private content visually dominant.

### Deliberate risks

- **No traditional brand color:** improves durability and calm, but screenshots rely on layout and the red recording control for recognition.
- **Fewer cards:** produces a more native, content-first interface, but demands precise typography and spacing.
- **Compact recording control:** creates a memorable and disciplined anchor, but first-use screens must supply a visible label and accessibility explanation.

## Decisions Log

| Date | Decision | Rationale |
|---|---|---|
| 2026-08-03 | Adopt quiet Apple-native recording-tool direction | Explicit product-owner choice based on an Apple Voice Memos reference |
| 2026-08-03 | Use black, white, and gray as the dominant palette | Makes content, privacy, and control feel primary rather than AI branding |
| 2026-08-03 | Reserve saturated color for local semantic emphasis | The red recording control becomes the stable visual anchor; other colors explain state only |
| 2026-08-03 | Replace card-heavy Recording presentation with flat list rows | Improves scan speed and removes generic AI-note visual language |
| 2026-08-03 | Keep system typography | Reinforces platform-native behavior, offline reliability, Dynamic Type, and Chinese support |
| 2026-09-29 | Evolve VoiceContext into a personal agent with 聊天 / 会议 / 待办事项 / 拓展 tabs; move 我的 and settings to 拓展 | Explicit product-owner decision; retain VoiceContext identity and recording priority while using the complete phone agent framework |
| 2026-09-29 | Use system Reminders as the Tasks source of truth | Explicit product-owner choice; the app and agent manage the same reminders without a parallel task database |
| 2026-09-29 | Rename the product to 一芥伙伴 / Yima, positioned as a personal assistant on the phone (Personal Agent) | Explicit product-owner decision; retain Bundle IDs, data paths, recording reliability, and the existing visual system |
| 2026-10-01 | Use red reminder dots and green event dots in the Tasks calendar | Explicit product-owner clarification: show both dots when both types occur; retain monochrome selection and accessible text |
