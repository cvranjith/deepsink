# DeepSink (Phase 1)

A passive meeting intelligence app. The iPhone sits on the table and listens to the
room — including your own voice and the laptop speaker — while the actual meeting
runs on a separate device. Phase 1 scope: record a meeting, get back notes and
action items with checkboxes. See `requirement-deepsink-mobile.md` for the full
spec this was built against, and `IDEAS.md` for what's explicitly deferred to
phase 2.

## Architecture

```
DeepSink (iOS/Swift)
      │   POST /v1/invoke   { "service": "...", "input": ..., "options": {...} }
      │   Authorization: Bearer <token>
      ▼
ai-router (Cloudflare Worker)  ──▶ cloud models (Groq / Gemini)
                                ──▶ Mac mini (local models, via tunnel)
```

DeepSink never calls a model provider directly and never holds a provider API
key — it only ever talks to `ai-router` (the same router `yt-run` uses), via
`RouterClient` (`DeepSink/Models/RouterClient.swift`). Swapping the router URL,
rotating the token, or adding a service ID never touches a View — every call
site above `RouterClient` only ever sees plain Swift types (`RouterError`,
`TranscriptBlock`, `SessionNotesPayload`, ...).

Everything else is local-first by design (FR-6): recording, browsing past
sessions, and ticking action-item checkboxes all work with no network. Only
`deepsink.transcribe` and `deepsink.notes` need the router, and those are
retried automatically (on relaunch, on returning to the foreground, and the
moment connectivity comes back — see `NetworkMonitor`) or manually via the
Retry button on a failed session.

### Reused from yt-run, not reinvented

- **Router client pattern** — `RouterClient` is yt-run's `AIGatewayClient`
  trimmed to just the token/`local.*` path (no OAuth client-secret branch;
  DeepSink only ever talks to `ai-router`).
- **One-click Wi-Fi update** — `DeployView`, `BuildInfo`, `ProvisioningProfile`,
  and `install_to_deepsink_device.sh` are the exact same mechanism yt-run's
  `DeployView`/`install_to_device.sh` use: the app calls `local.deploy` on the
  router, which runs a build+install script on the Mac mini and pushes over
  the phone's existing Wi-Fi device pairing via `devicectl`. Not a new
  mechanism — see "Router contract" below for the one thing it needs added.
- **Live Activity plumbing** — same `ActivityAttributes` + widget-extension
  shape as yt-run's `RunActivityAttributes`, showing elapsed time instead of
  distance.
- **One deviation from yt-run, per this app's own requirement doc**: yt-run
  stores its router token in plain `UserDefaults`. DeepSink's token gates real
  meeting audio/transcripts, so it's Keychain-backed instead
  (`KeychainStore.swift`) — see FR-7.

## Router contract

`ai-router`'s `worker.js` today only has `local.codex`, `local.download`, and
`local.deploy`, all JSON-in/JSON-out. **`deepsink.transcribe` and
`deepsink.notes` are not live yet** — calls against them will fail with a
clear `unknown_service` error (surfaced through the same "clear error + retry"
path FR-4 already requires) until the router is extended. Nothing in this app
needs to change when that happens; it's already coded against the contract
below.

### `deepsink.transcribe`

```
POST /v1/invoke
{
  "service": "deepsink.transcribe",
  "input": "<base64 AAC audio chunk>",
  "options": { "chunk_index": 0, "start_offset_seconds": 0, "format": "m4a" }
}
200 -> { "output": { "blocks": [ { "start": 0.0, "end": 4.2, "text": "…" }, ... ] } }
```

`RouterClient.transcribe` also tolerates a simpler `{ "output": { "text": "…" } }`
shape with no block boundaries, if that's easier to stand up first. Audio
travels as base64 in the JSON body rather than multipart — simplest possible
contract for a router this small; only worth revisiting as real multipart if
chunk sizes ever make base64's ~33% overhead matter (see "Audio format" below
for why chunks stay small).

### `deepsink.notes`

```
POST /v1/invoke
{
  "service": "deepsink.notes",
  "input": "<full transcript text>",
  "options": {
    "marker_hints": [ { "offset_seconds": 812.0, "comment": "…" }, ... ],
    "background_notes": "<user-typed context about the session — see Session.backgroundNotes>"
  }
}
200 -> { "output": {
  "title": "…", "summary": "…", "key_points": ["…"], "decisions": ["…"],
  "action_items": [ { "text": "…", "owner": "me | <name> | unknown", "due": "2026-10-01 | null" } ],
  "open_questions": ["…"]
} }
```

