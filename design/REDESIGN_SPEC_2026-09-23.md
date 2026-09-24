# Studio Recorder redesign - revised editor A

Status, 2026-09-24: the user revised A to show AI chat on the left, the linked video/audio editor in the center, and transcript on the right at the same time. The interactive HTML is a design prototype, not shipped native functionality.

Sources: [observed UI inventory](CURRENT_APP_UI_INVENTORY_2026-09-23.md), [interactive editor](prototypes/editor-workspace-throwaway.html?variant=a).

Competitive design references: [verified UI patterns](COMPETITIVE_UI_PATTERNS_2026-09-23.md) and [product capability benchmark](../Docs/research/video-recorder-editor-design-benchmark-2026-09-23.md).

## Structure and visual language

Move Projects / Studio navigation, Settings, Jobs, project title, and Export into the top toolbar. In Editor, replace the wide left navigation with AI chat and replace right inspector tabs with a persistent transcript. Project details open from the toolbar. Keep preview, timeline, and original-media access.

Adapt gpt-taste to the accepted desktop workspace: precise hierarchy, legible controls and deliberate spacing. The user-selected minimal direction rules out landing-page heroes, random layouts, stock photos and decorative motion. Production uses native SwiftUI and system typography.

| Element | Proposed rule |
| --- | --- |
| Window | Existing 1260 × 820 default; 1080 × 700 minimum |
| Editor columns | Chat 290 / center at least 500 / transcript 280 points at minimum window width; panels resizable and collapsible |
| Typography | System font; body 13; supporting text 11–12; headings 13–16 semibold; monospaced time digits |
| Spacing | 4 / 8 / 12 / 16 / 24; aligned edges and thin dividers |
| Surfaces | Flat neutral chat/content/transcript with thin dividers; no decorative gradients or heavy shadows |
| Color | Monochrome controls, timeline and audio; restrained red only for recording, errors and timing review; every state also has text or shape |
| Corners | 3–6-point controls; plain media frame; native defaults where appropriate |
| Motion | Minimal state feedback only; no looping decoration; respect Reduce Motion |

Prototype colors are illustrative. Production uses semantic colors and measured contrast: 4.5:1 for normal text, 3:1 for control boundaries/focus indicators.

### Minimalism rules

1. Show one clear primary action per surface: Record in Studio, Export video in Editor, Apply in a reviewed proposal. Other actions use quiet text buttons.
2. Use labels and spacing to group controls. Add a border only where it separates regions or defines an input. Avoid badges, decorative icons, shadows and nested cards.
3. Keep source time, output time, saved state and job stage explicit in text. Do not compress these into color-only dots.
4. Keep preview, adjacent video/audio tracks, chat, transcript, and current action visible. Open project metadata from the toolbar.
5. Use a neutral illustrative frame in mockups; real media provides visual richness in the product. Do not place marketing copy inside the preview.
6. Assistant is a persistent left conversation with selection scope and a fixed composer. Show one proposed media edit at a time, highlight it across both tracks and transcript, and require Apply.

## Screen inventory and proposed changes

| Screen | Preserve | Update |
| --- | --- | --- |
| Projects | Search, latest/recent recordings, Reveal, New Recording | Consistent thumbnail/title/duration/status rows; progress opens job; failures expose Retry |
| New Recording | Name, profile, Create/Cancel | Clear resolution/fps/retention summary; explicitly named Studio destination for Manage Profiles |
| Studio | Canvas, scenes, sources, transport | Group source controls; consistent selection; keep popovers inside window; sticky recording controls |
| Active recording | Timer, pause/stop, source health | Keep recording primary; separate job indicator; short safe-close state before next recording |
| Editor | Preview, editing, metadata, raw sharing | Top navigation and Export; left chat; center preview and adjacent linked video/audio tracks; right transcript; toolbar project details |
| Recording Controls | Compact/expanded modes, capture exclusion | Consistent toggle states; always visible timer and Stop; preserve capture exclusion |
| GIF Maker | Range, presets, preview, result actions | Clear Source → Range → Result progression; inline progress/error; retain no-audio explanation |
| Settings | Existing five tabs | Consistent forms; distinguish defaults from active Studio values; add Transcription/AI settings with implementation |
| Recovery | Packages, diagnostics, Recover/Reveal/Trash | Distinguish interrupted jobs from damaged media; show next action; preserve destructive confirmation |
| Permissions | Existing repair flow | Missing permission, affected action and direct repair; retain usable app areas |

## Editor A

Top toolbar: Projects, Studio, project title, project details, New Recording, Jobs, Settings, and Export video. Export queues a snapshot of the current edit revision; later edits do not silently change that export.

Center: preview/transport, then one ruler and two immediately adjacent lanes: program video above program audio waveform. Both lanes share output time, playhead, zoom, selection, and non-destructive cuts. Dragging on either lane selects both; Delete removes both. Keep selection actions beside the tracks. Keep Zoom/Privacy as contextual tools in the native editor. Distinguish original sharing from edited export.

Right transcript remains visible alongside chat. It shows edited playback order and derived output time while each word retains its source-time anchor. Click selects a word and seeks; Shift-click extends a contiguous range. Production also supports keyboard and drag selection and text copy. Removed words remain inspectable separately. Uncertain word bounds require timing review before transcript-driven deletion.

