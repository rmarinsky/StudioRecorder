# ScreenCaptureKit stale-frame and recording-start lifecycle

Research date: 2026-07-30
Repository snapshot: branch `codex/recording-resilience-performance`, HEAD `3482bd4`
Symptom: a new recording can contain a live camera over a screen image that appears frozen at a state from the previous recording.

## Conclusion

Restarting capture at the beginning of each recording is a reasonable defensive policy, but it is **not an Apple-documented fix for stale frames**. Apple documents `startCapture`, `stopCapture`, frame statuses, dynamic filter/configuration updates, and terminal delegate errors; it does not document a known “previous recording frame” failure mode or recommend a routine restart as its remedy ([SCStream](https://developer.apple.com/documentation/screencapturekit/scstream), [SCStreamDelegate](https://developer.apple.com/documentation/screencapturekit/scstreamdelegate)).

For Studio Recorder, the local raw recording path already performs the strongest form of restart: every recording queries `SCShareableContent.current`, creates a new `SCContentFilter`, a new `SCStream`, and a new `SCRecordingOutput`, then starts that stream ([`RecordingCoordinator.swift`](../../Recording/RecordingCoordinator.swift#L320), [`RecordingCoordinator.swift`](../../Recording/RecordingCoordinator.swift#L363), [`RecordingCoordinator.swift`](../../Recording/RecordingCoordinator.swift#L380)). Restarting only the long-lived preview stream therefore cannot repair a stale local `SCRecordingOutput`.

The missing protection is a **freshness gate on the actual recording stream**:

1. create the new stream from a newly queried `SCShareableContent`;
2. assign an `SCStreamDelegate`;
3. start it and observe its screen output before attaching or declaring the recording started;
4. require a valid `.complete` frame from that exact stream generation whose `displayTime` is at or after the start request;
5. time out and rebuild once if that evidence does not arrive;
6. only then start `SCRecordingOutput` and show **Recording**.

This gate proves that Studio Recorder saw a newly generated screen surface from the new capture lifecycle. It does not try to infer freshness from the camera, preview image, file duration, callback count, or `.idle` callbacks.

## Implementation outcome

The fix implemented after this research now:

- assigns the recording coordinator as the delegate of every local screen stream;
- starts a newly created stream for every recording and waits up to three seconds for a valid post-start `.complete` frame from every selected display;
- attaches `SCRecordingOutput` only after that gate passes, so an unverified surface cannot enter the new screen file;
- fails the start clearly and tears the partial session down if the gate does not pass;
- interrupts an active recording when ScreenCaptureKit reports a terminal stream stop.

It deliberately does not rebuild a screen stream in the middle of one recording. ScreenCaptureKit ends the attached `SCRecordingOutput` when that stream is stopped, so correct transparent recovery requires a new project segment and continuity metadata.

## Apple’s stream contract

`SCStream` is created from an `SCContentFilter` and `SCStreamConfiguration`; after `startCapture`, ScreenCaptureKit delivers media through `SCStreamOutput`. `startCapture` only reports whether starting the stream succeeded. It does not promise that a current video surface has already reached the app when the call returns ([Meet ScreenCaptureKit](https://developer.apple.com/videos/play/wwdc2022/10156/), [startCapture](https://developer.apple.com/documentation/screencapturekit/scstream/startcapture%28completionhandler%3A%29), [SCStreamOutput](https://developer.apple.com/documentation/screencapturekit/scstreamoutput)).

Apple’s sample creates a filter from newly retrieved `SCShareableContent`, adds outputs, and starts the stream. `SCShareableContent` represents the displays, windows, and applications available to capture; querying it again before a new recording is the correct way to resolve the selected `displayID` against the current system state ([SCShareableContent](https://developer.apple.com/documentation/screencapturekit/scshareablecontent), [Capturing screen content in macOS](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)).

Changing a running stream’s configuration or filter does **not** require restarting it. Apple explicitly presents `updateConfiguration` and `updateContentFilter` as live updates that do not interrupt or recreate the stream ([Take ScreenCaptureKit to the next level](https://developer.apple.com/videos/play/wwdc2022/10155/), [Capturing screen content in macOS](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos), [updateConfiguration](https://developer.apple.com/documentation/screencapturekit/scstream/updateconfiguration%28_%3Acompletionhandler%3A%29)). Consequently, reapplying the same filter/configuration is useful for normal reconfiguration but is not equivalent to tearing down a suspected bad capture session.

`SCStreamDelegate.stream(_:didStopWithError:)` is the authoritative terminal-stop callback. Apple says `SCStreamError.Code.userStopped` represents an intentional user cancellation and should be treated as expected and recoverable; other stop errors should invalidate the stream and trigger failure or bounded rebuilding ([stream(_:didStopWithError:)](https://developer.apple.com/documentation/screencapturekit/scstreamdelegate/stream%28_%3Adidstopwitherror%3A%29), [SCStreamError](https://developer.apple.com/documentation/screencapturekit/scstreamerror)).

## What frame status does and does not prove

Apple defines the `SCFrameStatus` values as follows ([SCFrameStatus](https://developer.apple.com/documentation/screencapturekit/scframestatus)):

| Status | Meaning | Studio Recorder treatment |
|---|---|---|
| `.started` | First frame sent after the stream starts. | Lifecycle evidence only; do not use as fresh-pixel evidence. |
| `.complete` | The system successfully generated a new frame. | The only status that should satisfy recording-start screen freshness, together with valid/data-ready/image-buffer checks and a current `displayTime`. |
| `.idle` | No new frame because the display did not change. | Healthy callback/liveness evidence, but not fresh-pixel evidence. Retain the last complete surface. |
| `.blank` | No new frame because the display is blank. | Degraded/blocked for recording start; do not treat the previous image as current. |
| `.suspended` | No new frame because updates are suspended. | Degraded; wait briefly or rebuild. |
| `.stopped` | The frame is in a stopped state. | Terminal for that generation; reject it and rebuild/fail. |

Apple’s WWDC22 explanation is particularly important: a `.complete` sample has a new video frame, while `.idle` means the sample did not change and has no new `IOSurface` ([Meet ScreenCaptureKit](https://developer.apple.com/videos/play/wwdc2022/10156/)). Therefore:

- repeated `.idle` callbacks can be perfectly correct for a static desktop;
- lack of pixel changes alone is not a freeze detector;
- an `.idle` callback must not make a new recording “fresh” because it can only refer back to the last complete surface;
- `.blank`, `.suspended`, `.started`, and `.stopped` must never replace the last good preview image or enter the program compositor as a new screen image.

`SCStreamFrameInfo.displayTime` identifies the display event time, and `dirtyRects` identifies regions redrawn or moved. The app can use `displayTime` to measure callback age and monotonic progress, and use `dirtyRects` for diagnostics on `.complete` frames ([SCStreamFrameInfo](https://developer.apple.com/documentation/screencapturekit/scstreamframeinfo), [dirtyRects](https://developer.apple.com/documentation/screencapturekit/scstreamframeinfo/dirtyrects)). Empty dirty rectangles or identical pixels are not independently a freeze because legitimately identical content is allowed.

## Reliable freeze detection

Use separate signals instead of a single “last sample” timestamp:

| Signal | Detects | Does not prove |
|---|---|---|
| Callback arrival time | The output callback is still being invoked. | That the callback carries a new or recent screen surface. |
| `SCFrameStatus` | Whether the system generated, skipped, blanked, suspended, started, or stopped a frame. | That `.idle` is wrong when the real desktop changed. |
| `displayTime` monotonicity and age | Old, repeated, or excessively queued frame events. | Pixel correctness by itself. |
| Stream identity/generation | Late callbacks from a retired stream. | That the current stream is healthy. |
| `.complete` + valid/data-ready/image buffer | A newly generated usable surface. | That every later surface will remain live. |
| `didStopWithError` | An authoritative terminal stream failure. | Silent stalls where no terminal callback arrives. |

The minimum runtime telemetry per screen stream should be:

- generation and selected `displayID`;
- start-request host time;
- last callback arrival time;
- last status;
- last and previous `displayTime`;
- computed delivery age (`now - displayTime`);
- last `.complete` arrival and display time;
- counts of `.complete`, `.idle`, `.blank`, `.suspended`, `.started`, `.stopped`, invalid buffers, and rejected old-generation callbacks;
- restart reason, attempt, and result.

A running stream is suspicious when callbacks stop beyond a short threshold, `displayTime` stops advancing, callback delivery age grows, a non-current generation still emits samples, or no post-start `.complete` surface arrives before the start deadline. Do not classify “same image hash for N seconds” as failure without an independent indication that the display changed.

Apple warns that holding screen surfaces too long creates latency and eventually frame loss: the app needs to process within `minimumFrameInterval` and release surfaces before the pool is exhausted. Larger queue depths can increase latency; the documented default/minimum is three and the maximum is eight ([Take ScreenCaptureKit to the next level](https://developer.apple.com/videos/play/wwdc2022/10155/), [queueDepth](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/queuedepth)). Measuring `displayTime` age is therefore necessary even when callbacks continue.

## Gaps in the researched snapshot

### Local raw recording

The local recording path already constructs a fresh stream per recording, so there is no persistent local `SCStream` to “restart” first ([`RecordingCoordinator.swift`](../../Recording/RecordingCoordinator.swift#L320), [`RecordingCoordinator.swift`](../../Recording/RecordingCoordinator.swift#L380)).

At the researched `3482bd4` snapshot:

- it creates the local `SCStream` with `delegate: nil`, so terminal `SCStreamDelegate` errors are not observed ([`RecordingCoordinator.swift`](../../Recording/RecordingCoordinator.swift#L380));
- it adds `SCRecordingOutput` before `startCapture`, so the file begins before the app has independently verified a current `.complete` screen frame ([`RecordingCoordinator.swift`](../../Recording/RecordingCoordinator.swift#L381), [`RecordingCoordinator.swift`](../../Recording/RecordingCoordinator.swift#L422));
- its source health records both `.complete` and `.idle` as healthy using callback arrival time, without checking `displayTime` age or requiring a new complete surface ([`RecordingCoordinator.swift`](../../Recording/RecordingCoordinator.swift#L1174));
- its recovery path only reapplies `updateContentFilter` and `updateConfiguration`; Apple defines these as live updates, not stream recreation ([`RecordingCoordinator.swift`](../../Recording/RecordingCoordinator.swift#L682), [Take ScreenCaptureKit to the next level](https://developer.apple.com/videos/play/wwdc2022/10155/)).

This means a stream that continues emitting `.idle` callbacks over an old surface can stay “healthy” indefinitely, and a new recording can be declared started without app-level evidence of a fresh screen image.

### Live preview and streaming

The preview/streaming path does create an `SCStream` with a delegate, rejects non-`.complete` images, tracks stream generations, and waits for a current-generation `.complete` program frame before publishing ([`LiveSceneCoordinator.swift`](../../StudioRecorder/Preview/LiveSceneCoordinator.swift#L265), [`LiveSceneCoordinator.swift`](../../StudioRecorder/Preview/LiveSceneCoordinator.swift#L363), [`LiveSceneCoordinator.swift`](../../StudioRecorder/Preview/LiveSceneCoordinator.swift#L958)).

It deliberately preserves the last preview frame while changing audio/pipeline state and restarting the preview stream ([`LiveSceneCoordinator.swift`](../../StudioRecorder/Preview/LiveSceneCoordinator.swift#L350)). That is acceptable as transitional UI only while the app visibly says it is preparing. The preserved image must not be accepted as readiness evidence and must not enter a new recording as if it came from the new generation.

## Recommended implementation order

### P0 — gate local recording on current screen evidence

For every selected display:

1. query `SCShareableContent.current`;
2. create a new filter, configuration, stream, stream generation, and delegate;
3. add the screen `SCStreamOutput`;
4. call `startCapture`;
5. wait up to a bounded deadline for `.started` and then a valid `.complete` frame from that generation with `displayTime >= startRequestHostTime`;
6. if the gate fails, stop and fully rebuild once from a new `SCShareableContent.current`;
7. if it fails again, do not start recording; explain that the selected display did not produce a current frame;
8. once the gate passes, add `SCRecordingOutput` to the already capturing stream and wait for `recordingOutputDidStartRecording`.

Apple documents that `SCRecordingOutput` begins asynchronously and exposes start/failure/finish delegate callbacks; `stopCapture` stops both stream and recording, while removing the recording output stops only recording ([Capture HDR content with ScreenCaptureKit](https://developer.apple.com/videos/play/wwdc2024/10088/), [SCRecordingOutputDelegate](https://developer.apple.com/documentation/screencapturekit/screcordingoutputdelegate), [addRecordingOutput](https://developer.apple.com/documentation/screencapturekit/scstream/addrecordingoutput%28_%3A%29)).

This order delays the recording file by the short preflight interval, which is preferable to producing a file whose screen freshness was never established.

### P0 — observe terminal failures and old frames

- Set the recording coordinator as every local stream’s `SCStreamDelegate`.
- Treat `userStopped` as intentional; every other stop invalidates that stream generation and interrupts or segments the recording.
- Remove stream-to-source/generation mappings before stopping, then drain/reject queued callbacks from retired streams.
- Compare callback arrival time with `displayTime`; do not refresh health solely because an old callback arrived.

### P1 — bounded mid-recording recovery

Reapplying filter/configuration can be the first low-cost nudge, but if no fresh `.complete` frame follows, rebuild the stream. A true `stopCapture` also stops its `SCRecordingOutput`, so seamless mid-recording rebuilding requires a new recording segment and project-manifest continuity rather than pretending the same output continued ([Capture HDR content with ScreenCaptureKit](https://developer.apple.com/videos/play/wwdc2024/10088/)).

Do not add an unbounded restart loop. One start-time rebuild and the existing bounded runtime policy are enough until real fault telemetry shows otherwise.

## Acceptance evidence

The fix is not proven by unit tests alone. Capture these controlled cases with timestamped telemetry and inspect the raw screen track, not only the composited preview:

1. Start recording on a static desktop, then move/change windows after start. The gate may wait for the first `.complete`, and the file must show the later changes.
2. Record, stop, substantially rearrange windows, then immediately record again. The second raw track’s first accepted complete frame must have the second stream generation and a post-request `displayTime`.
3. Keep the preview alive between recordings. Confirm the local raw stream is still newly created and independently gated.
4. Force a retired-stream callback after rebuild in a test seam. It must be rejected by generation.
5. Simulate no callbacks, repeated old `displayTime`, `.blank`, `.suspended`, and `.stopped`. Each must block freshness and drive the bounded recovery/failure state.
6. Hold a sample long enough to create delivery latency in a test tool. Telemetry must expose increasing callback age instead of reporting the source healthy.
7. Trigger an actual terminal capture stop. `didStopWithError` must be visible and the recording must not silently continue with the last frame.

## Primary sources

- [Apple: Meet ScreenCaptureKit — WWDC22](https://developer.apple.com/videos/play/wwdc2022/10156/)
- [Apple: Take ScreenCaptureKit to the next level — WWDC22](https://developer.apple.com/videos/play/wwdc2022/10155/)
- [Apple: Capture HDR content with ScreenCaptureKit — WWDC24](https://developer.apple.com/videos/play/wwdc2024/10088/)
- [Apple: Capturing screen content in macOS](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)
- [Apple: SCStream](https://developer.apple.com/documentation/screencapturekit/scstream)
- [Apple: SCStreamOutput](https://developer.apple.com/documentation/screencapturekit/scstreamoutput)
- [Apple: SCStreamDelegate](https://developer.apple.com/documentation/screencapturekit/scstreamdelegate)
- [Apple: SCFrameStatus](https://developer.apple.com/documentation/screencapturekit/scframestatus)
- [Apple: SCStreamFrameInfo](https://developer.apple.com/documentation/screencapturekit/scstreamframeinfo)
- [Apple: SCShareableContent](https://developer.apple.com/documentation/screencapturekit/scshareablecontent)
- [Apple: SCRecordingOutput](https://developer.apple.com/documentation/screencapturekit/screcordingoutput)