Exactly the shape proposed in `requirement-deepsink-mobile.md` FR-4. Every
field is optional on the client side (`SessionNotesPayload`) — a partial
response degrades gracefully rather than failing to decode.

### `deepsink.articulate`

```
POST /v1/invoke
{
  "service": "deepsink.articulate",
  "input": "<short, recent transcript excerpt>",
  "options": { "background_notes": "<same field as deepsink.notes>" }
}
200 -> { "output": { "bullets": ["…", …], "speech": "…" } }
```

Powers Live Assist's Articulate button (see below) — `input` is not the
full session transcript, just the last few minutes from
`LiveAssistEngine`'s on-device recognition. Tuned to be fast (tapped
mid-meeting, waited on) rather than thorough.

### Background notes

`Session.backgroundNotes` (edited freely in `SessionDetailView`, any time
— before, during, or after a session) is free-text context: who's in the
room, the agenda, acronyms/jargon, prior history. Sent to both
`deepsink.notes` and `deepsink.articulate` so generated notes and
in-meeting answers can use it, but the prompt on both services explicitly
tells the model it's background, not something that was actually said —
so it informs interpretation without leaking into the summary or key
points as if it were meeting content. Verified directly: the same
question ("what's the status on the QBR prep") produced a generic answer
without background notes and a specific, correct first-person answer
("I've got the revenue slide...") once background notes named the
user's own responsibility.

### `local.deploy`

DeepSink's `DeployView` reuses yt-run's existing `local.deploy` /
`mac_deploy` end to end. `RouterClient` sends an extra `"project": "deepsink"`
in `options` on every deploy call, which `mac_deploy` branches on (default
`"ytrun"` for backward compatibility) to run `install_to_deepsink_device.sh`
instead — both live and working.

### `deepsink.diarize`

```
POST /v1/invoke
{
  "service": "deepsink.diarize",
  "input": [ { "audio_base64": "<chunk 0>", "start_offset_seconds": 0.0 }, { "audio_base64": "<chunk 1>", "start_offset_seconds": 183.4 }, ... ],
  "options": { "format": "m4a" }
}
200 -> { "output": { "segments": [ { "start": 12.4, "end": 45.1, "speaker": "SPEAKER_00" }, ... ] } }
```

One call for a session's whole set of chunks, not one per chunk — see
"Speaker detection" above for why. **Not yet verified end to end with a
real HuggingFace token** — see `ai-gateway`'s README
("deepsink_diarize setup") for the one remaining manual step
(sign up, accept two model licenses, generate a token, save it to
`hf_token.txt`), after which no code change is needed on either side.

All four `deepsink.*` services and the `project` option above are wired up
and deployed — see `ai-router` and `ai-gateway`'s own READMEs for the
server-side implementation.

## Live Assist (attention keywords + Articulate)

Phase 1's chunk-then-upload pipeline (rotate every few minutes, transcribe
after the chunk finishes) is far too slow for "did someone just say my
name" or "give me an answer to the question from a moment ago" — both need
much fresher text than a several-minutes-old chunk sitting in the upload
queue.

`LiveAssistEngine` (`DeepSink/Models/LiveAssistEngine.swift`) solves this
with on-device speech recognition (Apple's `Speech` framework,
`requiresOnDeviceRecognition`) run entirely locally — no audio or
recognized text leaves the phone through this path, only the short excerpt
Articulate explicitly sends when tapped. It keeps a small rolling buffer
(`LiveTranscriptBuffer`) of recognized text, which both the keyword-match
check and Articulate's "last few minutes" read from.

