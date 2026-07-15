# Prioritized macOS recorder user needs — 15 July 2026

Reviewed against Studio Recorder `f9fb4d9`, the current [README](../../README.md), and focused implementation/tests for `StudioScene`, `StreamPreflight`, cursor framing, camera processing, recovery, GIF/snapshot export, and the local stream archive.

## Recommendation

Studio Recorder already covers most headline requests. The next value is not another effect; it is proving that one named Scene stays faithful through long capture, live switching, 4K load, reconnect, recovery, edit, GIF/snapshot export, and sharing.

Build in this order:

1. **Capture/stream reliability proof** — sustained upload and viewer-state checks, exact archive audio, and horizontal/vertical/4K fault soaks.
2. **Record with intent** — synchronized pause/resume, manual zoom markers, and safe command-key display.
3. **Audio precision** — source waveforms, clipping visibility, keyboard nudging, segment speed, mute, and volume.
4. **Adaptive camera performance** — Auto/Quality/Performance profiles and cheaper background blur.
5. **Recovery drills and Scene/export parity** — real force-quit/disk-full fixtures plus rendered verification of live Scene switches.
6. **Delivery presets** — two-action screenshot/GIF/video sharing; hosted links remain optional and later.

## Evidence rules

- Reddit/community links are first-person discovery evidence, not market-size evidence.
- Vendor documentation is used only for technical/product constraints.
- “Existing coverage” is based on current code and tests, not a roadmap document.

## Prioritized findings

### 1. Trustworthy capture and streaming at the chosen quality

