# Studio Recorder — native screen recorder and quick editor

A local-first macOS 26 / Apple Silicon screen recorder for demos, tutorials,
and bug reports. Studio Recorder is the working repository name, not a final
public brand.

## What works now

- discovers all ScreenCaptureKit displays after macOS grants Screen Recording access;
- records each selected display as a native raw movie in parallel by default;
- records the selected camera as a separate fragmented raw movie, preserving it for later layout changes when Editable tracks is selected;
- requests system audio and microphone capture through ScreenCaptureKit;
- uses HEVC when available, with H.264 fallback;
- writes a `.recordingproject` package to `~/Movies/Studio Recorder/` with a manifest and append-only journal;
- provides a native Projects/Studio shell, exact live display and camera preview, actionable per-track recovery review, and `⌘R` start/stop shortcut;
- configures Full HD, horizontal or vertical 4K, 16:10, square, or custom output canvases; fixed-region mode captures only the selected aspect-correct screen area;
- previews directly selectable screen and camera placement with large corner-resize targets, drag movement, pixel nudging, independent shape/corner radius/transform/framing, freezes the scene into the Capture Request, and reuses the same bounded manipulation in post-recording layout edits;
- saves, renames, and duplicates named Scene presets locally and switches compatible compositions during a recording or stream by click or `⌥1`–`⌥9`; recording projects preserve a timestamped scene timeline so playback and program export reproduce every live layout change;
- pauses and resumes local recording with `⇧⌘P`; recorded duration freezes and paused ranges are omitted non-destructively from project playback and derived output while continuous raw safety tracks remain available for recovery, and Record + Stream clearly keeps the live stream running;
- marks or resets a pointer-centered 2× manual zoom during recording or streaming with `⌥⌘Z`; the timestamped Scene timeline replays the same crop in project playback, MOV, GIF, and program output, and non-destructive post-record controls can move, retarget, resize, or remove each zoom while the full raw display remains recoverable;
- keeps the Studio inspector concise with large Screen, Camera, and Microphone & Audio rows that open focused native source-and-layout popovers;
- removes the camera background locally with Apple Vision Person mode using Auto, Quality, or Performance processing profiles, or with adjustable green/blue chroma key while preserving non-key-colored foreground equipment; Auto lowers live mask detail and cadence under load while quality-first export and editable raw camera media remain unchanged;
- offers Record, YouTube Stream, or Record + Stream from the same frozen Scene; manual RTMPS credentials stay in macOS Keychain, the stream uses the same screen/camera/background/follow compositor as local program output, and live health shows measured composition FPS, render latency, dropped frames, canvas, and bitrate;
- runs a mandatory local stream preflight before starting: credential shape, output/frame-rate contract, one mixed AAC audio stream, destination writeability, storage reserve, YouTube host reachability, and resolution-specific bitrate guidance; transport status says Sending only after the first configured media packets are submitted and does not claim viewer-visible Live;
- offers per-Scene retention: Editable tracks preserves independent screen/camera media, while Program movie only renders and verifies the exact canvas, framing, Follow Cursor motion, camera shape, background treatment, and audio before removing raw tracks;
- edits the output canvas and screen/camera placement, scale, shape, and mirroring after recordings that retain editable tracks; the program layout persists in `edit.json` without touching raw tracks;
- plays and exports the moving screen+camera composition through one Core Image program renderer; PNG and GIF derivation use the same composed result;
- adds multiple timed privacy regions in Quick Edit, with blur or opaque redaction, exact source timing, and adjustable final-canvas placement and size; preview, MOV, PNG, and GIF share the same render path while raw tracks stay unchanged;
- opens finalized editable tracks or a retained program movie with native playback controls and immediate Reveal, Open, Share, and drag actions;
- captures the live composed Scene as a native-resolution PNG using the same crop, vertical/horizontal canvas, camera shape, background removal, cursor treatment, and privacy-safe shortcut overlay as recording; snapshots save locally with immediate Copy, Reveal, and macOS Share;
- optionally displays Command/Control shortcuts, navigation/editing controls, and function keys in preview, recording, snapshots, exports, and the live stream; plain typing, Option-only text composition, repeats, and Secure Input are excluded, while editable timing stays in `scene/shortcuts.json` instead of raw tracks;
- exports the current playhead as a full-resolution PNG and opens a reusable GIF maker for either the faithful edited project composition or any local video, with adjustable range, width, frame rate, looping, exact rendered size, Save, Copy, Drag, and macOS Share actions;
- saves versioned non-destructive edits in `edit.json`, with trim, split/delete, master mute/volume attenuation, timeline undo/redo, edited playback, and compatible MOV export;
- includes unit and media-integration tests for project recovery, capture preferences, navigation, screenshots, and multi-frame GIF output.

## Deliberately not claimed as complete

A program movie is composed during playback/export or during safe post-recording finalization when Program movie only is selected. Live and recorded Follow Cursor use the same scene framing and the custom cursor/click renderer. Editable tracks keeps the full display recoverable; Program movie only deliberately trades later layout changes for one share-ready file. Synchronized waveforms, segment speed, per-source/per-segment volume, and local transcripts remain future slices. Quick edits never rewrite retained source media.
YouTube streaming now retries an interrupted established connection for at least one minute (ten attempts with bounded backoff), with an honest reconnect state and cancellable Stop behavior. Record + Stream keeps its independent editable recording alive while YouTube reconnects. Stream-only automatically writes the exact composed program to a fragmented local MOV, keeps it running through reconnects, and exposes archive failure separately from RTMPS state; system and microphone inputs are mixed into the single AAC stream expected by YouTube. The current preflight verifies local configuration and basic host reachability, not viewer-visible broadcast state or sustained upload capacity. YouTube OAuth/API broadcast health, a timed exact-scene warm-up, exact flattened archive audio mixing, and long horizontal/vertical/4K ingest soak tests remain before streaming is release-ready. Cloud hosting and arbitrary source/device changes during a live session remain out of scope.

## Build and run

Requirements: Xcode 26.5, XcodeGen, macOS Tahoe 26 on Apple Silicon.

    xcodegen generate
    xcodebuild -project StudioRecorder.xcodeproj -scheme StudioRecorder \
      -destination 'platform=macOS,arch=arm64' build CODE_SIGNING_ALLOWED=NO

On first launch, grant Screen Recording, Microphone, and Camera access in macOS when requested. Use one short recording first and verify the raw `.mov` files and `journal.ndjson` in the project package.

## Install the DEV app

    ./scripts/dev-install.sh

This builds an arm64 Debug bundle with the separate identifier
ua.com.rmarinsky.studiorecorder.dev, installs it as
/Applications/Studio Recorder DEV.app, and launches it. Its permissions are
separate from a future release build.

## Test

    xcodebuild -project StudioRecorder.xcodeproj -scheme StudioRecorder \
      -destination 'platform=macOS,arch=arm64' test CODE_SIGNING_ALLOWED=NO
