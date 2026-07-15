# Google Stitch prompts

Attach or paste [`DESIGN.md`](DESIGN.md) as the design-system context before using any screen prompt. Generate desktop application screens at **1440 × 900 px**. This is a native macOS tool, not a responsive website or landing page.

## Shared system instruction

> Follow DESIGN.md exactly. Preserve a 52 px integrated macOS title bar, 216 px sidebar where specified, warm charcoal surfaces, SF Pro or Geist fallback, and Signal Coral as the only accent. The media preview must dominate. Use compact native controls, 0.5 px separators, restrained vibrancy, and no generic dashboard cards. Do not invent features outside the requested screen.

## Permission diagnosis

> Generate the first-launch permission diagnosis screen for Studio Recorder. Show Screen Recording and Microphone as required, Camera as optional and tagged “Next slice”. Explain the blocked state plainly and provide one primary action, “Open System Settings”, plus a secondary automatic recheck state. Keep this inside a native macOS window with no sidebar. Avoid a multi-step onboarding wizard.

## Projects

> Generate the Projects home screen. Use a 216 px sidebar with Projects active and Studio below it. Show one featured recent `.recordingproject` with a large 16:9 preview and precise metadata, then two compact editorial project rows. Include a contextual interrupted-recording banner leading to Recovery. Primary toolbar action: New Recording with shortcut hint. No equal card grid.

## Studio — ready

> Generate Studio Recorder ready to capture. Use sidebar / large 16:9 stage / 304 px inspector. The inspector shows two selected displays, system audio, microphone level, Camera disabled with “Next slice”, layout contract, 1080p adaptive 30 fps, HEVC, output folder, and storage estimate. Put one prominent Record control with ⌘R in the bottom control deck. The screen must answer what is captured, whether audio works, and where files go.

## Studio — recording

> Generate the live recording state using the same geometry as Studio ready. Lock source configuration and replace it with health signals: timer, healthy displays, live audio meters, journal writing, disk headroom, and zero dropped frames. Add a compact REC indicator and subtle Signal Coral inner edge around the preview. The sole primary action is Stop with ⌘R. No pause button because pause is not implemented.

## Project Editor — target state

> Generate the target-state non-destructive project editor. Keep Projects available in the sidebar. Place preview above and a multi-track timeline below, with the inspector on the right. Include program, two display tracks, microphone/system audio waveform, and transcript sentences tied to time ranges. Show Layout and Camera inspector sections, a visible “Target state” badge, and one Export action. The timeline is dense and technical, not a collection of cards.

## Recovery

> Generate a contextual Recovery review screen for one interrupted `.recordingproject`. Use a split list/detail layout. Detail exactly which display tracks finalized, which audio track is partial, the last journal event, and recovered duration. Primary action: Open Recovered Project. Secondary destructive action: Discard Package. Include a plain explanation of what was and was not recovered.

## Settings

> Generate a separate compact macOS Settings window for Studio Recorder. Use sidebar tabs General, Capture, Audio, Storage, Shortcuts. Show Capture selected with 1080p adaptive, 30 fps default, HEVC with H.264 fallback, cursor capture, output folder, and a note that settings cannot change during recording. Use native rows and controls, not cards.