**Recurring job/problem.** Users want to record and stream for one to several hours without the Mac becoming choppy, the stream silently dropping, or the local result becoming unusable. “4K” is usually a quality/performance contract, not merely a resolution menu item. A June 2026 M4 Air user reports immediate choppiness across third-party recorders, worse with webcam, plus camera/audio desynchronization in one app ([Reddit](https://www.reddit.com/r/obs/comments/1ucusx1/macbook_air_m4_becomes_laggy_during_screen/)). Another Mac user planning simultaneous two-hour stream and recording asks specifically about fanless stability ([Reddit](https://www.reddit.com/r/obs/comments/1sgk6uu/streaming_obs_on_m5_macbook_air/)).

**Technical constraint.** YouTube currently recommends 30 Mbps H.264 for 4K30, two-second keyframes, CBR, RTMPS, representative-motion testing, health monitoring, and a growing verified local archive ([encoder settings](https://support.google.com/youtube/answer/2853702?hl=en-EN), [streaming tips](https://support.google.com/youtube/answer/2853856?hl=en), [archive guidance](https://support.google.com/youtube/answer/6247592?hl=en)).

**Existing coverage.** Studio Recorder supports horizontal/vertical 4K, health telemetry, reconnect with bounded backoff, independent Record + Stream capture, a fragmented stream-only archive, and mandatory preflight for credentials, canvas/FPS/bitrate, audio, storage, destination, and advisory host reachability. `StreamPreflightTests` explicitly warns that upload headroom remains unverified.

**Recommendation.** Finish the trust boundary before calling streaming or 4K release-ready: timed warm-up, sustained-upload estimate, optional YouTube broadcast-health integration, exact flattened archive audio, and real fault soaks.

**Acceptance criterion.** Complete one-hour 1080p landscape, 1080p portrait, and 4K30 sessions with camera/background treatment; inject a 30–60 second network loss; measure dropped frames, render latency, A/V/cursor drift, thermal behavior, storage growth, reconnect state, and viewer-visible state. Every local artifact must remain playable and the UI must never claim Live when only local packet submission is known.

### 2. Record with intent: pause, manual focus, and safe keys

**Recurring job/problem.** Tutorial makers repeatedly bundle pause, automatic/manual zoom, key display, cursor emphasis, webcam treatment, and quick cleanup ([Reddit](https://www.reddit.com/r/macapps/comments/1rhrcg8/screen_recording_apps_what_are_you_actually_using/)). Users notice even a one-to-two-second mismatch between cursor action and zoom target ([Reddit](https://www.reddit.com/r/macapps/comments/1qrzfa8/os_i_built_screenize_an_opensource_alternative_to/)).

**Technical constraint.** Screen Studio documents cursor effects as post-capture presentation data and notes that imported videos cannot regain missing cursor/camera telemetry ([cursor guide](https://screen.studio/guide/cursor), [import guide](https://screen.studio/guide/creating-project-from-existing-video)). This supports collecting semantic events during capture rather than baking them irreversibly into pixels.

**Existing coverage.** Follow Cursor, scalable cursor/click treatment, frame-aligned cursor history, fixed-region framing, and live/record/export compositor parity exist. Pause/resume omits paused time non-destructively. `Zoom Here` / `Reset Zoom` places a pointer-centered 2× crop into the timestamped Scene timeline during recording or streaming. Post-record controls move its source time, retarget its center, change magnification, or remove it through `edit.json`; rendered tests prove the edited marker replays in program output without changing captured media. Safe key telemetry remains incomplete.

**Recommendation.** Record safe command-key events next. Default to modifier combinations, navigation, and function keys; do not create a general key log or capture Secure Input. Keep pause and zoom semantic and non-destructive so raw safety media remains untouched. Apple exposes native camera-file pause/resume, but `SCRecordingOutput` has no matching pause API, so timeline compaction avoids risky screen/audio recorder reconfiguration ([AVCaptureFileOutput](https://developer.apple.com/documentation/AVFoundation/AVCaptureFileOutput), [SCRecordingOutput](https://developer.apple.com/documentation/screencapturekit/screcordingoutput)).

**Acceptance criterion.** Paused time is absent from normal project playback and every derived output; raw safety tracks remain byte-preserving and recoverable. Duration freezes while paused. Scene and cursor events remain source-time aligned across each omitted range. Record + Stream explicitly says the stream remains live; Stream-only has no Pause. Manual zoom is movable/resizable/retargetable. Preview, MOV, GIF, and live program render the same event at the same frame within one output frame of tolerance.

### 3. Editable audio without a second application

**Recurring job/problem.** Users want microphone and system audio separate so they can mute, rebalance, or repair one source without affecting the other. A 2026 discussion recommends separate tracks specifically because they stay synchronized and editable ([Reddit](https://www.reddit.com/r/obs/comments/1rj4pk0/do_you_use_audacity/)); another asks how to mute voice or application audio independently after capture ([Reddit](https://www.reddit.com/r/SmallYoutubers/comments/1qott7y/screen_recording_with_separate_audio_tracks/)).

**Technical constraint.** OBS documents separate recording tracks for post-production and a distinct combined stream track ([official multi-track guide](https://obsproject.com/kb/advanced-recording-guide-and-multi-track-audio)). Ordinary players may expose only one track, so a share-ready program mix and editable sources are separate contracts.

**Existing coverage.** Studio Recorder captures system audio and mic, retains editable raw tracks, and mixes enabled live inputs into the single AAC stream YouTube expects. The README deliberately leaves synchronized waveforms, speed, and volume editing incomplete.

**Recommendation.** Add compact source waveforms, clipped-peak markers, zoomable time scale, keyboard nudging, segment speed, and source/segment volume or mute. Persist edits in `edit.json`; never rewrite raw media.

**Acceptance criterion.** System/mic waveforms align with decoded playback, clipping is visible, source changes survive undo/redo and reopen, and one shared renderer produces identical preview/MOV output while retained raw tracks remain byte-unchanged.

### 4. Camera/background effects that do not starve capture

**Recurring job/problem.** Webcam overlay, independent placement, shape, and background treatment are repeatedly requested together, but webcam is also the component users report making recording lag and desynchronize ([Reddit](https://www.reddit.com/r/macapps/comments/1rhrcg8/screen_recording_apps_what_are_you_actually_using/), [Reddit](https://www.reddit.com/r/obs/comments/1ucusx1/macbook_air_m4_becomes_laggy_during_screen/)).

**Technical constraint.** Ecamm documents that multiple isolated video encodes can reduce source resolution and that its ISO path does not support 4K ([official preferences](https://support.ecamm.com/en/articles/3324016-ecamm-s-preferences-window)). The practical constraint is encoding/composition budget, not shape-control breadth.

**Existing coverage.** Independent camera transforms/shapes, Vision person removal, chroma key, raw-camera retention, and throttled segmentation exist. Person removal now offers Auto, Quality, and Performance profiles; Auto measures segmentation cost and lowers live mask input/cadence before capture stalls, while export remains quality-first. Preflight warns about 4K plus background treatment.

**Recommendation.** Add a cheaper Blur mode and expose Auto's effective degradation in stream health. Continue reducing mask cadence/preview detail before sacrificing raw capture or audio sync.

**Acceptance criterion.** Fanless Apple Silicon screen+camera tests meet a defined frame-time and drift budget; forced overload visibly degrades mask quality but not raw screen/camera/audio continuity; raw camera remains unchanged.

### 5. Reusable Scenes that stay safe while live

**Recurring job/problem.** Users want screen/camera composition for the live program and separate material for later editing. A May 2026 user asks how to stream the composed screen/webcam while recording flexible source material; the discussion immediately encounters different canvas and bitrate contracts ([Reddit](https://www.reddit.com/r/obs/comments/1tekcwt/streamingrecording_webcam_and_video_separately/)). A teacher asks for separate camera media so it can appear only when the content needs it ([Reddit](https://www.reddit.com/r/macapps/comments/1t7hoei/castly_simple_mac_screen_recording_with_webcam/)).

**Technical constraint.** OBS Scene Collections save reusable Sources/Scenes but separate them from output Profiles ([official guide](https://obsproject.com/kb/scene-collections)). Studio Recorder should keep this concept narrow: composition presets, not a plugin graph.

**Existing coverage.** `StudioSceneLibraryStore` atomically persists named Scenes; Studio exposes save, rename, duplicate, delete, and large live-switch targets; `StudioSceneLiveContract` blocks unsafe canvas/camera/cursor/region changes; compatible live switches append a timestamped `StudioSceneTimeline`, which playback/export resolves at source time. Tests cover persistence, corruption preservation, rebasing, and incompatible switches.

**Recommendation.** Keep the current narrow Scene model. Prioritize rendered live verification, scene reordering, and cut/short-dissolve only. Do not add browser sources, nested scenes, or arbitrary source/device changes.

**Acceptance criterion.** Switch repeatedly among Screen, Camera, and Screen + Camera during record, stream, and Record + Stream. Program preview/export must match the recorded Scene timeline frame-for-frame; raw-track retention must not change; incompatible switches must fail before mutating the active Scene.

### 6. Recovery that saves completed work after real failures

**Recurring job/problem.** A July 2026 user lost almost four hours after Stop hung and they force-quit ([Reddit](https://www.reddit.com/r/obs/comments/1uw234z/is_it_possible_for_me_to_recover_this_recording/)). A June disk-full case left MP4 unusable and an MKV without normal duration/scrubbing because FAT32 hit its file-size limit despite apparent free space ([Reddit](https://www.reddit.com/r/obs/comments/1ufm42a/obs_recordings_keeps_corrupting/)).

**Technical constraint.** OBS Hybrid MOV/MP4 stays recoverable after an aborted write and finalizes into a broadly compatible file ([official format guide](https://obsproject.com/kb/hybrid-mp4)). Finalization must not be the only point at which hours become usable.

**Existing coverage.** Studio Recorder uses fragmented MOV assets, manifest plus append-only journal, lifecycle derivation, readable-track salvage, diagnostics preservation, Reveal, and confirmed Trash. Unit tests cover corrupt manifests, partial tracks, no-readable-track refusal, and recovery history.

**Recommendation.** Stop expanding recovery UI; prove it with real media fault fixtures and storage-volume constraints.

**Acceptance criterion.** Force-quit during screen/camera capture and program finalization, simulate disk-full/writer failure, then relaunch. Recovery Review must identify each track accurately, salvage every playable fragment without rewriting failure history, refuse false recovery, and produce a playable project/export.

### 7. Trim, snapshot, GIF, and share in two deliberate actions

**Recurring job/problem.** Users value recording-to-GIF enough to pay for it and want clipboard-ready short clips for team chat ([Reddit](https://www.reddit.com/r/macapps/comments/1iu8s5o/what_screenshot_app_do_you_use/), [Reddit](https://www.reddit.com/r/macapps/comments/1k3ne8j/screen_recorder_with_gif_watermark_support/)). The built-in Mac capture tool remains attractive because the thumbnail can be dragged, marked up, or shared immediately ([Apple Support](https://support.apple.com/guide/mac-help/take-a-screenshot-mh26782/mac)). Screen Studio likewise documents GIF/MP4 file or clipboard export with size/FPS/quality settings ([official export guide](https://screen.studio/guide/exporting-the-video)).

**Existing coverage.** Studio Recorder has trim/split/delete/undo, faithful MOV export, live and project PNG, range GIF settings, exact dimensions, Save/Copy/Drag/Share, privacy-region parity, and local-video-to-GIF.

**Recommendation.** Treat these as destinations from one composition. Add a few named delivery presets and size estimates; do not build a separate screenshot editor or first-party hosting yet.

**Acceptance criterion.** From Studio or a project, place a correct PNG, short GIF, or MOV into Mail/Slack/issue tooling in two deliberate actions. Vertical/4K, Scene switches, Follow Cursor, camera shape/background, and redaction must match the same frame in preview and output; oversized GIFs warn before encoding.

## Explicitly defer

- General OBS plugins/browser sources/nested scenes.
- More automatic cursor animation before manual control and long-run alignment are proven.
- Camera novelty effects before adaptive performance and sync.
- A general multitrack NLE, transitions, or asset library.
- First-party cloud hosting before local delivery metrics justify its privacy and operating cost.
- More streaming platforms before YouTube broadcast-health, archive audio, and soak evidence pass.
