# Requirement: DeepSink Mobile (iOS / Swift) — Phase 1

## 0. How to use this document (instructions to Claude Code)

This is **phase 1 of a progressively wired app**. Build only what is in scope below.
Where a later phase is mentioned, leave a clean seam — a protocol, a stub, a TODO with
a named extension point — but do not implement it.

Please:
1. Confirm the project skeleton and architecture with me **before** writing feature code.
2. Ask rather than assume on anything in Section 9.
3. Keep the AI/router contract in one place so swapping backends never touches the UI.
4. Flag anything that needs an Apple entitlement, capability, or Info.plist key as soon
   as you hit it.

---

## 1. What DeepSink is

A **passive meeting intelligence** app. The iPhone sits on the table and acts as a room
listening device while the actual meeting runs on a separate laptop (Zoom/Teams). There
is no app-to-app audio capture — the phone hears the room, including my own voice and
the laptop speaker.

Phase 1 goal: **record a meeting, get back notes and actionable items with checkboxes.**

Everything else (live features) comes later.

## 2. Architecture context

The app does **not** call any model provider directly. It calls my existing AI router —
the same one the YouTube Gate app uses — with a service ID:

```
DeepSink (iOS/Swift)
      │   POST /v1/invoke   { "service": "...", "input": ..., "options": {...} }
      │   Authorization: Bearer <GATEWAY_TOKEN>
      ▼
Cloudflare Worker (router)  ──▶ cloud models (Groq / Gemini)
                            ──▶ Mac mini (local models, via tunnel)
```

The router owns model choice, prompts, and keys. The app owns capture, storage, and UI.
**No API keys for model providers ever live in this app.**

Service IDs this phase needs (final names to be agreed with me — the router is being
built in parallel):

| Service ID | Purpose |
|---|---|
| `deepsink.transcribe` | audio → transcript text |
| `deepsink.notes` | transcript → summary + action items (structured JSON) |

If the router does not yet accept audio, say so and propose the smallest change to it;
do not work around it by calling a provider directly from the app.

## 3. Phase 1 scope

**In scope**
- Record a meeting from the phone's mic, foreground and background, for up to ~2 hours
- Store the recording locally
- Send audio for transcription via the router
- Send the transcript for note generation via the router
- Display and persist: title, date, duration, summary, key points, **action items with
  checkboxes**
- A list of past sessions
- Export / share a session as markdown or plain text

**Out of scope this phase (leave seams only)**
- Live/streaming transcription during the meeting
- Attention alert, topic watchlist, rolling summary
- "Articulate" (on-demand response generation, bullets or verbatim script, in my own
  phrasing)
- Speaker diarisation
- Calendar integration
- Second-brain push
- Any sync between devices

## 4. Functional requirements

### FR-1: Recording
- Big, unambiguous record / stop control. I will be tapping this at the start of a
  meeting while distracted.
- Recording **must continue when the screen locks or the app is backgrounded**. Set up
  the audio background mode and an `AVAudioSession` configuration that survives this.
  Explain what Apple requires here and what the review implications are (this is
  personal/side-loaded for now, but tell me).
- Visible recording state: elapsed time, level meter so I can see it is actually
  hearing the room, and a Live Activity / lock screen indicator if it is cheap to add.
- Handle interruptions: phone call, Siri, another audio app. Resume automatically where
  possible; if a segment is lost, record that fact rather than silently dropping it.
- Store audio in a compressed format suited to speech (propose the format and say why —
  file size matters because it gets uploaded).

### FR-2: Session model
A session has: id, title (editable, default to date/time), start time, duration, audio
file reference, transcript, generated notes, action items, and a processing state.

Processing state must be explicit and visible: `recording → uploading → transcribing →
summarising → ready`, plus `failed(reason)`. I should never be looking at a spinner
with no idea which stage it is in.

### FR-3: Transcription
- After stopping, upload the audio to the router's `deepsink.transcribe` service.
- Long recordings will exceed sensible request sizes: chunk the audio, upload chunks,
  and stitch the transcript. Keep chunk boundaries on silence where practical.