**Deliberately a second, independent `AVAudioEngine` + input tap**, not a
rework of `AudioRecorder`'s own `AVAudioRecorder`-based file writing.
Phase-1 recording was already verified working end to end on a real
meeting before this was built; keeping Live Assist fully isolated means it
(opt-in, off by default, best-effort per the original ask — "if I'm not
attending with full attention") can never regress the one thing this app
absolutely cannot get wrong. Running two independent consumers of the mic
input at once is a supported iOS pattern, but **this combination hasn't
been verified on a real device yet** — confirm recording stays
glitch-free with Live Assist on before relying on both together in a real
meeting.

Turning Live Assist on in Settings prompts for Speech Recognition
permission (separate from the Microphone permission recording already
has) and shows a keyword list (usually just your name) and the Articulate
window size (default 3 minutes). A keyword match shows a banner + haptic;
tapping it (or the standing "Articulate" button while recording) opens a
sheet showing quick-reference bullets and a spoken-style draft from
`deepsink.articulate`.

## Speaker detection

`deepsink.diarize` (see below) plus a "Detect Speakers" button on a
finished, `.ready` session (`SessionDetailView`) — deliberately on-demand,
not part of the automatic recording→ready pipeline, and deliberately one
pass over the *whole* session's audio rather than per-chunk:
a diarization speaker label ("SPEAKER_00") is only consistent within the
one run that produced it, so diarizing per-chunk (the way transcription
already does) would give different numbering in different chunks. This
also means it needs the session's audio to still exist — disabled with an
explanation once `deleteAudioAfterDays` has purged it.

The result is a list of `{start, end, speaker}` turns, aligned against
DeepSink's own already-correct Whisper transcript blocks by time overlap
(`SpeakerDiarization.assign`) rather than trusting any text the
diarization step itself might produce — it never sees or touches
transcript text at all, only timing. Each detected speaker gets a
default "Person 1", "Person 2", ... label in order of first appearance
(`SpeakerDiarization.defaultSpeakers`), stored in `Session.speakers` — a
small rename-able `[id: displayName]` map, edited from the Speakers
section of a diarized session's detail view. Every transcript block only
ever stores the raw speaker ID (`TranscriptBlock.speakerID`); renaming a
speaker updates `Session.speakers` once and every block referencing that
ID resolves the new name immediately, everywhere (`TranscriptView`,
markdown export) — nothing is denormalized onto the blocks themselves.

Re-running detection preserves any name you've already given a speaker
ID that's still present, the same "don't wipe user edits on regen"
principle FR-4 already applies to notes/action items.

## Audio format

16kHz mono AAC-LC (`.m4a`) at ~32kbps. This is a speech-transcription feed,
not a music recording: content above ~8kHz (the ceiling a 16kHz sample rate
already captures, per Nyquist) adds negligible intelligibility for a
Whisper-class model but multiplies file size. At 32kbps, a 2-hour meeting is
roughly 32,000 bits/s ÷ 8 × 7,200s ≈ **28.8MB total** — small enough to chunk
and upload comfortably over a phone connection.

Recording writes directly into a rotating sequence of chunk files (not one
long file split afterward) — `AudioRecorder` cuts a chunk once it's run at
least `chunkTargetSeconds` (Settings, default 3 min) *and* the live level
meter reads a quiet moment, or unconditionally at `chunkTargetSeconds + 30s`
if no quiet moment shows up. This is a live-metering approximation of "cut on
silence," not real VAD — good enough for phase 1.

## Entitlements / Info.plist

- **`NSMicrophoneUsageDescription`** — required; set via
  `INFOPLIST_KEY_NSMicrophoneUsageDescription` in the project build settings.
- **`UIBackgroundModes: audio`** — required for recording to survive the
  screen locking or the app backgrounding; set in `DeepSink/DeepSink/Info.plist`
  (a *physical* file, not the auto-generated one — see "Why a physical
  Info.plist" below).
- **`NSSupportsLiveActivities`** — for the lock-screen/Dynamic Island
  recording indicator.
- **`NSSpeechRecognitionUsageDescription`** — required only if Live Assist
  is turned on (Settings); requested lazily at that point, not at launch,
  same pattern as the mic permission.
- **No photo-library entitlement** — marker photos use `PhotosPicker`
  (`PhotosUI`), which doesn't require any privacy key to *select* an existing
  photo; the picked image is copied into the app's own sandbox, never written
  back to the system Photos library.
- **No `BGTaskScheduler` entitlement** — upload/transcribe retries happen on
  launch, on returning to the foreground, and on reconnect while foregrounded
  (see `NetworkMonitor`), not via a background-fetch task. Simpler for phase
  1; flagged here in case you'd rather it retry while fully backgrounded too.

### Apple review implications (flagged per the requirement doc's own ask)

This is a personal, side-loaded, free-account build — not shipping to the App
Store. If that ever changes: background audio recording apps get real
App Review scrutiny (Apple wants to see the background audio mode used for
its stated purpose, not as a battery-life loophole), and an app that records
other people's voices without an obvious on-screen indicator is exactly the
kind of thing Review pushes back on. The always-visible recording state,
level meter, and consent-reminder toggle (Section 5) exist for that reason
too, not just usability.

### Why a physical `Info.plist`

`GENERATE_INFOPLIST_FILE = YES` is on for both targets (lets simple scalar
keys live as `INFOPLIST_KEY_*` build settings), but each target *also* has a
real `Info.plist` file on disk for the one thing that can't be expressed that
way: `UIBackgroundModes` is an array. Xcode merges the two. This physical
file is also exactly what `install_to_deepsink_device.sh` stamps
`DSBuildCommitHash`/`DSBuildCommitDate`/`DSBuildInstallDate` into before each
build (read back by `BuildInfo.swift`) — the git-committed version has none of
those keys; the script adds and the installer's `git checkout --` step
discards them each run, so they never land in a commit.

## Minimum iOS version

**26.0.** This is a personal build for one specific phone (currently on iOS
26.6.2) — there's no reason to support anything older, so the deployment
target just tracks "whatever this phone runs," same reasoning as yt-run's own
`IPHONEOS_DEPLOYMENT_TARGET = 26.5`. (SwiftData, used for local persistence,
only needs iOS 17+ — 26.0 clears that with a lot of headroom.)

## Local persistence: SwiftData

Three `@Model` types — `Session`, `ActionItem`, `Marker` — with everything
that doesn't need independent identity or querying (chunk metadata,
transcript blocks, the raw notes payload) stored as JSON blobs on `Session`
rather than further models. `Session.state` (a `ProcessingState`) is
deliberately *not* one Codable enum with associated values — SwiftData's
handling of those is still fragile across schema changes — so it's decomposed
into plain scalar columns (`stageRaw`, `chunksDone`, `chunksTotal`,
`failureReason`) instead.

## Fresh machine setup

Everything this repo needs lives in git or gets pulled fresh into `/tmp` at
build time (see `install_to_deepsink_device.sh`'s own comment on
statelessness) — no `Secrets.swift`-style file exists, since the router URL
and bearer token are entered in-app (Settings) and live in
UserDefaults/Keychain on-device, never in source. Cloning this repo onto a
different Mac and running the installer should behave identically, given:

1. **Xcode installed**, with the **same Apple ID signed in** (Xcode →
   Settings → Accounts) as whatever personal team built the app before —
   `DEVELOPMENT_TEAM = WCZKGGTY9K` is baked into the project, matching
   yt-run's own team ID, since it's the same Apple ID either way.
2. **iOS platform support downloaded** in Xcode (Settings → Platforms) — this
   is the ~17GB package `install_to_deepsink_device.sh` is careful never to
   delete, since re-downloading it is the expensive part of a "fresh machine."
3. **The iPhone paired once over USB** (`xcrun devicectl list devices` should
   show it as `paired`) — after that, Wi-Fi installs work without a cable.
4. `jq` installed (`brew install jq`) — the installer uses it to parse
   `devicectl`'s device list.

Given those four, `git clone` + `./install_to_deepsink_device.sh` is the whole
process — same as it is on this machine today.

## Running on device

```
./install_to_deepsink_device.sh
```

Pulls latest, stamps build info, clears the provisioning-profile cache
(resets the free-account 7-day clock), builds for the connected/paired
device, installs, and cleans up everything under `/tmp/deepsink_build` — the
iOS platform support itself is never touched. First run needs the phone
plugged in via USB and unlocked once; after that, `local.deploy` (once wired
server-side — see "Router contract") can trigger the same script from inside
the app over Wi-Fi, tucked into Settings → Update App, same as yt-run.

## Consent (Section 5)

DeepSink shows an always-visible recording indicator (elapsed time + level
meter, plus a lock-screen Live Activity) and an optional on-screen reminder
when recording starts, nudging you to tell the room out loud. **Recording
consent law varies by jurisdiction — that's your responsibility, not this
app's.** Nothing here is built to disguise or hide that recording is
happening.

## Known phase-1 simplifications

- **`uploading`/`transcribing` are shown as one client-visible stage**
  (`uploading`) rather than two, since the router's current contract does
  both synchronously in one call per chunk. `ProcessingStage.transcribing`
  stays in the enum as a seam for if the router ever splits into an async
  upload-then-poll shape.
- **No true VAD** — chunk boundaries use the live level meter as a
  silence proxy, not a real voice-activity model.
- **Transcript playback seeks within a chunk, not across the whole
  session** — chunks are separate files; tapping a transcript block plays
  the specific chunk file it falls in, seeked to the right offset, rather
  than a stitched continuous recording.
- **A session left in `.recording` state if the app is killed outright
  mid-recording** has no dedicated recovery UI yet — whatever chunks
  finished before the crash are safe on disk and already attached to the
  session, but there's no "resume this in-progress recording" flow. Noted
  in `IDEAS.md`.
- **Marker photos use the photo picker, not live camera capture** — avoids
  needing a `NSCameraUsageDescription` entitlement this phase; easy to add
  later if in-the-moment camera capture (rather than picking an existing
  photo) turns out to matter.
