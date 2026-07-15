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
- previews draggable/resizable screen and camera placement, gives each source independent shape, corner radius, transform, and framing, freezes the scene into the Capture Request, and renders scalable cursor/click treatment through the shared compositor;
- removes the camera background locally with a throttled Apple Vision Person mode, or with adjustable green/blue chroma key while preserving non-key-colored foreground equipment; editable raw camera media remains unchanged;
- offers Record, YouTube Stream, or Record + Stream from the same frozen Scene; manual RTMPS credentials stay in macOS Keychain, the stream uses the same screen/camera/background/follow compositor as local program output, and live health shows measured composition FPS, render latency, dropped frames, canvas, and bitrate;
- offers per-Scene retention: Editable tracks preserves independent screen/camera media, while Program movie only renders and verifies the exact canvas, framing, Follow Cursor motion, camera shape, background treatment, and audio before removing raw tracks;
- edits the output canvas and screen/camera placement, scale, shape, and mirroring after recordings that retain editable tracks; the program layout persists in `edit.json` without touching raw tracks;
- plays and exports the moving screen+camera composition through one Core Image program renderer; PNG and GIF derivation use the same composed result;
- opens finalized editable tracks or a retained program movie with native playback controls and immediate Reveal, Open, Share, and drag actions;
- exports the current playhead as a full-resolution PNG and opens a reusable GIF maker for either the faithful edited project composition or any local video, with adjustable range, width, frame rate, looping, exact rendered size, Save, Copy, Drag, and macOS Share actions;
- saves versioned non-destructive edits in `edit.json`, with trim, split/delete, undo/redo, edited playback, and compatible MOV export;
- includes unit and media-integration tests for project recovery, capture preferences, navigation, screenshots, and multi-frame GIF output.

## Deliberately not claimed as complete

A program movie is composed during playback/export or during safe post-recording finalization when Program movie only is selected. Live and recorded Follow Cursor use the same scene framing and the custom cursor/click renderer. Editable tracks keeps the full display recoverable; Program movie only deliberately trades later layout changes for one share-ready file. Synchronized waveforms, speed/volume edits, and local transcripts remain future slices. Quick edits never rewrite retained source media.
YouTube OAuth/API broadcast creation, automatic reconnect, and long horizontal/vertical ingest soak tests remain before streaming is release-ready. Cloud hosting and a general OBS-style scene graph remain out of scope.

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
