# Studio Recorder — native screen recorder and quick editor

A local-first macOS 26 / Apple Silicon screen recorder for demos, tutorials,
and bug reports. Studio Recorder is the working repository name, not a final
public brand.

## What works now

- discovers all ScreenCaptureKit displays after macOS grants Screen Recording access;
- records each selected display as a native raw movie in parallel;
- requests system audio and microphone capture through ScreenCaptureKit;
- uses HEVC when available, with H.264 fallback;
- writes a `.recordingproject` package to `~/Movies/Studio Recorder/` with a manifest and append-only journal;
- provides a native Projects/Studio shell, exact live display and camera preview, package discovery, contextual recovery status, and `⌘R` start/stop shortcut;
- opens finalized raw tracks with native playback controls and immediate Reveal, Open, Share, and drag actions;
- exports the current playhead as a full-resolution PNG or a bounded five-second GIF without modifying raw media;
- includes unit and media-integration tests for project recovery, capture preferences, navigation, screenshots, and multi-frame GIF output.

## Deliberately not claimed as complete

Independent camera encoding, a separately encoded program `.mov`, quick trim/split,
camera layout instructions, interaction metadata, and local transcripts remain future
slices. The current program preview is an honest capture contract, not a compositor.
Livestreaming, cloud hosting, and an OBS-style scene system are explicit non-goals for
this product phase.

## Build and run

Requirements: Xcode 26.5, XcodeGen, macOS Tahoe 26 on Apple Silicon.

    xcodegen generate
    xcodebuild -project StudioRecorder.xcodeproj -scheme StudioRecorder \
      -destination 'platform=macOS,arch=arm64' build CODE_SIGNING_ALLOWED=NO

On first launch, grant Screen Recording and Microphone access in macOS when requested. Use one short recording first and verify the raw `.mov` files and `journal.ndjson` in the project package.

## Install the DEV app

    ./scripts/dev-install.sh

This builds an arm64 Debug bundle with the separate identifier
ua.com.rmarinsky.studiorecorder.dev, installs it as
/Applications/Studio Recorder DEV.app, and launches it. Its permissions are
separate from a future release build.

## Test

    xcodebuild -project StudioRecorder.xcodeproj -scheme StudioRecorder \
      -destination 'platform=macOS,arch=arm64' test CODE_SIGNING_ALLOWED=NO
