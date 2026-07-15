# Design System: Studio Recorder

## 1. Visual Theme & Atmosphere

Studio Recorder is a focused native macOS production desk: calm charcoal surfaces, one warm signal color, precise technical typography, and the media itself occupying most of the window. It should feel closer to a compact field recorder and Final Cut inspection panel than to a SaaS dashboard.

- **Density:** 7/10, cockpit-dense but readable. Controls are compact; the preview and timeline remain spacious.
- **Variance:** 4/10. The shell is intentionally predictable and native, while project rows and the editor use unequal columns instead of card grids.
- **Motion:** 4/10. State transitions are clear and physical; only live meters, the recording indicator, and playhead move perpetually.
- **Canonical canvas:** 1440 × 900 px macOS window; functional minimum 1080 × 700 px.
- **Core principle:** the current task dominates. Setup shows sources, recording shows health, editing shows timeline and inspector. Do not show all controls in every state.

## 2. Color Palette & Roles

The dark palette is primary because it keeps attention on the recorded image. Light mode is designed separately and retains the same semantic hierarchy.

### Dark appearance

- **Night Canvas** (`#18191B`) — application background and title-bar base.
- **Stage Depth** (`#111214`) — preview surround; never use pure black.
- **Panel Charcoal** (`#222326`) — sidebar and inspector surfaces.
- **Raised Graphite** (`#2B2C30`) — controls, source rows, timeline tracks.
- **Chalk Text** (`#F2F0EB`) — primary labels and titles.
- **Muted Alloy** (`#A7A49F`) — descriptions, metadata, secondary labels.
- **Quiet Steel** (`#77777C`) — disabled and tertiary text.
- **Whisper Line** (`rgba(255,255,255,0.09)`) — 0.5–1 px structural separators.
- **Signal Coral** (`#E6675B`) — the only accent: record, selected state, focus, current playhead, and primary action.
- **Capture Healthy** (`#62B982`) — semantic success and healthy source state only; never decorative.
- **Capture Warning** (`#D5A44E`) — semantic permission, disk, or source warning only.

### Light appearance

- **Warm Canvas** (`#F1EFEA`) — application background.
- **Paper Stage** (`#FBFAF7`) — media and content surface.
- **Fog Panel** (`#E8E5DE`) — sidebar and inspector surfaces.
- **Soft Control** (`#DEDBD4`) — compact control backgrounds.
- **Ink Text** (`#242427`) — primary labels and titles.
- **Muted Graphite** (`#68676B`) — descriptions and metadata.
- **Quiet Silver** (`#99979A`) — disabled labels.
- **Whisper Line Light** (`rgba(36,36,39,0.11)`) — structural separators.
- **Signal Coral Light** (`#D9574D`) — same single accent, darkened for contrast.

No purple, blue neon, multicolor gradient, or large accent-filled panel is permitted. Semantic green and amber communicate health only and are not secondary brand accents.

## 3. Typography Rules

- **Display:** SF Pro Display, with Geist fallback in Google Stitch. Use 22–26 px, semibold, tracking `-0.02em`.
- **Body:** SF Pro Text, with Geist fallback. Use 13 px / 18 px for standard application copy.
- **Control:** SF Pro Text Medium, 12–13 px. Labels are sentence case, never all-caps navigation.
- **Mono:** SF Mono, with Geist Mono fallback. Use for timers, frame rates, timecodes, storage estimates, and track metadata.
- **Maximum line length:** 65 characters for explanatory copy.
- **Banned:** Inter, serif fonts, giant marketing headlines, extra-light body text, and using size alone to create hierarchy.

SF Pro is intentional here: this is a native macOS tool, not a branded marketing site. If Stitch cannot resolve SF Pro, use Geist while preserving the scale and weights.

## 4. Component Stylings

### Window shell

- 10 px outer radius with a 0.5 px highlight and layered macOS shadow.
- 52 px draggable title bar. Traffic lights are integrated at the top-left.
- 216 px sidebar for Projects and Studio. Recovery appears only when an interrupted project exists.
- 304 px inspector for source, layout, and project controls.
- Sidebars and title bars may use `saturate(180%) blur(20px)`; the main content and preview remain opaque.

### Preview stage