Left chat shows history, current selection scope, quick examples, and a composer fixed at the bottom. AI can suggest reviewed cuts and rearrangement of recorded picture/sound, analyze sentences, draft retake wording, and propose titles/descriptions. Rephrased words are text only and do not replace recorded speech. At 1080 × 700 both side panels remain open by default; users can resize or collapse either.

Show cuts marks removed words with strike-through and source intervals with hatching. Silence can appear as a selectable duration entry. Output playback closes gaps. Undo/Redo restores text, ranges and duration together. Highlight the exact range and all affected words before a manual cut crossing word boundaries. [VEED's Edit by Script](https://support.veed.io/en/articles/11137955-how-to-use-our-edit-by-script-tool) provides a concrete reference for visible/restorable deletions and silence entries.

## Transcript states

| State | UI contract |
| --- | --- |
| No transcript | Opening Editor requests transcription when prerequisites are satisfied; explicit Transcribe also available; explain local processing |
| Preparing | Model download progress, disk/network errors and recovery; editor remains usable |
| Transcribing / aligning | Distinct stage labels; text without valid timing is not cuttable |
| Ready | Searchable words and source times; reopen uses saved transcript |
| Timing review | Dotted word plus label; block word cut; waveform audition and adjustable start/end |
| Failed / interrupted | Preserve usable saved results; explain stage and offer safe Retry |
| No speech | Clear no-speech state; manual waveform editing remains available |
| Cleanup failed | Preserve successful transcript; retry deleting task model assets separately |

Every cuttable word needs a persisted source start/end. UI confirmation alone does not establish acoustic accuracy. Prototype numeric fields only demonstrate the confirmation flow.

## Background jobs

Show project, type, stage, measurable progress and error. Use indeterminate progress when completion cannot be measured. States: Queued, Preparing, Running, Recovering, Completed, Failed, Cancelled. Retry failed jobs; expose cancellation only at supported safe boundaries; completed export offers Open/Reveal. Closing Jobs does not cancel work.

Recover persisted jobs after restart and reconcile existing outputs before retries. Background tasks continue during recording as requested. Bound heavy-worker concurrency and prioritize capture without automatic pauses. Disk-full and failed track closure must never produce a false Ready state.

## Silence and AI

Find gaps uses detected silence, threshold/minimum-duration controls, waveform review, total time removed and protected boundaries. Apply reviewed ranges through the same edit/Undo mechanism.

Keep existing local commands separate from AI actions. OpenRouter uses the user's key stored in Keychain. Before sending, show the selected text scope and provider. Send transcript text and required timing identifiers by default, not media. Never show the stored key or log it.

AI returns reviewable proposed cuts or editable title/description alternatives. It does not provide authoritative word timings. Suggestions require review before applying; show whether a proposal came from silence detection or AI.

The Assistant must expose a bounded set of typed operations rather than an unlimited promise to edit everything: propose transcript cuts, suggest silence ranges, rearrange retained audiovisual phrases, propose supported layout changes when editable tracks exist, and draft metadata or retake scripts. Each media operation has project revision, source ranges, validation, and an Undo path. Show proposed changes on both lanes and transcript before Apply, with Refine and Dismiss. Text drafts cannot be applied as spoken-media changes. Unsupported requests explain the capability or source-track limit. This interaction takes cues from [Kapwing Kai](https://www.kapwing.com/ai/video-assistant), [VEED AI Agent](https://www.veed.io/tools/video-gpt/ai-video-assistant), and [Filmora AI Mate](https://filmora.wondershare.com/ai-copilot-editing.html).

## Retention and source truth

Program movie only retains the composed movie as edit source; independent screen/camera controls are unavailable. Editable tracks exposes existing independent-track controls. Do not promise recoverable stems for program-only projects.

Keep edits separate from original media. Word intervals and manual edits use source time; output playback/export uses an explicit mapping. Persist revisions and transcript provenance. The download-per-task decision includes ASR and alignment models; preparation, cancellation and cleanup need truthful states.

## Validation before native implementation

- Review 1260 × 820 and 1080 × 700 in dark/light; confirm both side panels, preview, adjacent lanes, transcript footer, and primary actions remain reachable.
- Check VoiceOver, tab order, word/range announcements and keyboard equivalents for dragging.
- Measure contrast; check increased contrast, Reduce Motion and non-color selection cues.
- Review long titles, mixed Ukrainian/English, transcript overflow, empty/error/offline states.
- Verify real queue recovery, simultaneous recording/jobs, disk-full and export revision consistency.
- Verify audible and visible cut boundaries on real media; the prototype cannot prove synchronization or timing accuracy.

## Delivery sequence

1. Visually review revised editor A at both window sizes: chat usability, timeline height, linked lanes, and transcript legibility.
2. Apply native visual tokens and fix observed Studio popover clipping.
3. Implement durable queue, global Jobs and persistent export.
4. Connect word-timing benchmark and transcription lifecycle to transcript-panel states.
5. Implement synchronized transcript/waveform editing and audition.
6. Add silence review, then OpenRouter suggestions and metadata tools.

The interactive artifact includes sample Projects, Studio, revised Editor A, Settings, and New Recording states. Its media, transcript, jobs, and chat proposals are illustrative; no production Swift code changed. Browser URL policy prevented automated rendered review of the local HTML.
