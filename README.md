# Studio Recorder — native screen recorder and quick editor

A local-first macOS 26 / Apple Silicon screen recorder for demos, tutorials,
and bug reports. Studio Recorder is the working repository name, not a final
public brand.

## What works now

- discovers all ScreenCaptureKit displays after macOS grants Screen Recording access;
- records each selected display as a native raw movie in parallel;
- records the selected camera as a separate fragmented raw movie, preserving it for later layout changes;
- requests system audio and microphone capture through ScreenCaptureKit;
- uses HEVC when available, with H.264 fallback;
- writes a `.recordingproject` package to `~/Movies/Studio Recorder/` with a manifest and append-only journal;
- provides a native Projects/Studio shell, exact live display and camera preview, package discovery, contextual recovery status, and `⌘R` start/stop shortcut;
- configures horizontal, vertical, 16:10, square, or custom output canvases; fixed-region mode captures only the selected aspect-correct screen area;
- previews draggable/resizable screen and camera placement, gives camera its own free/landscape/portrait/square frame, freezes source shape/position plus cursor treatment into the Capture Request, and records the native system cursor;
- edits the output canvas and screen/camera placement, scale, shape, and mirroring after recording; the program layout persists in `edit.json` without touching raw tracks;
- plays and exports the moving screen+camera composition through one Core Image program renderer; PNG and GIF derivation use the same composed result;
- opens finalized raw tracks with native playback controls and immediate Reveal, Open, Share, and drag actions;
- exports the current playhead as a full-resolution PNG or a bounded five-second GIF without modifying raw media;
- saves versioned non-destructive edits in `edit.json`, with trim, split/delete, undo/redo, edited playback, and compatible MOV export;
- includes unit and media-integration tests for project recovery, capture preferences, navigation, screenshots, and multi-frame GIF output.

## Deliberately not claimed as complete

A program movie is composed on playback/export rather than encoded during capture. Synchronized waveforms, speed/volume edits, cursor-position telemetry for post-capture mouse-follow/click rendering,
program-only storage, and local transcripts remain future slices. The live preview follows the cursor now; recorded follow-mode export still awaits telemetry. Camera and screen raw tracks stay independent, and quick edits
never rewrite raw tracks.
Livestreaming, cloud hosting, and an OBS-style scene system are explicit non-goals for
this product phase.

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
