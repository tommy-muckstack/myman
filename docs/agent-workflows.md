# Agent workflow recipes

These commands run on the user's Mac with MyMan **1.1.62+** and the **0.6.0** companion. Use the host's approved Local Computer execution, not a cloud shell. Each recipe is a response to a human request. Run `myman doctor --json` and `myman actions --json` first. `source: running_app`, `live: true` confirms discovery from the installed app; permissions remain separately controlled. `actions --offline` reads bundled documentation and never claims current availability.

## Screenshot lettering → matches → font file

1. Use your host to show the requested page/window. Discover it with `myman windows list --json`, then capture it:

   ```sh
   myman screenshot --mode agent --window-id WINDOW-ID --json
   myman capture targets --id SHOT-ID --query "Sample heading" --json
   myman font match --id SHOT-ID --region 40,80,900,180 --json
   ```

   Replace the region with returned original-image pixel geometry covering a consistent typeface. Capture more distinct letters when the sample is sparse. Matches are ranked distances among the bundled styles; lower is closer, not a probability. The result states the catalog size and compared-character counts. Do not claim the top candidate is the original font.
2. Generate from the same sample:

   ```sh
   myman font create --id SHOT-ID --region 40,80,900,180 --name "Heading study" --json
   myman font preview --id NOTE-ID --text "The user's intended text 0123456789" --json
   myman font file --id NOTE-ID --json
   ```

   Keep the returned font-note ID. The workbench opens while processing but requires no clicks. `--captured-only` omits inferred letters; normal completion labels them as approximations. Inspect `attachment.preview_path`, `coverage`, `provenance`, and `missing_from_specimen`. The specimen uses the actual generated OpenType bytes; missing characters may show replacement glyphs. This is a generated approximation, not recovery of the original font file.
3. Return the `.otf` at `attachment.path` through the requesting host's attachment mechanism, optionally with the specimen PNG and a short explanation of unsupported/approximate characters. MyMan returns local files; it does not send messages or install fonts.

## Illustrated note or walkthrough

```sh
myman note create --title "Release walkthrough" --body "## Overview" --json
myman annotate --id SHOT-ID --ops '[{"op":"callout","target_text":"Save","number":1,"text":"Save the change"}]' --preview --json
```

Inspect the preview, then repeat without `--preview` to save the annotated screenshot. Attach that returned screenshot ID:

```sh
myman note attach --id NOTE-ID --source-id ANNOTATED-SHOT-ID --alt "Save the change" --json
myman note append --id NOTE-ID --body "The screenshot shows the saved settings." --json
```

`note attach` also accepts an absolute local `--path`, and optional `--expected-updated-at` from the current note. It copies the image into the note's managed assets and appends Markdown atomically with respect to note edits. Source deletion leaves the note's copy intact; deleting the note cleans up its owned assets. Use Markdown for headings, lists and tables. Avoid overwriting concurrent human edits; `note update` requires a revision.

## Find vaguely remembered content

```sh
myman library search --query "registration pricnig" --kind screenshots --limit 20 --json
myman library search --query "that screenshot of pricing last week" --json
```

Native search shares the UI's exact, prefix, typo and semantic ranking. Exact matches precede semantic matches. Explicit `--kind`, `--after`, `--before`, `--theme`, and `--pinned-only` constrain results; inspect the returned applied filters. `--lexical-only` skips fuzzy/semantic expansion for a quick first pass. Semantic processing follows the user's existing setting and local model availability. Quoted phrases are not semantically expanded.

Follow `next_offset`, and read the result's source ID with `library read` before claiming what an item says. `partial: true` marks the 1,000-result bound. Brain MCP and bare `search` stay read-only keyword retrieval and work from existing exports with the app closed. Use `library search --offline` explicitly for that fallback; `--root` selects an exported Brain only in offline mode.

## Capture and return a short demo

```sh
myman record start --window-id WINDOW-ID --max-duration 30 --mic off --system-audio off --json
myman record result --session-id SESSION-ID --json
```

Use the host to perform the requested demonstration. Retain the session ID, optionally pause/resume, and stop explicitly or let the app's duration limit finish the take. Poll until `finalized`; inspect `record frames --id RECORDING-ID --count 6`. Use `record export --id RECORDING-ID --start 1 --end 8 --max-bytes 20000000` when a trimmed MP4 is requested. Return the final attachment, not a growing capture file. See [media commands](https://github.com/tommy-muckstack/myman/blob/main/docs/agent-cli.md#window-recording-pause-inspection-and-export) for bounds and audio behavior.

