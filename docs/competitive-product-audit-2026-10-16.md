# MyMan competitive product audit

> This is the pre-implementation audit. See [implementation and verification status](competitive-workflows-progress.md) for the resulting changes and remaining release checks.

October 16, 2026

MyMan has the foundation for an excellent private Mac work assistant: capture, local speech recognition, source-backed meeting notes, search, and agent handoffs already coexist. The highest-value work is to complete the everyday journeys through those capabilities: dictate accurately into the current task, turn a meeting into the notes the person needs, and send a recording someone can easily watch.

The recommended order is **dictation correctness and personalization → useful meeting enhancement and cited chat → video sharing → transcript-based video editing**. A measured reliability baseline should accompany every stage. Feature presence alone does not establish best-in-class quality.

## Scope and evidence

This is a source and product-capability audit, with static inspection of installed application packages. It does not establish comparative recognition accuracy, live latency, or visual usability scores.

| Project | Inspected baseline | Relevant scope |
| --- | --- | --- |
| MyMan | `2ffc358`, October 14 | Swift app, Brain companion, sharing service, existing tests and verification records |
| LoomIsDead native | `7a3df8b`, October 16 | Recording controls, device selection, local library, direct-upload client |
| LoomIsDead web | `d3aec8a`, October 16 | Direct-upload endpoints, storage, watch page, comments and reactions |
| GranolaIsDead native | `7320e4b`, October 16 | Templates, enhancement, meeting chat, Quick Chat |
| GranolaIsDead web checkout | `65dbacf`, October 16 | Cross-meeting chat source and current project structure |
| WisprFlowIsDead | Local checkout `5ccbf88`, October 16 | Dictation pipeline, context terms, snippets, dictionary aliases, transforms and shortcuts |

The WisprFlowIsDead checkout had pre-existing edits to its parity and release documents; they were left untouched. Clone READMEs sometimes lag their source: LoomIsDead's native app and direct-upload backend exist despite older README gap lists. Recommendations below follow implementation evidence rather than marketing checklists.

The supplied yourappisdead.com address was unavailable from this environment. Local checkouts supplied all three comparison projects. Official Loom, Granola and Wispr Flow documentation supplied the current original-product references.

## What MyMan already has

Do not create duplicate implementations of these:

- Dictation already has deterministic spoken-number/domain formatting, app-specific tones, editable vocabulary, correction learning, bounded model cleanup, delivery verification, and recovery history. See [VoiceController](../src/Voice/VoiceController.swift), [DictationDelivery](../src/Voice/DictationDelivery.swift), and [DictationCleanup](../src/Voice/DictationCleanup.swift).
- Meetings already have bot-free capture, detection and calendar context, speaker correction, grounded claims and commitments, linked personal notes, live context from past captures, and recovery/checkpoint machinery. See [MeetingController](../src/Meetings/MeetingController.swift), [GroundedMeetingNotes](../src/Meetings/GroundedMeetingNotes.swift), and [MeetingContextStream](../src/Meetings/MeetingContextStream.swift).
- Recording already has screen/region capture, an agent window-capture path, pause/resume, webcam, mixed-audio MP4 export, trim/join, zoom, cursor polish, overlays and redaction. Several advanced edits are exposed through agents rather than the main editor. See [ScreenRecorder](../src/Capture/ScreenRecorder.swift), [RecordingPolishView](../src/Capture/RecordingPolishView.swift), [AgentVideoEdits](../src/Core/AgentVideoEdits.swift), and [AgentPolish](../src/Core/AgentPolish.swift).
- Themes, unified capture search, portable Markdown, source retrieval through MCP, and recorded briefs already connect these tools. MyMan's opportunity is to make those connections useful to a person without requiring CLI knowledge.

## Prioritized gaps

Priority is product judgment. Effort is relative: **S** means a focused local change, **M** spans several app components, and **L** requires a new durable subsystem or client/server work. These are not delivery estimates.

