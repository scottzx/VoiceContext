# Design System — 一芥伙伴 / Yima

> Status: approved source of truth  
> Approved by: Human product owner  
> Date: 2026-08-03  
> Reference direction: Apple Voice Memos-style native recording utility

This file is the project-wide source of truth for visual and interaction design. Screen-specific documents may add implementation detail, but they must not contradict this file. Any departure requires explicit product-owner approval and a dated entry in the decision log below.

Cross-page implementation guide: [Unified interface language and tokens](docs/design/interface-language.md) (2026-10-02) maps this approved direction to shared typography roles, spacing, component contracts, and a staged migration for Chat, Meetings, and Tasks. It includes the current implementation audit and pending work; it does not imply that the code or runtime acceptance is complete.

Calendar and reminder ownership update (2026-10-06, explicit product-owner request): [Yima-owned calendar, reminders, and meeting links](docs/design/yima-owned-calendar-reminders.md) replaces the system-only source restriction for Yima items. The local-first scope and one calendar event per meeting are confirmed; synchronization direction and implementation details remain under review.

Calendar and reminder navigation update (2026-10-12, explicit product-owner approval): [Entry and settings consolidation](docs/design/yima-owned-calendar-reminders.md#12-入口与设置收拢2026-10-12) keeps only 待办 and 日程 in creation, treats meetings as a schedule type, moves system integration into Settings, and limits filters to display choices. Reuse the approved native style; this change does not implement system synchronization.

## Product Context

- **Name:** 一芥伙伴 (Chinese), Yima (English).
- **Positioning:** Your personal assistant on your phone — Personal Agent.
- **What this is:** An iPhone personal agent combining chat, reliable recording, meetings, Yima-owned calendar and reminders with optional system integration, shell, Skills, and browser tools. Recordings capture personal thoughts and conversations; each meeting has one calendar event and can link recording evidence. Open Markdown/JSON context connects them with chat and agent execution. Recording reliability remains the priority.
- **Who it is for:** Privacy-conscious Apple users who value reliable recording, local processing, open documents, and free speech-to-text with models downloaded when needed.
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
6. **Personal and professional share one language.** Personal recordings and meeting evidence use the same Recording hierarchy and visual language. A meeting also has its own calendar event, shown consistently in Meetings and Reminders.
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
| `vc.warningText` | `#8A4B00` | `#FFB340` | Small warning/status text; use the base warning color for indicators |
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
- Blue is limited to system settings, permissions, external/system links, and the explicitly approved assistant-speaking edge below (2026-10-12). In-app navigation remains monochrome.
- Never use purple/violet tokens, decorative gradients, gradient buttons, or decorative colored glows. The approved recording-edge exception below is a functional recording state only.
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
- **Integration navigation (approved 2026-09-29, label updated 2026-10-04, source scope updated 2026-10-06):** Four tabs in order: 聊天, 会议, 提醒, 拓展. Chat reuses the full phone agent capabilities; Meetings hosts meeting context and the recording workspace; Reminders shows Yima-owned items and authorized system Reminders/Calendar sources; Extensions contains 我的 and settings. See `docs/design/personal-agent-integration.md` for integration history and `docs/design/yima-owned-calendar-reminders.md` for the current source scope.
- **Yima lists and meeting events (approved 2026-10-06):** Provide Yima日历 and Yima待办 as local sources even when system access is denied. Optional system integration binds dedicated system lists; display the bound source and items once in the app. Each meeting has one Yima event, reachable from both Meetings and the schedule area in Reminders; action tasks remain separate. Unknown dates stay in an unscheduled area. Keep local creation/editing available independently of EventKit permission. Local rows use native Forms; EventKitUI remains for system objects. Preserve flat rows, shared filters, and the approved calendar dots. Synchronization direction is pending user feedback.
- **Creation, settings, and filters (approved 2026-10-12):** Creation offers only 待办 and 日程. New schedules choose 普通日程 or 会议 inside the native Form; existing schedules and meetings keep their type. New tasks choose 保存到: Yima待办 or iPhone提醒事项 inside the Form, with the system option available only when reminder access and a writable list are available. Preserve each destination's existing notification capabilities. Manage system calendar/reminder access at 设置 → 日历与待办; Extensions retains one Settings entry and no separate calendar/reminder tile. Shared filters control visible sources and completed tasks only. This approval covers information architecture and native controls without requiring another prototype; system synchronization remains unimplemented.
- **Shared tab layout and preferences (2026-09-29):** Match Chat and Meetings with inline navigation titles, flat lists, system canvas backgrounds, and neutral navigation icons on Tasks and Extensions. Extensions offers one Settings entry; language and appearance are app-wide. Recording-specific preferences remain a subsection. Do not show an Agent-list shortcut in Extensions.
- **Tab visibility (2026-10-03):** Show the main tab bar only on the four root pages. Hide it on all secondary and deeper pages, including recording details and tools; restore it with the return transition. Keep recording and playback controls available in their own pages. Sheets use native modal presentation.
- **Task rows and date navigation (2026-10-04):** Calendar events share reminder row typography, source placement, leading icon width, and spacing. Their date is on the left and time range or All Day on the right of one metadata row; location is plain text without an icon. All Items groups visible items by date; tapping a date opens native year/month/day wheels that offer only populated dates under the current source/completion filters. Undated reminders remain in an Unscheduled section. Date selection jumps within the list.
- **Shared reminder filters (2026-10-04):** The Reminders home and All Items share persisted calendar/reminder source selection and completed-reminder visibility. Both offer a filter entry. Home rows, counts, overdue summary, and calendar dots respect selected sources; completed reminders never produce unfinished-reminder dots. Changes persist immediately across navigation and app reopening.
- **Reminder date metadata (2026-10-04):** Reminder rows on Home and All Items show only the due date/time. Do not display notification dates or a bell row. Keep notification settings available in the reminder editor and preserve the existing system alarms.
- **EventKitUI integration (2026-10-04):** Restore the custom month/week calendar from d8344f2, including collapse, filtered red/green dots and the top Today action. Do not use UICalendarView. Use EventKitUI only for event details/editing and separate multi-selection calendar/reminder source choosers. Done saves the shared source selection; Cancel keeps it unchanged. Closing native sheets refreshes the existing unified lists and date markers.
- **Chat and Extensions navigation (approved 2026-10-02):** Keep search visible above the conversation list and New Conversation in the upper-right corner. Move the list's global settings and terminal/browser menus to Extensions. Group Skills, models and services/model groups/global usage, assistant configuration, memory, tool connections (MCP/hardware), terminal and its runtime environment (Rootfs/environment variables), and browser in Extensions. The browser page offers Open Browser and Browser Settings using the same global browser pool. Extensions keeps one unified Settings entry for general, chat, recording, data, privacy/permissions, diagnostics, and about. Keep the current conversation's model, files, tools, context, and usage inside the conversation. Preserve the separate conversation browser-tab pool and global browser pool. Reuse the existing native monochrome list style; add no tab or Agent-list shortcut. This approval confirms navigation scope, not runtime acceptance.
- **Extensions grid and custom functions (2026-10-09, explicit product-owner request):** Present Extensions entries as four square icons per row with names below. Place 自定义功能 first, followed by the existing sections and entries in their current order. Use neutral grouped surfaces, system typography, and 12 pt control corners; uploaded product logos retain their own colors. Users add a name, HTTP/HTTPS URL, and optional photo/file logo. Without a logo, show the first character or initial. Long-press a custom entry to open a native adjustment list for persistent sorting and deletion. Forms and confirmation dialogs remain native. See `docs/design/custom-extensions.md` for data, navigation, and verification details. This supersedes the flat-list requirement for the Extensions root only.
- **Custom function browser presentation (2026-10-09, explicit product-owner request):** Open a custom function as a full-screen single web page with its name and one native Return action. Hide browser tabs, the address bar, browser history controls, and the app tab bar. Return exits the page directly. New-window links stay on that page; closing it releases the temporary browser page. Preserve native loading errors, retry, and recording priority.
- **App voice mode (2026-10-17, explicit product-owner request):** Enable independent voice mode from Extensions. It is mutually exclusive with recording: an unfinished recording, including a paused one, blocks activation and prompts the user to finish it first. Do not create a separate Xiaolan home, frontend, or full-screen navigation shell. Voice commands navigate directly through the app's existing tabs, pages, and text/image/chart/HTML previews; retain their normal tab visibility and return behavior. Use native toolbar/menu controls, without a persistent bottom voice dock. See [voice mode design](docs/design/xiaolan-fullscreen.md); this approval establishes scope and does not confirm implementation.
- **Persistent voice capsule (2026-10-17, later explicit product-owner choice):** Replace repeated voice toolbar controls with one App-only monochrome floating capsule showing a microphone and short truthful status. It persists across tabs, detail pages and native content presentations while voice mode is enabled or paused. Default to the right side clear of navigation/input; allow dragging and left/right edge tuck with a visible restore handle. Tucking changes only presentation, never microphone state. Retain 44 pt targets, native menus, system text and semantic surfaces, 12 pt corners, Dynamic Type, VoiceOver position/expand actions and Reduce Motion. Keep transparent areas interactive for underlying content, avoid the keyboard, and hide during app lock/background/privacy prompts. Entry remains Extensions; no new Xiaolan frontend or bottom dock. This supersedes the toolbar-only choice above; see [interaction update](docs/design/xiaolan-fullscreen.md#12-常驻胶囊与即时应答2026-10-17).
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

### Global recording state

- Outside the recorder, replace the global top recording bar with a faint system-red edge while the microphone is recording (2026-10-12, explicit product-owner request). Human speech lightly animates red; the assistant's actual TTS playback uses system blue. Synthesis, task execution, and the short wake cue do not count as assistant speech. The edge overlays no content controls, consumes no layout space, and ignores touches.
- Use native SwiftUI shapes and short easing. A little extra brightness and width follows the existing microphone level for red, and the actual audio player's output level for blue, sampled at most ten times per second. During assistant playback, microphone echo does not drive the edge. No invented idle pulse, multicolor gradient, or private Apple Intelligence effect.
- Keep a native recording menu in page headers with a truthful SF Symbol, accessible status, elapsed time, transcript backlog, Return to Current Recording, and Stop Recording. The assistant dialogue sheet also retains this control.
- Paused, interrupted, and safely stopping sessions have their own symbol and wording and no active recording edge. With Reduce Motion, the recording edge remains static. Existing recorder screens keep their recording controls.

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
- VoiceOver order on the records screen: navigation and recording menu, date selection, Recording list, fixed recording control.
- VoiceOver order in details: title, player, transcript, metadata/actions.
- Announce meaningful state transitions politely; stopping uses clear destructive semantics.
- Use readable elapsed-time accessibility values such as `12 分 48 秒`, not digit-by-digit timer noise.

## Prohibited Patterns

- Purple/violet brand systems or gradients.
- Orange gradient recording buttons.
- Decorative colored shadows or glows, except the explicitly approved semantic recording edge above.
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
| 2026-10-03 | Hide the main tab bar on all secondary and deeper pages | Explicit product-owner request; keep root navigation separate from recording and playback controls |
| 2026-10-04 | Unify reminder/event rows and add populated-date jumping in All Items | Explicit product-owner request; extend the existing reminder style and meeting date-jump interaction |
| 2026-10-04 | Rename the tab to 提醒 and share saved filters with its home page | Explicit product-owner request; retain existing persisted source identifiers and apply the same choices to both pages |
| 2026-10-04 | Reset to d8344f2 and integrate EventKitUI without the official month calendar | Explicit product-owner request; retain the established custom month/week calendar and saved filters, while using native event editing and source selection |
| 2026-10-02 | Consolidate Chat, Meetings, and Tasks with shared semantic typography, spacing, colors, and 44 pt targets | Explicit product-owner approval of the cross-page token guide; preserve existing font preferences and each content type's structure |
| 2026-10-02 | Move global settings and terminal/browser navigation from the chat list to Extensions; keep conversation controls in the conversation | Explicit product-owner confirmation; make Chat focus on search, creating, and managing conversations while Extensions provides grouped capabilities and one Settings entry |
| 2026-10-06 | Add Yima-owned calendar and reminder lists, optional system integration, and one event per meeting visible in Meetings and Reminders | Explicit product-owner request; basic use must work without system access. Supersedes the 2026-09-29 system-only authority rule for Yima-owned items; synchronization direction remains pending |
| 2026-10-09 | Remove in-app purchases and make speech-to-text free; distribute models through user-initiated downloads after installation | Explicit product-owner request; implementation is pending. See docs/design/free-transcription-model-download.md; retain the existing visual system |
| 2026-10-09 | Use a four-column Extensions grid and place configurable local/LAN/Tailscale product shortcuts at the top | Explicit product-owner request; retain existing section order, neutral surfaces, and native add/adjust flows. See docs/design/custom-extensions.md |
| 2026-10-09 | Open custom functions as full-screen single web pages, with Return closing the page | Explicit product-owner request; hide browser tabs and controls, preserve native errors and recording priority |
| 2026-10-12 | Replace the global recording banner with a subtle red recording/human-speech edge, blue assistant-speech edge, and native header controls | Explicit product-owner request after the banner overlapped the assistant conversation, with later clarification of red for human speech and blue for assistant answers. Scoped exception to the no-glow and blue-color restrictions; preserve truthful actual playback, Stop/Return actions, Reduce Motion, and unobstructed content |
| 2026-10-12 | Keep 待办 and 日程 as the two creation choices, put meeting type and task destination in their Forms, move system integration to 设置 → 日历与待办, and limit filters to display choices | Explicit product-owner approval of the consolidation plan; reuse approved native Forms, navigation and list style without an additional prototype. Preserve existing types and notification capabilities; no system synchronization in this change |
| 2026-10-17 | Enable independent voice mode from 拓展, require unfinished recording to end first, and navigate directly in the existing app | Explicit product-owner correction: voice and recording are mutually exclusive; no separate Xiaolan frontend or full-screen shell. Text, image, chart and HTML use app content previews; implementation remains pending |
| 2026-10-17 | Use one draggable monochrome voice capsule with edge tuck across App pages | Product owner explicitly selected microphone plus brief status. Supersedes repeated toolbar controls; native style, recording mutual exclusion and App-only scope remain. |