## Recover after a disconnect or app restart

```sh
myman jobs --json
myman job REQUEST-UUID --json
myman record result --session-id SESSION-ID --json
```

Use the original IDs. `--request-id UUID` deduplicates a request while its receipt is retained, including across restarts. A prior ID with different arguments fails. Completed job results persist; unfinished jobs become `interrupted` on restart. An app crash between saving an artifact and recording completion may leave the receipt interrupted: inspect the library rather than silently repeat a mutation. Starting a recording successfully does not guarantee finalization; its named session result is authoritative.

Receipts live outside Brain in owner-only Application Support, for up to seven days, capped at 256 terminal jobs and 32 recording sessions. Inline results above 64 KiB are replaced with artifact references where available. Temporary preview paths are marked expired after restart; regenerate previews with `font preview`, `record frames` or `annotate --preview`. Deleting/excluding content redacts retained results and clears recording receipts. No automatic retries or background tasks are scheduled by recovery.

When a result says `recovery_persisted: false`, it was returned in memory but could not be durably saved; retain its artifact ID/path in the host. Requests fail before execution when a start receipt cannot be saved. Old requests beyond retention cannot be deduplicated; never use expiry as a reason to replay unknown work.

## Companion 0.7.0: comparison, word markup, video finishing and quality

Use a running app that advertises the following commands. Public 1.1.64 predates them; installing the plugin alone does not update the app.

```sh
myman wait --id SHOT-ID --stage ocr --timeout 120 --json
myman capture targets --id SHOT-ID --query '$49' --granularity word --json
myman annotate --id SHOT-ID --ops '[{"op":"circle","target_region":"WORD-ID"}]' --preview --json
myman capture compare --before-id BEFORE-ID --after-id AFTER-ID --ignore-rects '[[0,0,120,30]]' --json
```

Inspect the preview. The comparison returns a temporary image and changed OCR lines. It requires equal-size images and is not a functional test. Ignored areas are omitted from difference analysis, not securely removed from the image.

```sh
myman record export --id RECORDING-ID --start 0 --end 8 --edits '[{"type":"title","start":0,"end":1,"text":"Updated checkout"},{"type":"step","start":1,"end":3,"number":1,"text":"Choose your plan"},{"type":"caption","start":3,"end":5,"text":"Your selection is saved"},{"type":"zoom","start":5,"end":7,"rect":[100,100,400,300]},{"type":"redact","start":0,"end":8,"rect":[600,20,150,40]}]' --json
myman record frames --id EXPORTED-ID --count 8 --json
myman wait --session-id SESSION-ID --timeout 120 --json
myman wait --job-id ORIGINAL-JOB-UUID --timeout 120 --json
myman font quality --id FONT-NOTE-ID --text 'Your intended text 0123456789' --json
```

Adjust times and rectangles to the returned video dimensions/duration. Edit times always refer to the original recording, even after trimming. A title replaces the picture during its interval; it does not add time. Zoom is a fixed crop, not object tracking. Redaction covers only explicitly selected pixels/times and leaves audio unchanged. Inspect exported frames and attach only the final file requested by the user.

Font quality includes an actual-font specimen, per-letter evidence and `capture_next`. Capture those letters at a larger size in the same typeface and weight when the user wants a better reconstruction. A supported sample is evidence, not a guarantee of a perfect font.

## GrokBot end-to-end acceptance recipe (requires host access)

On the registered Mac, run live discovery and confirm these actions exist. Use a dedicated synthetic test window, with no private content. Ask GrokBot:

> Use MyMan on my Mac to capture the test window, locate one word, create a markup preview and save it after inspection. Compare the original and marked-up screenshot. Record a five-second demo of that window with microphone and system audio off, wait for its finalized result, export it with a title and caption, inspect its frames, and return the final image and video as attachments. Report any unsupported tool or permission rather than switching to my full display or replaying work.

Verify tool discovery, the selected Mac, actual attachment delivery, and cleanup of the synthetic test artifacts. Local CLI/MCP tests cannot prove these host behaviors. No GrokBot execution tool is available in the current development environment, so this recipe remains unverified until run in GrokBot.

## Multiple agents

See [four collaborative workflows and executable recipes](multi-agent-workflows.md). Use neutral role names or names explicitly supplied by the user. Companion 0.8.0 adds credential-bound identities, source bundles, guarded edits, recording ownership, temporary leases and explicit handoffs. Hosts schedule their own work and target the intended Mac; MyMan never launches other agents or sends messages.
