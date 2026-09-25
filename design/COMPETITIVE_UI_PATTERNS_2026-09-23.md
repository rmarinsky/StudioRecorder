# UI references for StudioRecorder

Researched 2026-09-23. Revised 2026-09-24 after user review: the editor keeps preview and adjacent video/audio tracks in the center, AI chat on the left, and a persistent transcript on the right. These references inform the layout; they do not establish that every competitor supports every feature.

## Products worth opening

| Product and official example | What to inspect | Fit for StudioRecorder |
| --- | --- | --- |
| [Tella Layouts V2](https://www.tella.tv/video/layouts-v2-1-6yp6) and [Custom Layouts](https://www.tella.tv/video/cmi4tg61d002t04l8594odzyj/view) | Base layout plus timed layout segments; direct canvas selection, reusable screen/camera arrangements, timeline control | Reference for recorded-scene and presentation editing when independent tracks exist |
| [Tella Auto Cut](https://www.tella.tv/video/introducing-auto-cut-1i2h) and [Tella changelog](https://www.tella.tv/changelog/page/4) | Inline suggestions with individual/batch acceptance; selected transcript text can create a new clip; word cuts can include surrounding silence | Reference for reviewed AI cuts and explaining how adjacent silence is handled |
| [VEED Edit by Script](https://support.veed.io/en/articles/11137955-how-to-use-our-edit-by-script-tool) | Script panel, struck removed words, Show Deleted / Restore, pauses as duration entries, threshold-based silence removal | Closest concrete reference for word, sentence and gap review |
| [Kapwing Trim with Transcript](https://www.kapwing.com/help/how-to-use-trim-with-transcript/) | Transcript tab, word-level selection and Delete mapping to video | Reference for simple text selection and explicit cut feedback |
| [Kapwing Kai](https://www.kapwing.com/ai/video-assistant) | Conversational edits linked to project/timeline and follow-up prompts | Reference for context-aware AI requests and editable results |
| [Camtasia + Audiate](https://support.techsmith.com/hc/en-us/articles/39967435209485-Using-Camtasia-Audiate-with-Camtasia-Editor) | Suggested fillers/pauses, text edits synchronized back to the timeline | Reference for visible handoff between transcript and media edits |
| [Camtasia Rev media](https://support.techsmith.com/hc/en-us/articles/41262572834829-How-do-I-Make-a-Video-With-Camtasia-Editor) | Combined package versus unpacked screen/camera/audio tracks | Reference for explaining source retention choices; Camtasia's combined Rev package is more editable than StudioRecorder's current Program movie only output |
| [VEED AI Agent](https://www.veed.io/tools/video-gpt/ai-video-assistant) and [Filmora AI Mate](https://filmora.wondershare.com/ai-copilot-editing.html) | AI entry point in editor toolbar or clip context menu; results previewed on timeline; explicit unsupported-action feedback in Filmora | Reference for an assistant that acts on current selection with honest capability limits |

## Important vocabulary distinction

OBS/Ecamm style **recording scenes** switch live sources and composition during capture. Tella's **layout segments** change the presentation over the recorded clip. Descript's **Scenes** are editorial units. These are related but different objects. StudioRecorder already has live saved scenes; the editor should call subsequent changes `Layout` or `Presentation` unless the same capture scene is truly editable in the recording. [Tella Layouts V2](https://www.tella.tv/video/layouts-v2-1-6yp6), [Camtasia Rev media guide](https://support.techsmith.com/hc/en-us/articles/41262572834829-How-do-I-Make-a-Video-With-Camtasia-Editor).

## Applied layout recommendation

```text
Top: Projects · Studio · project title        Jobs · Settings · Export
┌──────── AI chat ────────┬──────── Edited program ────────┬──── Transcript ────┐
│ Conversation and scope  │ Preview and playback            │ Timed words        │
│ Proposed edit + Apply   │ One ruler                       │ Search and select  │
│ Fixed composer          │ Video lane                       │ Pause entries      │
│                         │ Audio waveform directly below    │ Removed content    │
└─────────────────────────┴─────────────────────────────────┴────────────────────┘
```

Keep chat and transcript visible together even at minimum window width; make each side panel resizable and collapsible. A selected word or media range becomes visible chat scope. A proposed media edit highlights the same range on both tracks and the transcript. [VEED AI Agent](https://www.veed.io/blog/introducing-ai-agent-by-veed), [Kapwing Kai](https://www.kapwing.com/ai/video-assistant).

Transcript should show spoken words, optional silence entries, and removed content in place. Search and selection must work across long recordings. A cut preview states exact source in/out, resulting duration and whether audio/video are linked. A bad word boundary opens waveform audition and repair. The transcript can remain readable while an export or transcription job runs. [VEED Edit by Script](https://support.veed.io/en/articles/11137955-how-to-use-our-edit-by-script-tool), [Kapwing Trim with Transcript](https://www.kapwing.com/help/how-to-use-trim-with-transcript/).

AI should operate on explicit tools: propose cuts, find gaps, change output preset, choose a recorded layout where tracks exist, and draft titles/descriptions. Each action needs project/selection scope, parameters, permission to run and a proposed edit list before application. Show `Apply`, `Refine`, and `Dismiss`; applying uses the same non-destructive edit model and Undo as manual editing. A general LLM alone cannot guarantee that every requested operation is available; the chat must say when a project lacks independent tracks or an edit is unsupported. [Filmora AI Mate](https://filmora.wondershare.com/ai-copilot-editing.html), [Tella Auto Cut](https://www.tella.tv/video/introducing-auto-cut-1i2h).

Concrete prototype interaction: select a sentence at output time 01:12–01:18, ask the left chat to remove the long pause, and inspect highlighted ranges on both adjacent tracks and the right transcript. After Apply, edited transcript order and output duration update; Undo restores the prior edit. A request to change an independent camera source in a Program movie only project receives a retained-source explanation. This is a StudioRecorder design derived from the references, not a claim about competitor behavior.

## Design questions to settle in the next visual prototype

1. Can 290-point chat, 280-point transcript, and at least 500-point center remain usable together at 1080 × 700?
2. Are video and audio visibly adjacent, with the same selection when dragged from either lane?
3. Does the user understand `source time` versus shortened `output time` after several overlapping cuts?
4. Are silence entries readable in the transcript without making normal text too dense? Check 0.3 s and multi-second gaps.
5. Can Program movie only projects clearly refuse requests to alter separate screen/camera tracks while still allowing all program cuts?

All products above were verified from first-party material. Documentation demonstrates intended UI and capability; it is not a hands-on usability test of those products. Commercial pages may show idealized states. Perform rendered comparison in each app before copying precise spacing or interaction details.
