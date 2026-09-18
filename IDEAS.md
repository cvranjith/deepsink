# DeepSink — Phase 2 backlog

Not built. Each item below names the seam already left for it in the phase-1
code, per `requirement-deepsink-mobile.md` section 0's instruction to leave a
clean extension point rather than implementing ahead of scope.

## ~~Live loop (attention alert)~~ — built

Built as `LiveAssistEngine` (on-device Speech framework recognition, a
second isolated `AVAudioEngine` + tap, not the level-meter timer this note
originally guessed at) plus a configurable keyword list in Settings — see
the app's README. Topic watchlist and a continuously-updating rolling
summary are still open: the buffer `LiveAssistEngine` already keeps could
feed a watchlist match the same way keyword matching does, but nothing
watches for topics yet, only literal keywords.

## ~~Articulate (on-demand response generation)~~ — built

Built as `deepsink.articulate` + `ArticulateSheet`, using
`LiveAssistEngine`'s rolling on-device transcript as context rather than a
backend-held session transcript (see the app's README for why: it keeps
this stateless on the router/gateway side, same as every other service).
Not yet verified on a real device — the phone wasn't available this
session.

## Ask-anything over a session

New service ID `deepsink.ask`, transcript as context, **citations back to
specific transcript blocks are the important part** (per the original
review this was promoted from) — `TranscriptBlock` already has stable
`id`/`startSeconds`, so a citation can point straight at one.

## Note templates

Regenerate notes from the same transcript under a different template (key
takeaways / decisions and risks / technical detail / client-facing minutes).
Since prompts live in the router, this is a `service` or `options` parameter
on the existing `deepsink.notes` call, not new app logic — pairs with the
"re-run notes on existing transcript" path `SessionProcessor.retryNotes`
already implements.

## ~~Speaker diarisation~~ — built

Built as an on-demand "Detect Speakers" button on a finished session
(`SessionProcessor.diarize`), not automatic — diarization needs one pass
over a session's *whole* audio to get consistent speaker numbering
(a speaker label is only consistent within a single diarization run, so
per-chunk diarization would give different numbering in different
chunks), which is real CPU time for a long meeting. Uses `pyannote.audio`
running locally on the Mac mini in its own isolated Python environment —
see the app's README and `ai-gateway`'s own README ("deepsink_diarize
setup") for why it's isolated and the one-time HuggingFace token setup
this needs. `TranscriptBlock.speakerID` + `Session.speakers` (a
rename-able "Person 1"/"Person 2"/... map) is exactly the shape this note
originally guessed at. Not yet verified end to end with a real
HuggingFace token — the setup step was still in progress when this was
built; see the app's README for the exact remaining step.

## Transcript translation / multilingual display

Would sit alongside `Session.transcriptBlocks`, not replace it — keep the
original transcript and add a translated variant rather than overwriting.

## Cleanup pass ("tidy the transcript")

A separate router service that removes filler/fixes obvious ASR errors,
stored as its own field rather than overwriting `Session.transcriptBlocks` —
same reasoning as translation: never destroy the raw transcript.

## Webhook / automation out

A generic outbound webhook per session-completed event — natural
generalization of a second-brain push. `SessionProcessor.generateNotes`
already has one clear point (right after `session.state = .ready`) where a
"session just finished" hook would fire.

## Second-brain push

Once a specific target (Notion, Obsidian, etc.) is picked, `MarkdownExporter`
already produces the exact markdown shape (`- [ ]`/`- [x]` action items) most
note systems want — this becomes "send that string somewhere" rather than a
new export format.

## Cross-device sync

Explicitly out of scope — `Session`/`ActionItem`/`Marker` are plain
SwiftData models with no CloudKit container configured. Turning on
`.modelContainer(for:cloudKitDatabase:)` is the shape this would take, but
touches conflict resolution for the checkbox-toggle case (FR-4's "regenerating
notes must not wipe checked state" concern gets harder once two devices can
edit the same session).

## Desktop companion

Out of scope entirely — noted only because competitor tools (Otter, Bluedot)
differentiate on capturing meeting audio from the computer as well as the
phone.

## Recovering a session killed mid-recording

Not from the original review, but noticed while building phase 1: if the app
is killed outright while `Session.state.stage == .recording`, chunks
recorded before the kill are safe on disk and already attached to the
session, but there's no UI to notice and resume/finalize that session — it
just sits shown as "Recording" forever in the list. Worth a small "sessions
stuck in Recording on launch get offered a stop/finalize action" pass.

## Explicitly rejected (carried over from the original requirement doc)

Meeting bots that join the call as a participant. The whole premise here is a
phone listening to the room, with no integration into the conference
platform.
