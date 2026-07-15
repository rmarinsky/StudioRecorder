# Studio Recorder user-needs refresh — 15 July 2026

Baseline inspected: Studio Recorder `53f414d` and the current [README](../../README.md). This refresh starts after scene composition, Follow Cursor/click treatment, camera background removal, 4K canvases, YouTube RTMPS, recovery, stream-health metrics, and range-based GIF export already exist.

## Recommendation

Build the next three slices in this order:

1. **Stream Continuity and Local Safety** — automatic reconnect with an honest state machine, a verified local program archive, preflight, and fault/soak tests.
2. **Record with Intent** — synchronized pause/resume, a manual zoom-at-pointer command, and privacy-safe command-key display, all captured as editable telemetry.
3. **Precision Privacy Edit** — audio waveforms, keyboard/time nudging, and multiple timed blur or solid-redaction regions.

This keeps Studio Recorder a focused native recorder rather than an OBS clone or general NLE. Reliability comes first because a failed live session is unrecoverable; then capture-time intent reduces editing; then a small precision/privacy layer prevents round-tripping to another editor.

## Evidence quality and limits

- Reddit posts and comments below are **first-person qualitative evidence**, not demand-size estimates. Developer launch posts are used only when the comments contain independent user requests or reported problems.
- Official product/help documentation is **capability or operational evidence**. A competitor offering a feature does not by itself prove user value.
- The ranked slices are **product inference**, clearly separated from the evidence.
- Search focused on recent macOS recorder and streaming discussions available on 2026-07-15. The sample over-represents technically confident, price-sensitive users.

## First-person user evidence

