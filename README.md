# Studio Recorder — native screen recorder and quick editor

A local-first macOS 26 / Apple Silicon screen recorder for demos, tutorials,
and bug reports. Studio Recorder is the working repository name, not a final
public brand.

## What works now

- discovers all ScreenCaptureKit displays after macOS grants Screen Recording access;
- records each selected display as a native raw movie in parallel by default;
- records the selected camera as a separate fragmented raw movie, preserving it for later layout changes when Editable tracks is selected;
- captures system audio and microphone through ScreenCaptureKit and preserves them as two synchronized independent tracks in `raw-tracks/audio-stems.mov`; legacy projects still fall back to their embedded mixed screen audio;
- uses HEVC when available, with H.264 fallback;
- writes a `.recordingproject` package to `~/Movies/Studio Recorder/` with a manifest and append-only journal;
- provides a native Projects/Studio shell, exact live display and camera preview, actionable per-track recovery review, and `⌘R` start/stop shortcut;
- configures Full HD, horizontal or vertical 4K, 16:10, square, or custom output canvases; fixed-region mode captures only the selected aspect-correct screen area;
- previews directly selectable screen and camera placement with large corner-resize targets, drag movement, pixel nudging, independent shape/corner radius/transform/framing, freezes the scene into the Capture Request, and reuses the same bounded manipulation in post-recording layout edits;
- saves, renames, duplicates, and orders named Scene presets locally and switches compatible compositions during a recording or stream by click or `⌥1`–`⌥9`; scene order determines the shortcut assignment, and recording projects preserve a timestamped scene timeline so playback and program export reproduce every live layout change;
- pauses and resumes local recording with `⇧⌘P`; recorded duration freezes and paused ranges are omitted non-destructively from project playback and derived output while continuous raw safety tracks remain available for recovery, and Record + Stream clearly keeps the live stream running;
- marks or resets a pointer-centered 2× manual zoom during recording or streaming with `⌥⌘Z`; the timestamped Scene timeline replays the same crop in project playback, MOV, GIF, and program output, and non-destructive post-record controls can move, retarget, resize, or remove each zoom while the full raw display remains recoverable;
- keeps the Studio inspector concise with large Screen, Camera, and Microphone & Audio rows that open focused native source-and-layout popovers;
- removes or blurs the camera background locally with Apple Vision Person detection using Auto, Quality, or Performance processing profiles, or uses adjustable green/blue chroma key while preserving non-key-colored foreground equipment; Auto lowers live mask detail and cadence under load while quality-first export and editable raw camera media remain unchanged;
- offers Record, YouTube Stream, or Record + Stream from the same frozen Scene; managed YouTube mode uses external-browser OAuth, creates and binds a private event, keeps tokens in macOS Keychain, refreshes current primary/backup RTMPS ingestion during reconnect, reconciles an interrupted event on relaunch, reports server-side ingest/broadcast health, and explicitly completes it on Stop; manual RTMPS remains available as a fallback;
- watches every active recording and streaming source independently—including each selected display, camera, system audio, and microphone—and surfaces warm-up, stalls, and recovery without stopping the capture; combined Record + Stream keeps the two delivery paths visibly separate, while a stalled live-program screen ingress gets up to two bounded in-place/rebuild recovery attempts without disturbing raw recording tracks;
- primes the real program compositor before publishing: a post-attempt screen frame must render with the exact validated Scene and every visible camera must provide a current frame before YouTube, the stream-only archive, or Record + Stream can start;
- runs a mandatory local stream preflight before starting: credential shape, output/frame-rate contract, one mixed AAC audio stream, destination writeability, storage reserve, YouTube host reachability, and resolution-specific bitrate guidance; transport status says Sending only after the first configured media packets are submitted and does not claim viewer-visible Live;
- offers per-Scene retention: Editable tracks preserves independent screen/camera media, while Program movie only renders and verifies the exact canvas, framing, Follow Cursor motion, camera shape, background treatment, and audio before removing raw tracks;
- edits the output canvas and screen/camera placement, scale, shape, and mirroring after recordings that retain editable tracks; the program layout persists in `edit.json` without touching raw tracks;
- plays and exports the moving screen+camera composition through one Core Image program renderer; PNG and GIF derivation use the same composed result;
- adds multiple timed privacy regions in Quick Edit, with blur or opaque redaction, exact source timing, and adjustable final-canvas placement and size; preview, MOV, PNG, and GIF share the same render path while raw tracks stay unchanged;
- opens finalized editable tracks or a retained program movie with native playback controls and immediate Reveal, Open, Share, and drag actions;
- captures the live composed Scene as a native-resolution PNG using the same crop, vertical/horizontal canvas, camera shape, background removal, cursor treatment, and privacy-safe shortcut overlay as recording; snapshots save locally with immediate Copy, Reveal, and macOS Share;
- optionally displays Command/Control shortcuts, navigation/editing controls, and function keys in preview, recording, snapshots, exports, and the live stream; plain typing, Option-only text composition, repeats, and Secure Input are excluded, while editable timing stays in `scene/shortcuts.json` instead of raw tracks;
- exports the current playhead as a full-resolution PNG and opens a reusable GIF maker for either the faithful edited project composition or any local video, with adjustable range, width, frame rate, looping, exact rendered size, Save, Copy, Drag, and macOS Share actions;
- saves versioned non-destructive edits in `edit.json`, with trim, split/delete, master and independent system/microphone mute/volume attenuation, timeline undo/redo, edited playback, and compatible MOV export;
- includes unit and media-integration tests for project recovery, capture preferences, navigation, screenshots, and multi-frame GIF output.