- Show progress per chunk.
- Must be resumable: if the app is killed or the network drops mid-upload, retry the
  outstanding chunks rather than starting over.
- The transcript is stored locally and is the input for FR-4. I want to be able to read
  the raw transcript too, not just the summary.

### FR-4: Notes and action items
- Send the transcript to `deepsink.notes`.
- The router returns **structured JSON**, not prose. Proposed shape (push back if you
  see better):

```json
{
  "title": "…",
  "summary": "…",
  "key_points": ["…"],
  "decisions": ["…"],
  "action_items": [
    { "text": "…", "owner": "me | <name> | unknown", "due": "2026-10-01 | null" }
  ],
  "open_questions": ["…"]
}
```

- The app must degrade gracefully if a field is missing or the JSON is malformed —
  never crash, never show a raw parse error to me.
- **Action items render as checkboxes.** Checking one persists locally and is mine to
  toggle; regenerating notes must not silently wipe my checked state (ask me what to do
  on conflict, or keep both — propose something).
- Let me edit any generated text. The model's output is a first draft.
- Allow re-running note generation on an existing transcript (e.g. after I improve the
  prompt in the router) without re-transcribing.

### FR-5: Session list and detail
- List: title, date, duration, state, count of open action items.
- Detail: summary, key points, decisions, action items (checkboxes), open questions,
  and a way to view the full transcript.
- Search across titles and transcripts is nice to have this phase, not required.
- Delete a session, including its audio file.

### FR-6: Export
- Export a session as markdown (and plain text) via the standard share sheet.
- Markdown should use `- [ ]` / `- [x]` for action items so it pastes usefully into my
  notes system. This is the seam for the later second-brain push.

### FR-7: Settings
- Router base URL and bearer token (stored in Keychain, never in UserDefaults).
- A "test connection" action.
- Audio quality / chunk size, if exposing it is cheap.
- Whether to keep audio after transcription, or delete it to save space.

## 5. Consent and recording ethics

This records real meetings with other people in the room.

- Include a clear in-app recording indicator; do not make silent recording the easy path.
- Add a settings toggle for a short start-of-recording reminder to announce that I am
  recording.
- Note in the README that recording consent law varies by jurisdiction and that this is
  my responsibility, not the app's.

Do not build anything that disguises recording.

## 6. Non-functional

- **Swift + SwiftUI**, current iOS target. Tell me the minimum iOS version you assume
  and why.
- Local persistence: propose SwiftData or Core Data and justify briefly.
- No third-party dependencies unless you make a case for one.
- All model calls go through one `RouterClient` type with a small, testable surface.
  Swapping the router URL or adding a service ID must not touch view code.
- The app must be usable offline for everything except transcription and notes:
  recording, reading past sessions, and ticking checkboxes all work with no network,
  and queued uploads resume when connectivity returns.
- Battery: recording for 90 minutes should not be alarming. Note anything expensive.

## 6a. FR-8: One-click in-app update over Wi-Fi (reuse existing mechanism)

I build and side-load these apps myself with a personal Xcode setup, which means a
**rebuild and reinstall roughly every week**. For the YouTube Gate app I already devised
a one-click mechanism: a control inside the app triggers install/refresh of a new build
over Wi-Fi, without plugging into the Mac.

**Reuse that exact mechanism here — do not invent a new one.**

- Look at how it is implemented in the YouTube Gate project and port the same approach,
  keeping naming, configuration, and developer ergonomics consistent between the two apps.
- If you cannot see that project, **ask me for it** rather than designing a replacement.
- Keep it in one small, isolated module so both apps can converge on shared code later.
- The update control should be tucked away (Settings / a long-press / a debug section),
  not on the main recording screen where I might hit it mid-meeting.
- It must be safe with an in-progress session: never trigger an update while recording,
  and never leave a recorded-but-unprocessed session unreadable after an update. Session
  data and queued uploads must survive a reinstall.
- Show the currently installed build version and the available one, so I can tell whether
  I am already up to date.