- Always the largest single region in Studio and Editor.
- 16:9 program frame inside a darker stage surround.
- Source labels use small glass pills at the edges, never centered overlays.
- Recording adds a 1 px Signal Coral inner edge and a compact `REC` indicator; no flashing full-frame border.
- Camera is a 16:9 rounded rectangle with 10–12 px radius, placed inside the safe area.

### Buttons

- Default controls are 28–30 px high with 6 px radius.
- Primary actions are 34 px high. The record/stop control may be 44 px high because it is the central physical action.
- Signal Coral fill is reserved for recording and the current primary action.
- Secondary actions use raised graphite or transparent backgrounds with a whisper border.
- Active press translates down 1 px and reduces brightness; no outer glow.
- Every primary action shows its shortcut when space allows.

### Source rows

- 44–52 px high, separated by negative space or 0.5 px lines rather than individual cards.
- Leading monoline source icon; title and device detail; trailing status, level, or toggle.
- Live audio rows show a restrained six-segment meter. Display rows show resolution and frame-rate contract.
- Unsupported features show `Next slice`; do not render them as enabled controls.

### Project rows

- Use editorial rows with unequal thumbnail and metadata columns.
- Preview image ratio is 16:9 with 8 px corners.
- Duration, date, capture profile, and recovery state use monospaced metadata.
- Avoid equal card grids. A single featured recent project may be elevated; the rest are rows.

### Timeline and transcript

- Track heights vary by content: program 46 px, audio 34 px, transcript 30 px.
- The playhead is the accent; clips are neutral graphite with media thumbnails or waveform detail.
- Transcript edits are inline sentence blocks tied to time ranges. Deletions use a subtle strike state, not destructive red fills.

### Empty, loading, and error states

- Loading uses layout-matched skeletons, not circular spinners.
- Empty states contain one clear explanation and one action; hide filters and inspector sections that cannot work yet.
- Permission failures name the missing permission and provide `Open System Settings`.
- Capture failure preserves the project context and routes to Recovery instead of replacing the whole window with an alert.

## 5. Layout Principles

- Use CSS Grid / SwiftUI split layouts. No percentage arithmetic or overlapping content zones.
- **Studio:** sidebar / stage / inspector, with a bottom control deck inside the stage column.
- **Recording:** keep the stage fixed; freeze source selection; replace configuration with source health.
- **Editor:** sidebar / preview-and-timeline / inspector. The timeline owns the bottom 32–40%.
- **Projects:** sidebar / content. Use a featured recent project followed by compact rows.
- **Settings:** separate compact preferences window rather than another destination in the main content hierarchy.
- Below 1180 px wide, the inspector becomes a slide-over panel. The stage never shrinks below a usable 16:9 frame.
- Below 820 px high, metadata collapses before preview or primary controls.
- No horizontal scrolling in any supported window size.

## 6. Motion & Interaction

- Hover and press feedback: 120–150 ms.
- Inspector and recovery panels: 220–260 ms using `cubic-bezier(0.25, 0.46, 0.45, 0.94)`.
- Modal arrival: 260 ms with a restrained spring; no bounce-heavy motion.
- Animate only `transform` and `opacity` where possible.
- The live recording dot breathes gently every 1.8 seconds. Audio meters update continuously but do not shimmer.
- Project rows cascade only on initial load with 35 ms stagger; subsequent updates are immediate.
- Respect Reduce Motion by replacing movement with short opacity changes.
- Keyboard: `⌘R` start/stop, `Space` play/pause in Editor, `⌘E` export, `⌘,` settings, `Esc` dismiss.
- Drag project files out to Finder; accept media drops into Editor when that slice exists.

## 7. Anti-Patterns (Banned)

- No website-like hero area, pricing-card layout, or oversized slogan.
- No three equal cards across the window.
- No pure black, purple/blue neon, gradient text, or glowing buttons.
- No emojis; use SF Symbols or equivalent monoline icons.
- No Inter or serif fonts.
- No permanent Recovery navigation when there is nothing to recover.
- No disabled future feature presented as working.
- No vague labels such as `Enhance`, `Magic`, `AI Edit`, or `Optimize`.
- No fake precision such as `99.99% quality` or round-number performance claims.
- No modal wizard for routine recording setup.
- No full-window error state when the user can recover or retry in context.
- No animation that competes with the recorded content.