| Priority | Addition or update | Current gap | Effort |
| --- | --- | --- | --- |
| P0 | Preserve intent during voice corrections | “Scratch that” discards the entire earlier utterance | S–M |
| P0 | Retrieve the actual evidence for Brain chat | Matching documents become leading excerpts, which can omit the answer | M |
| P1 | Snippets, pronunciation aliases, contextual spelling | Vocabulary exists; reusable voice expansions and per-take field context are missing from the dictation pipeline | M |
| P1 | Notes guided by the person's notes and chosen template | Personal meeting notes are stored separately; final generation does not consume them | M |
| P1 | Scoped chat and saved recipes | Native chat is a beta surface without a first-class meeting/theme/person scope and structured citations | M–L |
| P1 | Share a playable recording | Current sharing publishes PNG/text/HTML, capped at 3 MB; it does not upload video | L |
| P1 | Make recording tools available in the UI | Agent editing exceeds what the Polish window exposes | M |
| P2 | Voice commands and reusable transforms | Internal text actions exist; global spoken editing of a selection is missing | M |
| P2 | Timed transcripts and transcript-driven cuts | Recording transcripts are plain text; there is no word-timed editing model | L |
| P2 | Language and microphone profiles | Qwen is forced to English and Apple recognition uses en_US; device/context behavior needs an explicit product contract | M–L |

P0 here means correctness work to prioritize before promoting the affected experience, not a claim of a production incident or security severity.

## Dictation

### Preserve earlier sentences during corrections

[DictationCleanup.applyVoiceCommands](../src/Voice/DictationCleanup.swift) takes only the substring after the last “scratch that.” For example, its current rule turns “Keep the first paragraph. Send it Tuesday, scratch that, send it Wednesday.” into “Send it Wednesday.” The first sentence is lost by construction.

Define correction scope explicitly: replace the current clause or sentence, preserve earlier completed content, and reserve a separate explicit phrase for clearing the whole take. WisprFlowIsDead's `Sources/FlowCore/Backtrack.swift` is a useful starting point, but its heuristics also need adversarial examples before adoption. This is a behavior change, so document it and preserve raw history for recovery.

Acceptance: multi-sentence dictation, corrections involving dates/numbers/names, literal mentions of correction phrases, and repeated corrections retain every unaffected clause. A model timeout must preserve the deterministic result.

### Add snippets, aliases and temporary context

WisprFlowIsDead supplies three concrete models worth adapting:

- `Personalization.swift`: snippets with spoken cues and expansions; dictionary entries with explicit misheard aliases, provenance and usage.
- `Context.swift`: bounded proper-name extraction from the focused field and window title.
- `DictationPipeline.swift`: composition of these features with cleanup and styles.