Also note in the README anything I need to keep in sync on the Mac side (build output
location, local server, hosting of the manifest, expiry of the signing profile) so that
the weekly cycle stays a single tap on the phone.

## 7. Deliverables

1. Xcode project, buildable, with the architecture explained in the README
2. `README.md` — setup, entitlements/Info.plist keys, router configuration, and how to
   run on device
3. The `RouterClient` abstraction with the service-ID contract documented
4. A note listing exactly which seams exist for phase 2 (live loop, articulate,
   watchlist) and what would plug into each

## 8. Acceptance criteria

1. Start recording, lock the phone, leave it 30 minutes, return, stop — full audio is
   captured.
2. A 30-minute recording produces a transcript via the router, with visible per-chunk
   progress.
3. Notes appear with summary, key points, and action items as tickable checkboxes.
4. Ticking an item survives app restart.
5. Killing the app mid-upload and reopening resumes rather than restarting.
6. Malformed model output shows a readable error with a retry, not a crash.
7. Export produces markdown with `- [ ]` action items.
8. No provider API key exists anywhere in the codebase; only the router token, in Keychain.
9. Airplane mode: recording and browsing past sessions still work; new uploads queue.
10. The in-app update control installs a fresh build over Wi-Fi in one tap, using the
    same mechanism as YouTube Gate, and all existing sessions and queued uploads survive it.

## 9. Open questions — ask me, do not assume

- Does my router already accept audio for `deepsink.transcribe`, or does phase 1 need
  the router extended first? (I am building the router in parallel; coordinate.)
- SwiftData vs Core Data
- Whether to keep audio files after successful transcription by default
- Whether chunked transcription should stream results as chunks complete, or wait for
  the whole transcript before showing anything
- Minimum iOS version
- Where the YouTube Gate one-click update mechanism lives, if you cannot find it —
  ask me for the repo or the relevant files rather than reimplementing it

## 10. Ideas from comparable apps

Derived from a review comparing Voice Notes, Otter AI and Bluedot. Treat accuracy
claims in such reviews as marketing, not benchmarks.

### Promoted into phase 1 (small, high value)

**FR-8: Mid-meeting markers and comments**
While recording, let me capture a timestamped note without stopping the recording:
- A one-tap "mark this moment" button (no typing — I may be mid-conversation)
- An optional short typed comment attached to that moment
- Optionally a photo (whiteboard, slide) attached to the moment

Markers are stored with the session, shown in the detail view, and included in the
export. They are also passed to `deepsink.notes` as hints, so the model knows which
moments I flagged as important. No AI is required for capture itself — this must work
offline and instantly.

**FR-9: Transcript as browsable blocks**
Do not render the transcript as one wall of text. Break it into timestamped blocks.
Tapping a block plays the audio from that point. This is how I will verify numbers and
commitments, so it needs to be quick to scan.

### Phase 2 backlog — add to `IDEAS.md`, do not build now

- **Ask-anything over a session.** A chat box on a finished session; answers must cite
  the transcript blocks they came from. New router service ID (`deepsink.ask`), with
  the transcript as context. The citation requirement is the important part.
- **Note templates.** Let me regenerate notes from the same transcript under a different
  template (key takeaways / decisions and risks / technical detail / client-facing
  minutes). Since prompts live in the router, this should be a service-ID or option
  parameter, not app logic. Pairs with FR-4's re-run capability.
- **Speaker labels.** Diarisation, with the ability to rename a speaker once and have it
  apply across the whole transcript. Significant work; deferred.
- **Transcript translation / multilingual display.**
- **Cleanup pass.** A "tidy the transcript" service that removes filler and fixes obvious
  ASR errors, kept separate from the raw transcript rather than overwriting it.
- **Webhook / automation out.** A generic outbound webhook per session-completed event,
  which is the natural generalisation of the second-brain push.
- **Desktop companion.** Out of scope entirely for now, but noted: the reviewed tools
  differentiate on capturing meeting audio from the computer as well as the phone.

### Explicitly rejected

- Meeting bots that join the call as a participant. The whole premise here is a phone
  listening to the room, with no integration into the conference platform.
