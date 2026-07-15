# Studio Recorder — execution prompt

Use this prompt for the next implementation run.

---

You are continuing the native macOS **Studio Recorder** project in `/Users/rmarinskyi/IdeaProjects/personal/mac-apps/StudioRecorder`.

Read these first:

1. `README.md`
2. `design/IMPLEMENTATION_BLUEPRINT.md` — source of truth
3. `git status --short` and the current diff

The worktree is intentionally dirty from earlier accepted implementation. Preserve it. Do not reset, discard, or rewrite unrelated changes. Do not create fake screens or controls whose effect is not implemented.

## Product boundary

This is an Apple-native recorder/editor, **not an OBS clone**:

- Swift 6, SwiftUI, and AppKit only where SwiftUI is insufficient.
- `ScreenCaptureKit` for display/system-audio capture; `AVFoundation` for camera/mic.
- A `.recordingproject` is the durable object. Raw media is never changed by UI layout, editing, or export.
- Current live Studio preflight already renders a selected display plus selected camera. It is preview-only. Do not claim the camera is recorded until a raw camera track is genuinely implemented.
- The separate Editor/Layout experience remains later. Do not reintroduce a fake `Layouts` destination.

## Current checkpoint

Already present but incomplete:

- Projects / Studio shell and contextual Recovery navigation.
- Basic project discovery and current v1-style package/journal implementation.
- Screen capture, system audio/mic capture, raw track output, basic recovery detection.
- Live Studio stage with selected screen and selected camera preview.
- DEV installer: `./scripts/dev-install.sh`.

Do not call any slice complete merely because part of its UI exists.

## Execution rule

Implement **one coherent delivery slice at a time**, beginning with Slice 1 below. Finish it completely: code, focused tests, full test suite, DEV build, and rendered visual check. Then stop and report exact evidence. Do not jump to Settings, Editor, export, streaming, camera recording, or transcript work before their prerequisites.

Use `apply_patch` for edits. Run:

```sh
xcodebuild -project StudioRecorder.xcodeproj -scheme StudioRecorder \
  -destination 'platform=macOS,arch=arm64' test CODE_SIGNING_ALLOWED=NO
./scripts/dev-install.sh
```

Use Computer Use to inspect the installed `/Applications/Studio Recorder DEV.app` after UI-facing work. Do not alter macOS privacy settings unless explicitly asked.

## Implement now — Slice 1: normalized Project model and library

### Outcome

Project discovery must no longer be a UI-time scan of ad hoc manifest strings. Introduce a deep project-library module that can read existing v1 packages and new v2 packages into one normalized model.

### Required implementation

1. Define normalized domain values for:
   - Project identity, lifecycle/status, source snapshot, track descriptor, and recovery snapshot/report.
   - Manifest v2 with immutable capture-request snapshot, app/build version, schema version, relative track descriptors, created/stopped timestamps.
   - Typed, versioned NDJSON journal events: `projectCreated`, `trackPrepared`, `trackStarted`, `trackFinished`, `trackFailed`, `finalizationStarted`, `projectClosed`, `projectInterrupted`.
2. Evolve `RecordingProjectStore` into the project-library boundary. It must:
   - discover packages without blocking the main actor;
   - decode both v1 and v2 without rewriting a v1 package during discovery;
   - normalize missing v1 fields to explicit `unknown` values;
   - build deterministic project and recovery snapshots from manifest, journal, expected tracks, and file inspection;
   - preserve injectable base directory for tests;
   - keep filesystem details behind the module. Do not add protocols without a second real implementation.
3. Change capture creation only where required to create a valid v2 project and append typed events. Keep the current raw screen recording behavior working.
4. Update the existing coordinator/view only enough to consume normalized project snapshots. Do not redesign the Studio screen in this slice.
5. Add fixtures and tests for:
   - v1 package discovery still working;
   - v2 package discovery;
   - deterministic newest-first project list;
   - finalized, recording, needs-recovery, and unreadable classification;
   - missing manifest, corrupt journal line, missing track, partial/readable track, and unknown-v1 state;
   - journal event ordering and no v1 mutation during a read.

### Explicit non-goals

- No Settings, permission UI, search UI, Project Summary, Editor, export, RTMPS, transcript, or camera raw track.
- No migration that mutates existing v1 projects during scan.
- No JSON-string event matching after this slice.
- No success state based solely on `stoppedAt == nil`.

### Acceptance criteria

- v1 and v2 fixture packages produce deterministic normalized project/recovery snapshots.
- A broken package remains visible as `unreadable`; it is never silently skipped.
- Existing raw recordings remain discoverable and recoverable.
- All tests pass; `git diff --check` is clean.
- If a visible UI value changes, inspect it in the DEV app and report the result.

## Follow-up slices — do not implement until Slice 1 is accepted

| Order | Slice | Required outcome |
| --- | --- | --- |
| 2 | Application model and shell | `StudioRecorderModel`, `AppIntent`, launch/route/capture state, command routing; no duplicate starts. |
| 3 | Permission diagnosis | Live permission snapshot, repair actions, activation refresh; Projects remain browsable while capture is blocked. |
| 4 | Preferences and Studio Draft | Separate `Settings` scene, validated defaults, destination bookmark/fallback, immutable Capture Request when Record starts. |
| 5 | Projects and Project Summary | Loading/empty/search/unreadable/recovery states; real project detail, reveal/open raw media. |
| 6 | Studio Ready and Preparing | Validate draft, freeze to Capture Request, ordered preparation progress, no mutable controls once accepted. |
| 7 | Recording health and Finalizing | Per-track health, one teardown path, asset inspection before close, exact transition to Summary or Recovery. |
| 8 | Recovery resolution | Evidence-based track report, persisted resolution, reveal/open/confirmed discard. |
| 9 | Product hardening | Appearance, resize/accessibility/Reduce Motion/localization checks, multi-display/low-disk/permission-revoke manual soak. |

## Non-negotiable rules

- Every visible control must name its source of truth, allowed states, and effect.
- Preferences apply only to a new Studio Draft. An active immutable Capture Request wins over Settings.
- Capture failures after package creation always create inspectable recovery evidence.
- Keep layout/camera/editor work derived and non-destructive; never mutate raw tracks.
- Preserve the current 30 fps default. Do not show a selectable 60 fps option until capability and soak evidence exists.
- Use native macOS conventions: real Settings scene at `⌘,`, `⌘N` for new recording, `⌘R` record/stop only in Studio, keyboard-accessible controls, no web-style fake chrome.
- Report what is actually implemented versus what is merely designed.

At the end, provide: changed files, test/build command results, DEV visual verification, known limitations, and the exact next slice.