MyMan currently feeds cleanup the recognized text, tone, app bundle ID and existing vocabulary. Add a bounded, invocation-only context snapshot so an unfamiliar name visible in the current document can help spelling without becoming a permanent global vocabulary entry. Add personal snippets with import/export and explicit alias editing. Wispr Flow documents both [spoken snippet expansion](https://docs.wisprflow.ai/articles/5784437944-create-and-use-snippets) and [dictionary/snippet import](https://docs.wisprflow.ai/articles/8955301725-How-Do-I-Bulk-Import-Dictionary-Items-and-Snippets).

Do not transplant the clone pipeline unchanged: it expands snippets before dictionary/style processing, which can modify an expansion intended to be exact. Protect expansion spans from subsequent cleanup, prevent recursive expansion, and resolve overlapping triggers deterministically. Keep MyMan's existing verified delivery and focus-change handling.

Acceptance: signatures, multiline code, links, dollar signs and backslashes arrive exactly as saved; overlapping cues behave predictably; secure fields provide no context; changing apps mid-take cannot send a rewrite to the wrong field.

### Voice editing and latency

Add a distinct command shortcut for “make this shorter,” “turn this into bullets,” or a saved transform over a selection. [Wispr Flow Command Mode](https://docs.wisprflow.ai/articles/4816967992-how-to-use-command-mode) supports spoken editing using selected and current-field text. MyMan's [TextSelectionActions](../src/Core/TextSelectionActions.swift) currently provides internal copy/summarize/explain/note/task actions, a narrower capability.

Capture selection and field revision before inference, show the replacement for review when necessary, and verify the original field before insertion. Keep undo history. WisprFlowIsDead's `Transforms.swift` and command controller offer UI/data-model references; MyMan's delivery checks should remain authoritative.

For speed, first measure release-to-verified-insertion. [VoiceController.stopAndTranscribe](../src/Voice/VoiceController.swift) begins recognition after recording stops and chunks long takes afterward. Incremental recognition during the take could reduce the remaining work on release; it needs bounded resource use, stable finalization, and coexistence with meeting capture. Existing cleanup deadlines already solve part of this problem. Do not replace them with an unbounded rewrite.

## Meetings and memory

### Enhance the person's notes using a chosen format

GranolaIsDead has nine built-in templates in `mac/src/Notes/NoteTemplate.swift`, explicit rough-note input in `Prompts.swift`, and logic in `NoteEngine.keepOwnLines` to restore user-authored lines omitted by generation. It does not yet provide a custom-template editor. Granola itself distinguishes [templates that shape notes from recipes that produce further outputs](https://www.granola.ai/blog/meeting-recipes-repeatable-formats).

MyMan's [MeetingRecordingNote](../src/Meetings/MeetingRecordingNote.swift) saves an ordinary linked note, but [MeetingNotesService](../src/Meetings/MeetingNotesService.swift) builds its job input from transcript, summary, meeting kind, owner and participants. [GroundedMeetingNotes.generate](../src/Meetings/GroundedMeetingNotes.swift) does not load the linked personal note. A user can write what matters during a call without that writing guiding the final summary.

Add a versioned template model and explicit “Enhance my notes” behavior. Start with Auto, 1:1, stand-up, customer interview, sales discovery and hiring; allow editable sections and instructions. Include the personal-note revision and template revision in generation/cache guards. Preserve typed content exactly, distinguish it from transcript-backed claims, and retain MyMan's evidence validation for generated facts and tasks. Personal notes may contain private thoughts or hypotheses that should not be presented as something said in the meeting.

Acceptance: every typed bullet survives, changing a template cannot overwrite edits, late-meeting commitments remain included, uncertain owners remain uncertain, and deleted or revised inputs invalidate in-flight results.

### Fix retrieval before expanding chat

[BrainChat.answer](../src/Brain/BrainChat.swift) asks `SearchService` for six hits, then `sourceText` takes the beginning of each item. A meeting contributes only its first 1,000 summary characters and first 2,000 transcript characters. The combined context is truncated again to 12,000 characters. Thus a search hit can identify the correct meeting while the answer-bearing passage never reaches the model. This is separate from final meeting-note generation, which already processes source windows.

Return relevant chunks with adjacent context, stable source IDs, timestamps and revision information. Require structured citations in answers and resolve them to the exact source passage. Budget context by relevance and source coverage. For questions such as “What did we decide this week?”, enumerate the selected period and report incomplete coverage instead of treating six search hits as exhaustive.

Expose “Ask this meeting,” “Ask this Theme,” and person/date filters. Add saved recipes for follow-up drafts, decision changes, customer feedback and weekly commitments. Granola documents [chat across individual meetings, folders and people/company records](https://docs.granola.ai/help-center/getting-more-from-your-notes/chatting-with-your-meetings). GranolaIsDead's global chat is useful UI inspiration, but also caps selected notes and digests; it is not a retrieval engine to copy wholesale.

Acceptance: a question answered only near minute 55 succeeds with a clickable citation to that passage; contradictory decisions retain their dates; no-answer cases abstain; a selected scope cannot silently expand; follow-ups remain drafts until the person chooses an action.

## Recording and sharing

### Complete the recipient experience

[SharePublishing.publish(item:)](../src/Core/SharePublishing.swift) sends screenshots as PNG and other capture kinds as text. The [sharing service](../integrations/share-service/README.md) accepts PNG, plain text and inert HTML up to 3 MB. Sharing a recording's text is not a playable video link.

LoomIsDead has a useful end-to-end reference: native `ShareUploader.swift`, web `app/api/videos/direct/`, and `components/Watch.tsx`. The current direct-upload route supports up to 500 MiB, while its player includes seeking, speed controls, timestamped comments and reactions. This is a stronger source than its older README claim that all production uploads are limited to 4 MB.

Bring the upload/watch experience into MyMan as an optional publishing destination. Preserve local saving as the default. Show upload progress, cancel/retry state and a durable receipt; publish a link only after completion. Start with reliable playback, copied timestamp links, captions and expiry/revocation, then add optional comments and reactions.

The clone's storage contract needs adaptation: `lib/direct-upload.ts` expects public Blob URLs, and the media route redirects to them. MyMan's existing private service promises revocable, expiring access. Reuse the upload choreography and player concepts, but use private media delivery with access checks, upload ownership binding and durable cleanup. A watch-page deletion cannot revoke an already-known public storage URL. This difference is a concrete integration constraint.

Acceptance: a realistic multi-hundred-megabyte MP4 uploads, resumes or retries without duplicate publication, plays/seeks in Safari and Chrome, and handles network interruption. Expiry/revocation must reject subsequent media range requests as well as page loads. Previously downloaded copies remain outside revocation.

### Expose the existing editor and add timed transcripts

The native Polish window offers trim, backdrop, zoom and cursor controls. MyMan's agent paths already add captions, title/end cards, music, time-scoped overlays, redaction and joining. Expose these through one reviewable recording workspace before building another rendering engine. Add a clear source/device picker and camera-only recording as a later focused parity improvement; window capture already exists in the agent API, with a current webcam restriction.

The larger technical dependency is timing. [ScreenRecorder.transcribeMovie](../src/Capture/ScreenRecorder.swift) joins recognized audio chunks into plain text; the transcription API returns strings. Preserve timed segment/word data from an appropriate recognizer or alignment stage. Existing manually timed caption overlays are not automatic subtitles.

With timing in place, add click-to-seek transcripts, caption correction and SRT/VTT export, chapter boundaries, non-destructive multi-range cuts, and previewable silence/filler removal. Keep original media and an edit decision list; consistently retime audio, captions, cursor events and redactions. Loom documents [editing video by selecting transcript text](https://support.atlassian.com/loom/docs/edit-your-loom-video) and [automatic titles, summaries and chapters](https://support.atlassian.com/loom/docs/loom-ai-features/).

Acceptance: transcript seeks land near the spoken passage, captions stay synchronized after multiple cuts, undo restores the source, and redacted pixels cannot reappear after zoom/crop/export.

## Shared architecture and product focus

WisprFlowIsDead explicitly vendors MyMan's audio, transcription, paste and cleanup code. GranolaIsDead also uses closely related capture and writing-model patterns. Reconcile useful additions into MyMan first, then establish a small shared package or repeatable vendoring process for genuinely stable primitives. Keep UI and product storage models separate. Sharing the entire application would increase coupling without making any workflow better.

MyMan's best differentiator is a connected local workflow: meeting decision → linked screenshot or demo → reviewed follow-up or agent brief, with source evidence throughout. Improve entry points and results in the existing launcher/document windows. A new giant dashboard, mandatory account, broad autonomous agent, or full team-workspace backend is not needed for this first sequence.

Cross-device/mobile use and team collaboration remain meaningful competitive scope differences. They require separate sync, identity and ownership decisions; completing this Mac plan would not establish universal parity with all three original products.

Language support also needs explicit scope. The current Qwen path requests English and rejects CJK-dominant output; Apple recognition selects en_US, while spoken formatting is English-oriented. Add language profiles and engine-specific availability before advertising general multilingual dictation. Keep the English hallucination protections for the English profile rather than simply removing them.

## Delivery sequence and acceptance scorecard

1. **Correctness and baseline:** fix correction scope, recover answer-bearing chat excerpts, and restore a runnable test environment. Capture baseline timings and failure rates.
2. **Daily dictation:** add exact snippets and aliases, then invocation-scoped context. Benchmark before investing in incremental recognition. Add selection commands as a separate change.
3. **Useful meeting outputs:** include personal notes, add templates, then scoped cited chat and reusable recipes. Reuse existing decisions, context and task models.
4. **Video delivery:** expose existing editing controls and implement optional private video sharing. Add timed transcripts, subtitles and transcript editing as the next stage.

Proposed release criteria below are targets, not measured results from this audit:

| Journey | Proposed criterion |
| --- | --- |
| Warm dictation | p95 release-to-insertion at or below 1.5 s for a 10 s take on a declared reference Mac; report cold-load time separately |
| Dictation correctness | No silent loss of unaffected clauses, names, numbers or saved snippet contents in the acceptance corpus; track correction rate against the original app on the same audio |
| Delivery | Zero false “Pasted” claims or duplicate insertions in focus-change, delayed-field and opaque-editor cases; recovery available for every failed take |
| Meeting notes | All typed bullets preserved; no invented action owners/deadlines in adversarial fixtures; final five minutes represented in long-meeting tests |
| Chat | At least 95% answer-bearing retrieval on a fixed labeled set; every factual answer has a resolvable source; unsupported cases abstain |
| Recording | Mic and system sound survive export, pause/resume, interruption and device changes; no accumulating A/V drift in a 60-minute run |
| Sharing | Large upload failure recovery, mobile viewing, seek/range playback, expiry and revocation pass against the actual configured service |
| Everyday usability | Measure first successful capture, find-an-old-decision, dictate-and-correct, and record-to-share tasks with new users; compare task completion and time rather than screenshot resemblance |

Use the same synthetic audio/documents and declared hardware across comparisons. Include noisy/quiet speech, technical terms, Bluetooth route changes, several Mac text fields, and English plus each explicitly supported additional language. Extend existing verification hooks and fixtures instead of introducing a second overlapping test framework.

## Verification and reverse-engineering limits

The installed Granola **7.663.2** and Wispr Flow **1.6.1167** ASAR packages were inspected read-only. Granola's `gatherPromptInputsForDocument-RM0c0C79.js` consumes written notes and dictionary context; its schema includes selected templates, and separate modules expose citation and recurring-meeting recap paths. Wispr Flow's main package exposes selected-text capture and distinct command status, while its hub includes a snippet expansion editor and context-awareness controls. These corroborate architectural seams; bundled code or a feature flag does not prove availability for a particular account.

No personal app databases, session cookies, credentials or captured content were inspected. No proprietary implementation or assets were copied into MyMan. Loom was assessed through the clone code and official documentation; no installed Loom binary was available.

The supplied [REA project](https://github.com/morluto/rea) supports static JavaScript/Electron inspection and deeper native analysis. It was reviewed but not installed or executed. Direct ASAR inspection was sufficient for the questions above; deeper binary analysis would be useful only for a specific unresolved behavior, such as device-switch recovery or capture timing.

Focused MyMan tests were attempted for dictation formatting/delivery/latency, meeting faithfulness/acceptance, recording edits and share-ready MP4. Both normal and escalated runs stopped before test execution because Xcode could not verify the cached `Sentry.xcframework` signature. No test pass, performance measurement or original-app runtime comparison is claimed. Repair or re-fetch the dependency through the normal signed-artifact path before implementation; do not disable signature validation to obtain a green build.

Application source was left unchanged. This audit is the only added repository file.
