# YouTube Live preflight contract

Research date: 2026-07-15

## Recommendation

Ship preflight as an evidence report, not one optimistic green light. Use four explicit states:

1. **Ready locally** — capture permissions, sources, exact scene, encoder warm-up, audio contract, destination, and storage passed.
2. **Sending** — Studio Recorder established RTMPS transport and is emitting encoded bytes.
3. **YouTube receiving** — YouTube reports the bound stream as `active`.
4. **Live to viewers** — the broadcast lifecycle is `live`.

Google defines `active` as YouTube receiving data, while a broadcast becomes viewer-visible only after its lifecycle reaches `live`; its documented testing flow intentionally keeps the monitor stream private first ([LiveStream resource](https://developers.google.com/youtube/v3/live/docs/liveStreams), [Life of a Broadcast](https://developers.google.com/youtube/v3/live/life-of-a-broadcast)). Therefore the current transport-success state must be labelled **Sending**, not **Live**, unless Studio Recorder adds YouTube OAuth/API confirmation.

## Required checks

“YouTube requirement” below means a first-party rule. “Product gate” is a proposed Studio Recorder threshold where YouTube does not publish one.

| Check | Gate and threshold | Can Studio Recorder prove it locally? |
|---|---|---|
| Stream credentials | Block unless the endpoint is `rtmps://`, has a host, and the Keychain value is non-empty. Never print the key. YouTube recommends RTMPS and treats the stream key as the address/password for the feed ([encoder settings](https://support.google.com/youtube/answer/2853702?hl=en), [stream settings](https://support.google.com/youtube/answer/9854503?hl=en)). | Syntax and Keychain access only. A stale/wrong key or a channel not enabled for Live cannot be proven without publishing or OAuth. First-time Live enablement may take 24 hours ([encoder setup](https://support.google.com/youtube/answer/2907883?hl=en)). |
| Screen/camera/mic permission | Block for every enabled source whose permission is not authorized; name disconnected or busy devices. ScreenCaptureKit requires Screen Recording permission, and AVFoundation exposes camera/mic authorization plus device connectivity/use state ([ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit), [AVCaptureDevice](https://developer.apple.com/documentation/avfoundation/avcapturedevice)). | Yes. This is a deterministic local check. |
| Video contract | H.264, CBR, progressive, square pixels, Rec.709 SDR, no more than 60 fps, 2-second keyframes and never over 4 seconds ([encoder settings](https://support.google.com/youtube/answer/2853702?hl=en)). Product gate: inspect actual warm-up samples and require an IDR at start plus a maximum 2.1-second keyframe gap. | Yes, by warming the exact VideoToolbox/HaishinKit configuration and inspecting emitted format descriptions, attachments, timestamps, and keyframe cadence. Creating a VideoToolbox compression session alone proves availability, not sustainable encoding ([VideoToolbox compression session](https://developer.apple.com/documentation/videotoolbox/vtcompressionsession-api-collection)). |
| Audio contract | YouTube requires exactly one ingested audio stream; H.264/AAC, stereo AAC at 128 Kbps and 44.1 kHz matches its published contract. No audio and multiple audio streams are ingest errors ([error messages](https://support.google.com/youtube/answer/3006768?hl=en)). **If both mic and system audio are disabled, inject one silent AAC stream or block streaming.** | Yes, by inspecting the muxed output. Separate editable/raw inputs are fine, but the RTMP output must contain one mixed audio stream. |
| Bitrate/profile | Use the H.264 values below. Block a known preset below 80% or above 125% of its recommendation; warn outside 90–110%. These percentages are a Studio Recorder policy, not YouTube thresholds. YouTube itself reports `bitrateLow` and `bitrateHigh` ingest issues ([health issue types](https://developers.google.com/youtube/v3/live/docs/liveStreams/health_status_messages)). | Configuration is local; actual accepted bitrate is only known after ingest begins. |
| Full-load warm-up | Product gate: 15 seconds using the exact canvas, camera, background treatment, cursor effects, audio, and representative screen motion. Pass when at least 99% of target frames are composed, zero timestamps regress, and render p95 is below 80% of the frame budget (26.7 ms at 30 fps). Do not replace p95 with an average. | Yes. Warm-up proves local composition/encode headroom, not network or YouTube. |
| Capture-frame integrity | Count only valid ScreenCaptureKit buffers whose frame status is usable; surface stopped/suspended/blank separately instead of treating them as encoder drops. Apple provides frame-status metadata for this distinction ([SCFrameStatus](https://developer.apple.com/documentation/screencapturekit/scframestatus)). | Yes. |
| Local archive start | Before any actual YouTube publish, create the local archive, append the first video frame and one mixed audio frame, and require the writer to remain in `.writing`. AVAssetWriter exposes `.failed` and its error ([AVAssetWriter status](https://developer.apple.com/documentation/avfoundation/avassetwriter/status)). | Yes. A preflight scratch archive can prove start/finalization without contacting YouTube. |
| Storage | Confirm the destination is writable and query the destination volume’s important-usage capacity ([Foundation capacity API](https://developer.apple.com/documentation/foundation/urlresourcekey/volumeavailablecapacityforimportantusagekey)). Product gate: block below a 15-minute estimate plus 2 GiB; warn below a 60-minute estimate plus 2 GiB. For Stream-only, estimate from configured video + 128 Kbps audio + 5% container overhead; Record + Stream must add all raw-track estimates. | Yes, but capacity can change during the stream. Continue monitoring and warn at 15 minutes estimated remaining. Using the capacity API requires the matching required-reason privacy declaration. |
| Network path | Require an `NWPath` that is satisfied and supports DNS; warn for constrained/expensive paths and show Ethernet/Wi-Fi/other. Apple explicitly treats path state as connection-attempt capability, not proof that a specific connection will succeed ([NWPath](https://developer.apple.com/documentation/network/nwpath)). | Path and interface only. It cannot validate upload capacity, YouTube reachability, the stream key, or sustained routing. |
| Upload headroom | YouTube says to run a speed test and choose a quality the connection can reliably sustain ([encoder settings](https://support.google.com/youtube/answer/2853702?hl=en)). Product policy for an optional user-initiated sustained test: green at p10 upload ≥1.5× total configured bitrate, warn at 1.2–1.5×, block or offer a lower profile below 1.2×. | A generic speed test is indirect and must not produce “YouTube ready.” This review found no first-party dry-run endpoint that validates YouTube ingress without sending a stream. |
| YouTube ingest health | With OAuth, wait for `status.streamStatus == active`; then require health `good` or `ok`, reject `bad`/`noData`, reject any severity `error`, and display every warning with YouTube’s reason. The API defines these states and configuration issues ([LiveStream status](https://developers.google.com/youtube/v3/live/docs/liveStreams), [health issue types](https://developers.google.com/youtube/v3/live/docs/liveStreams/health_status_messages)). | No with a manual stream key. All Live Streaming API methods require OAuth 2.0 ([authorization](https://developers.google.com/youtube/v3/live/registering_an_application)). Without OAuth, open Live Control Room and tell the user to confirm preview/health; do not claim verification. |
| Viewer-visible status | Only show **Live** when the broadcast lifecycle is `live`; `testing` is partner-only, and `liveStarting` is not yet confirmed. The API flow says the transition commonly takes 5–10 seconds and can take up to a minute ([Life of a Broadcast](https://developers.google.com/youtube/v3/live/life-of-a-broadcast)). | Only with OAuth or explicit confirmation from Live Control Room. A successful RTMPS connection is insufficient. |
| End/archive verification | Finish and reopen the local file; verify playable video, expected canvas, at least one audio track, monotonic duration, and duration within 1 second of the session. YouTube can auto-archive streams under 12 hours, including 4K, but recommends a local backup; streams over 12 hours may not be captured ([archive policy](https://support.google.com/youtube/answer/6247592?hl=en)). | Local artifact: yes. YouTube archive: no; remote processing is delayed according to stream length ([LiveStream resource](https://developers.google.com/youtube/v3/live/docs/liveStreams)). |

## YouTube H.264 profiles Studio Recorder should enforce

The app currently streams at 30 fps, so these are the primary choices. Values are YouTube’s published recommendations ([encoder settings](https://support.google.com/youtube/answer/2853702?hl=en)).

| Ingest class | Video bitrate | Minimum upload for green product gate (1.5× video + 128 Kbps audio) |
|---|---:|---:|
| 720p30 | 4 Mbps | 6.2 Mbps |
| 1080p30 | 10 Mbps | 15.2 Mbps |
| 1440p30 | 15 Mbps | 22.7 Mbps |
| 2160p/4K30 | 30 Mbps | 45.2 Mbps |

- **4K must use Normal latency.** Low and Ultra-low latency do not support 4K, and lower latency increases viewer sensitivity to encoder/network disruptions ([latency guide](https://support.google.com/youtube/answer/7444635?hl=en-GB)).
- For vertical 9:16, apply the class by pixel dimensions (for example, 2160×3840 is the 2160p/4K class) and require a real monitor-preview test. This mapping is a product interpretation because YouTube’s bitrate table is orientation-neutral.
- For 16:10 or custom canvases absent from YouTube’s table, use the closest equal-or-higher pixel class, show **Custom — YouTube test required**, and rely on auto-detection plus ingest health rather than implying official certification. YouTube says Live Control Room can auto-detect resolution and frame rate ([encoder settings](https://support.google.com/youtube/answer/2853702?hl=en)).

## Why a short green speed test is not enough

These are user reports, not platform requirements, but they identify failure modes the acceptance suite must reproduce:

- A user reported 100+ Mbps upload while YouTube still changed to “not receiving enough video” after several minutes ([Reddit, 2025](https://www.reddit.com/r/obs/comments/1o8o3u2/youtube_is_not_receiving_enough_video_to_maintain/)). Another reported 100+ Mbps in a speed test while the YouTube route fluctuated to 0–3 Mbps with 85–95% network drops ([Reddit, 2024](https://www.reddit.com/r/obs/comments/1anqld7/frames_instantly_drop_bitrate_fluctuates_from_0/)). This supports separating generic bandwidth, actual egress, and YouTube ingest health.
- A June 2026 report only reproduced buffering once other applications were active ([Reddit, 2026](https://www.reddit.com/r/obs/comments/1txwumi/youtube_livestream_through_obs_wont_stop_buffering/)). The warm-up must exercise realistic screen motion and camera/background work, not color bars alone.
- A June 2026 report stayed healthy for roughly 40 minutes before sustained upload collapsed ([Reddit, 2026](https://www.reddit.com/r/obs/comments/1uao74m/dropped_frames_please_help/)). Preflight reduces immediate failures; it does not replace one-hour horizontal, vertical, and 4K fault soaks.
- A user reported YouTube buffering/no-data while the local encoder showed almost no dropped frames ([Reddit, 2024](https://www.reddit.com/r/obs/comments/1ady5hi/youtube_stream_buffers_but_obs_doesnt_drop_frames/)). Local composition FPS must not be presented as YouTube health.

## Prioritized acceptance checklist

### P0 — honest and locally verifiable

- [ ] Replace transport-success **Live** with **Sending** unless YouTube confirms broadcast lifecycle `live`; do not enter **Sending** until RTMPS is connected and the first encoded video and audio packets have been submitted.
- [ ] Add one preflight sheet with blocking failures, warnings, measured values, and a fresh timestamp; rerun it whenever Scene, sources, output, bitrate, audio, or destination changes.
- [ ] Validate enabled permissions/devices, RTMPS syntax, Keychain access, preset/bitrate, writable destination, and projected free time.
- [ ] Run the 15-second exact-scene warm-up and report composed/dropped frames, render p50/p95/max, encoder output FPS, timestamp regressions, actual codec/profile/bitrate, and keyframe gap.
- [ ] Prove exactly one AAC audio stream; inject silence or block when the Scene has no enabled audio source.
- [ ] Start/finalize/reopen a scratch local archive before enabling actual publish.
- [ ] Make network-path and speed-test results warnings/evidence, never proof of YouTube readiness.
- [ ] If only a manual key is configured, explicitly require Live Control Room preview/health confirmation and warn that Auto-start can make a test feed public.

### P1 — first-party YouTube verification

- [ ] Add installed-app OAuth with least-privilege YouTube scope and secure token storage.
- [ ] Create/select a private or unlisted broadcast with monitor testing and Auto-start disabled; bind the stream before sending.
- [ ] Poll until stream `active`; then surface health status, last-update age, issue type/severity/reason/description.
- [ ] Permit transition to `live` only after `active` plus `good`/`ok` and no severity-error issues; show `liveStarting` until lifecycle `live`.
- [ ] On Stop, transition/confirm `complete`, then separately verify local archive and eventually remote recording status. Never call remote processing “finished” early.

### P2 — release evidence, not preflight UI

- [ ] One-hour 1080p horizontal, 1080p vertical, 4K horizontal, and 4K vertical soaks with representative motion, camera background removal, cursor effects, mic/system audio, and local archive.
- [ ] Repeat with bandwidth restriction, 5–30 second route loss, camera disconnect, microphone disconnect, display sleep/change, disk-low, destination removal, and forced app termination.
- [ ] Acceptance: no false **Live** state; local archive stays recoverable; reconnect never resets scene/cursor/audio timing; every degradation is timestamped; final A/V drift is bounded and measured.
- [ ] Keep the local archive mandatory-by-default even after YouTube archive verification because YouTube explicitly recommends it and does not guarantee streams over 12 hours.

## Current implementation consequence

Studio Recorder already matches the published static encoder contract closely: RTMPS, H.264 High, CBR, 30 fps, two-second keyframes, AAC 128 Kbps/44.1 kHz, 4K30 at 30 Mbps, reconnect, and a local archive. The highest-value next slice is therefore not another setting. It is the P0 evidence sheet plus truthful state naming, followed by OAuth-backed ingest/broadcast health. Until P1 exists, “YouTube verified” is impossible with the manual-key architecture.