| Workflow | What users actually report or request | Evidence |
|---|---|---|
| Manual zoom | Users want both automatic and manual zoom, including a precise target independent of clicks. They notice when cursor and zoom timing diverge by even a second or two. | A March 2026 recorder request lists automatic/manual zoom with key presses and pause ([Reddit](https://www.reddit.com/r/macapps/comments/1rhrcg8/screen_recording_apps_what_are_you_actually_using/)); Recordly feedback asks for pinpoint manual zoom and configurable locked/free masking ([Reddit](https://www.reddit.com/r/macapps/comments/1rsf44t/os_i_made_a_free_opensource_screen_studio/)); Screenize feedback calls cursor/zoom misalignment “awkward” ([Reddit](https://www.reddit.com/r/macapps/comments/1qrzfa8/os_i_built_screenize_an_opensource_alternative_to/)). |
| Keystroke display | Tutorial makers combine a key-overlay utility with a separate hotkey-zoom tool when the recorder does not provide both. Other users explicitly call keystroke overlays important. | A user pairs KeyCastr with TuringShot to get keys plus live hotkey zoom in one recording pass ([Reddit](https://www.reddit.com/r/macapps/comments/1ru9l85/recommendation_for_a_keyboard_screen_recording/)); Screenize feedback explicitly values keystroke overlays ([Reddit](https://www.reddit.com/r/macapps/comments/1qrzfa8/os_i_built_screenize_an_opensource_alternative_to/)). |
| Pause/resume | Users want to stop dead time without ending the project, for example to take a break and continue. The request recurs in otherwise capable recorder threads. | A Flowy user asks to pause for a break rather than stop and start a new recording ([Reddit](https://www.reddit.com/r/macapps/comments/1m48837/regarding_create_screen_recordings_like_this_for/)); the March 2026 requirements thread also lists pause ([Reddit](https://www.reddit.com/r/macapps/comments/1rhrcg8/screen_recording_apps_what_are_you_actually_using/)). |
| Precision editing/waveforms | Users want visible system/mic levels and separate audio control because mismatched volumes are hard to diagnose from a flat timeline. They also complain about imprecise trim/playback handles. | A user says waveform levels would immediately reveal which source is too loud or quiet and asks for separately accessible audio ([Reddit](https://www.reddit.com/r/SideProject/comments/1s79ric/i_built_a_free_opensource_screenshot_screen/)); Recordly feedback in the prior survey reports hard-to-grab trim handles and unreliable precise playback ([Reddit](https://www.reddit.com/r/macapps/comments/1rsf44t/os_i_made_a_free_opensource_screen_studio/)). |
| Privacy/redaction | Users want more than one blur region and distinguish a fixed region from one that follows changing content. “Auto-redact” claims also attract trust questions when their boundary is unclear. | A user says most tools allow only one blur area and calls multiple regions essential ([Reddit](https://www.reddit.com/r/macapps/comments/1rhrcg8/screen_recording_apps_what_are_you_actually_using/)); another asks for both locked and free masking ([Reddit](https://www.reddit.com/r/macapps/comments/1rsf44t/os_i_made_a_free_opensource_screen_studio/)). |
| Stream reliability | Streamers report disconnect/reconnect loops despite apparent bandwidth, settings changes, and long troubleshooting. A recent case was an unsupported codec rather than bandwidth, showing that health counters alone do not identify every failure. | February and March 2026 disconnect reports include repeated reconnects and extensive unsuccessful network/settings changes ([Reddit](https://www.reddit.com/r/obs/comments/1ra810o/obs_disconnecting_and_reconnecting_all_the_time/), [Reddit](https://www.reddit.com/r/obs/comments/1rz3ttx/constant_stream_disconnect_reconnect/)); a July 2026 report describes severe dropped frames with no visible local bottleneck ([Reddit](https://www.reddit.com/r/obs/comments/1useeu1/obs_dropping_frames_with_no_visible_bottlenecks/)). |

## Official capability and operational evidence

- Screen Studio supports an editable manual zoom target and level, independent of click position ([Manual Zoom guide](https://screen.studio/guide/manual-zoom)). Its recording widget can finish, pause, restart, or delete a recording ([recording-control guide](https://screen.studio/guide/managing-recording-in-progress)).
- CleanShot exposes click and keystroke capture, including “all keys” versus “only command keys,” plus screen/camera capture and a basic trim/volume editor ([official feature list](https://cleanshot.com/features?xs=1)). This validates command-only as a comprehensible privacy default; it does not prove that storing every typed character is safe.
- Screen Studio provides a scrubber for locating exact edit points ([Scrubber guide](https://screen.studio/guide/scrubber)) and timed masks for sensitive data ([Mask and Highlight guide](https://screen.studio/guide/adding-a-mask-and-highlight)). Its documented mask cannot follow scrolling content and a mask and highlight cannot coexist in one frame, leaving room for a simpler but more composable multi-region model.
- ScreenFlow displays audio waveforms, clipped peaks, effects, and volume changes directly on the timeline ([official help](https://www.telestream.net/telestream-support/screen-flow/help/Intro.03.2.html)). That is a useful precision baseline without requiring a full audio workstation.
- OBS distinguishes network-dropped frames from rendering/encoding problems and recommends alternate ingest testing, lower bitrate, and optional dynamic bitrate under congestion ([official troubleshooting](https://obsproject.com/kb/stream-connection-troubleshooting)).
- YouTube tells encoders to test representative motion/audio, monitor stream health, use RTMPS, and match bitrate to resolution; 4K30 H.264 is currently recommended at 30 Mbps ([encoder settings](https://support.google.com/youtube/answer/2853702?hl=en-EN)). YouTube also recommends a local archive even though it can archive streams shorter than 12 hours ([archive guidance](https://support.google.com/youtube/answer/6247592?hl=en)).

## Product inference

### 1. Stream Continuity and Local Safety

**Why first:** Studio Recorder now reports composition FPS, latency, drops, canvas, and bitrate, but the README still correctly withholds a release-ready streaming claim because automatic reconnect and long soak tests are absent. Observability without recovery still leaves the user responsible for noticing and fixing a live failure.

Build one explicit state machine: `Preflighting → Connecting → Live → Congested → Reconnecting → Live/Failed → Ended`. The UI must never remain green while output has stopped. Reconnect with bounded exponential backoff, retain the same frozen Scene, and keep writing a verified local program movie through network outages. Conservative bitrate fallback should be opt-in and visibly report quality reduction; it must not masquerade as a fix for encoding or codec errors.

Minimum acceptance bar:

- simulate a 30–60 second network outage and recover without user intervention or duplicate local media;
- preserve a playable local archive even if reconnect ultimately fails;
- identify capture, render/encode, network, and platform-contract failures separately in the UI and journal;
- preflight codec, keyframe interval, canvas/FPS/bitrate, credentials, and rough upload headroom;
- complete horizontal and vertical one-hour soaks, plus a 4K30 soak at YouTube’s current contract, with measured A/V/cursor drift and no false-live state.

### 2. Record with Intent

**Why second:** Pause, manual zoom, and command display are repeatedly requested together by tutorial makers. They also fit Studio Recorder’s existing cursor/click telemetry: capture intent cheaply, then render it non-destructively everywhere.

Add `Pause/Resume` and `Mark Zoom Here` to the recording HUD and shortcuts. A manual zoom event should target the pointer at that frame, create an editable zoom block, and never depend on guessing from clicks. Add a command-key overlay that records display-ready shortcut tokens rather than becoming a general keylogger. Default to modifier combinations and navigation/function keys; unmodified printable characters must be off unless the user explicitly chooses an all-keys mode.

Minimum acceptance bar:

- pause/resume keeps screen, camera, system audio, mic, cursor, clicks, keys, and journal time synchronized; paused time is not exported;
- a marked zoom can be moved, resized, retargeted, disabled, and rendered identically in preview, MOV, GIF, and the live program when created before/during streaming;
- shortcut telemetry uses frame-aligned timestamps, deduplicates key-repeat noise, and never captures Secure Input events;
- the HUD stays out of the captured output and makes paused versus recording state unmistakable.

### 3. Precision Privacy Edit

**Why third:** Existing trim/split/delete is enough for structural cleanup, but users still need exact edit points, source-volume visibility, and a safe way to hide accidental secrets. These are high-frequency repairs; transitions, color grading, and general compositing are not.

Add compact per-source audio waveforms with clipped-peak indicators, a zoomable timeline, keyboard nudging, and accessible trim handles. On that timing foundation, add multiple timed regions with two treatments: opaque fill (the safest default) and blur. Redaction must be an explicit overlay in `edit.json`, never a rewrite of raw tracks. Do not start with automatic PII detection: false negatives create a stronger privacy failure than a visibly manual tool.

Minimum acceptance bar:

- separate system/mic waveforms align with playback and reveal clipping; frame/time nudging and snapping work at timeline zoom levels;
- multiple overlapping redactions can coexist, each with start/end, position, size, and fill/blur treatment;
- preview, frame export, GIF, and MOV share the same renderer and produce identical coverage;
- exports warn when a redaction is outside the visible canvas or does not span the selected export range;
- raw media remains unchanged, and the user can inspect/delete the derived artifact independently.

## Explicitly defer

- Automatic zoom generated from every click; manual intent and cursor timing should be trustworthy first.
- Recording all printable keys by default, or retaining a reusable text log of what the user typed.
- OCR/AI “automatic secret detection” as a security guarantee.
- Object-tracking redactions before static timed regions support multiple overlaps and exact export parity.
- A multitrack NLE, transitions, color grading, or OBS-style arbitrary source/plugin graph.
- More streaming destinations before YouTube reconnect, local backup, preflight, and soak evidence are solid.

