# Editor workspace prototype - revised A

Decision, 2026-09-24: AI chat is always on the left, preview and adjacent program video/audio lanes are in the center, and the transcript is always on the right. Projects, Studio, Jobs, Settings, project details, and Export are in the top bar. The old Details / Transcript / Assistant inspector tabs and audio disclosure were removed. Existing `?variant=a` links still open this prototype.

[Open prototype](editor-workspace-throwaway.html?variant=a) · [Redesign specification](../REDESIGN_SPEC_2026-09-23.md) · [Observed app inventory](../CURRENT_APP_UI_INVENTORY_2026-09-23.md)

The side panels start at 290 and 280 points, can be resized with pointer or arrow keys on their separators, and can be collapsed independently. At the 1080-point minimum width the center retains about 510 points. Both panels are open by default.

Try dragging on either media lane, selecting a word or pause on the right, Shift-clicking across words, pressing Delete, and using Undo/Redo. The same output-time selection is shown on video and audio. A cut removes the selected range from one shared piece list, and the transcript updates to the edited order with derived output times. The original source duration remains available in the model. The dotted-underlined word requires boundary review before deletion through the transcript.

The left conversation has a fixed composer and explicit scope. Its sample requests show pause removal, phrase reordering, sentence analysis, retake wording, and title/description drafts. Media proposals appear on both lanes and transcript before Apply. New wording is text only. Project details and original-media actions moved to an info dialog from the top bar; less common edit tools remain under Tools by the timeline.

This is a disposable design prototype. Preview artwork, waveform, word timing, assistant replies, jobs, and export are illustrative. It makes no recording, transcription, OpenRouter request, media render, or persistent project change; reloading resets its edit state. The native app must store the user's OpenRouter key in Keychain and validate real timing and synchronized output.

Run `node --test design/prototypes/editor-workspace.test.cjs` for model and structural checks. Automated rendered review of the local HTML remains blocked by Browser Use URL policy, so light/dark screenshots at 1260 × 820 and 1080 × 700 still need visual inspection in the user's open tab before translating this layout to SwiftUI.