## Deliberately not claimed as complete

A program movie is composed during playback/export or during safe post-recording finalization when Program movie only is selected. Live and recorded Follow Cursor use the same scene framing and the custom cursor/click renderer. Editable tracks keeps the full display and synchronized system/microphone stems recoverable; Program movie only verifies the expected audio tracks before trading later layout changes for one share-ready file. Quick Edit builds cached source-time waveforms with peak/RMS levels and clipping markers for the system and microphone stems, plus independent source, master, and selected-segment mute/volume, without rewriting retained media. Segment speed and local transcripts remain future slices.
YouTube streaming retries an interrupted established connection for at least one minute (ten attempts with bounded backoff), with an honest reconnect state and cancellable Stop behavior. Managed mode waits for fresh local media before advancing the private preview to viewer-visible live, alternates YouTube's current primary/backup ingestion endpoints, and stops retrying when the remote event is complete or revoked. Record + Stream keeps its independent editable recording alive while YouTube reconnects. Stream-only automatically writes the exact composed program to a fragmented local MOV, keeps it running through reconnects, flattens system and microphone audio into one share-ready AAC track, and exposes archive failure separately from RTMPS state. Automatic recovery covers the live-program screen ingress; fixed raw screen/camera files still remain fail-visible because safe restart requires segmented track descriptors and stitching. Long private horizontal/vertical/4K ingest, network-loss, key-rotation, device-loss, force-quit, and sleep/wake soak evidence still remains before streaming is release-ready. Manual-key mode provides transport recovery only and requires verification in Live Control Room.

## Build and run

Requirements: Xcode 26.5, XcodeGen, macOS Tahoe 26 on Apple Silicon.

    xcodegen generate
    xcodebuild -project StudioRecorder.xcodeproj -scheme StudioRecorder \
      -destination 'platform=macOS,arch=arm64' build CODE_SIGNING_ALLOWED=NO

On first launch, grant Screen Recording, Microphone, and Camera access in macOS when requested. Use one short recording first and verify the raw `.mov` files and `journal.ndjson` in the project package.

Managed YouTube uses one application-owned OAuth desktop client. Local builds may inject it without writing credentials to the repository:

    GOOGLE_OAUTH_CLIENT_ID='…apps.googleusercontent.com' \
    GOOGLE_OAUTH_CLIENT_SECRET='…' \
    ./scripts/dev-install.sh

Without both values, recording and manual RTMPS remain available while managed YouTube is shown as unavailable. OAuth tokens are stored in macOS Keychain; the client secret is never stored with those tokens. Like every native desktop OAuth secret, it is recoverable from a distributed binary and is not treated as a security boundary.

## Install the DEV app

    ./scripts/dev-install.sh

This builds an arm64 Debug bundle with the separate identifier
ua.com.rmarinsky.studiorecorder.dev, installs it as
/Applications/Studio Recorder DEV.app, and launches it. Its permissions are
separate from a future release build.

## Test

    xcodebuild -project StudioRecorder.xcodeproj -scheme StudioRecorder \
      -destination 'platform=macOS,arch=arm64' test CODE_SIGNING_ALLOWED=NO

## Releases

CI builds and tests pushes and pull requests on macOS 26 with Xcode 26.5. The release workflow signs an arm64 app with Developer ID, submits it to Apple notarization, staples and validates it, then produces a ZIP and SHA-256 checksum. Manual runs upload an internal validation artifact. A `v*` tag additionally publishes those files as a GitHub release.

Repository variables:

- `GOOGLE_OAUTH_CLIENT_ID`
- `APPLE_TEAM_ID`

Repository secrets:

- `GOOGLE_OAUTH_CLIENT_SECRET`
- `DEVELOPER_ID_CERTIFICATE_P12_BASE64`
- `DEVELOPER_ID_CERTIFICATE_PASSWORD`
- `APP_STORE_CONNECT_API_KEY_P8_BASE64`
- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`

Rotate the Google OAuth client secret before the first public build. Product information, privacy terms, and release links are published at [rmarinsky.com.ua/studio-recorder](https://rmarinsky.com.ua/en/studio-recorder/).
