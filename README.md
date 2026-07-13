# Studio Recorder — capture slice

A native macOS 26 / Apple Silicon prototype for a solo recording studio.

## What works now

- discovers all ScreenCaptureKit displays after macOS grants Screen Recording access;
- records each selected display as a native raw movie in parallel;
- requests system audio and microphone capture through ScreenCaptureKit;
- uses HEVC when available, with H.264 fallback;
- writes a `.recordingproject` package to `~/Movies/Studio Recorder/` with a manifest and append-only journal;
- provides a native SwiftUI recording desk, display selection, program-layout preview, recovery status, and `⌘R` start/stop shortcut;
- includes unit tests for cursor-following viewport decisions and finalized-segment recovery.

## Deliberately not claimed as complete

Camera isolation, a separately encoded program `.mov`, camera placement/keyframes, transcript editing/Diduny integration, pause-cut suggestions, and RTMPS streaming are the next slices. The layout UI in this build is a preview/preset contract, not a compositor.

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
