//
//  LiveAssistEngine.swift
//  DeepSink
//

import Foundation
import AVFoundation
import Combine
import WhisperKit

enum LiveAssistError: Error {
    case notAuthorized
    case modelUnavailable(String)

    var message: String {
        switch self {
        case .notAuthorized:
            return "Microphone access is off — enable it in iPhone Settings > Privacy > Microphone to use Live Assist."
        case .modelUnavailable(let detail):
            return "Live Assist's on-device transcription model couldn't load: \(detail)"
        }
    }
}

// Runs on-device, real Whisper-quality transcription (WhisperKit's
// AudioStreamTranscriber) in parallel with the main recording, for the
// same two phase-2 features as before: the attention/keyword alert, and
// giving Articulate something recent to work from — now ALSO the
// primary source of the live preview text itself, replacing Apple's
// SFSpeechRecognizer entirely (see the 2026-09-24 conversation: once
// this is genuinely Whisper-quality and on-device, there's no reason to
// keep the rougher Apple recognizer around as a separate "hot preview"
// source). No audio or recognized text ever leaves the phone through
// this path — only the short excerpt Articulate explicitly sends when
// tapped, and (opt-in) the same live text already pushed to the web
// viewer's live_preview.
//
// WhisperKit owns its own AVAudioEngine + input tap internally (via its
// AudioProcessor), deliberately separate from AudioRecorder's own
// AVAudioRecorder-based file writing — the same "independent mic
// consumer" pattern this class already used with SFSpeechRecognizer,
// now proven to work in production on a real device, so carrying it
// over to WhisperKit's own engine is the same known-safe shape, not a
// new risk.
//
// Unlike SFSpeechRecognizer's single "one open utterance, replaced by
// each partial result" model, AudioStreamTranscriber continuously
// re-transcribes a growing rolling buffer and progressively "confirms"
// segments once enough newer audio has arrived after them - this is
// what gives you real word-level self-correction as you keep talking
// (a segment can still be revised right up until it's confirmed), not
// just a longer-and-longer prefix. See handleTranscriberState below for
// how that's mapped onto LiveTranscriptBuffer's simpler
// "one open entry, sealed by finishUtterance()" model: each newly
// confirmed segment becomes its own sealed entry (with its own real
// timestamp, so the rolling time-window reads in Articulate keep
// working), and the still-unconfirmed tail stays one open, overwritable
// entry until it confirms or the segment set changes shape.
@MainActor
final class LiveAssistEngine: ObservableObject {
    // Picked as the accuracy/speed middle ground for real-time
    // transcription on a phone's Neural Engine - "tiny" is explicitly
    // flagged upstream as debug-only/low-accuracy, "large-v3" (600MB+)
    // is built for offline batch accuracy, not a rolling live buffer
    // re-transcribed multiple times a second. Worth revisiting once
    // this has been tried on a real device.
    private static let modelName = "base"

    private var whisperKit: WhisperKit?
    private var audioStreamTranscriber: AudioStreamTranscriber?

    // Two separate buffers, same underlying class, different lifetimes -
    // conflating them was the actual bug behind "the live preview keeps
    // erasing what I already said": `buffer` is what Articulate reads
    // (recentTranscript(seconds:)), a genuine rolling time-window that's
    // supposed to forget old content; `livePreviewBuffer` backs
    // `livePreviewText` (the recording screen and web viewer's live
    // line) and is scoped to "since the last chunk actually
    // materialized" instead - cleared only in markMaterialized(upTo:)
    // below, once a chunk's real Whisper transcript has landed, never on
    // a timer.
    private let buffer = LiveTranscriptBuffer()
    private let livePreviewBuffer = LiveTranscriptBuffer()

    private var sessionStartDate: Date?
    private var keywords: [String] = []
    private var alreadyFiredForUtterance = false

    // How many of the transcriber's confirmedSegments have already been
    // sealed into buffer/livePreviewBuffer as their own entries - only
    // the delta past this index is new each time the state callback
    // fires, since confirmedSegments itself is append-only.
    private var flushedConfirmedCount = 0

    // Guards against sealing the same utterance twice in a row - observed
    // on a real device (short test recording): confirmedSegments can grow
    // by a segment that's a near-duplicate of the one just sealed (same
    // text, an only-slightly-later clip end), rather than genuinely new
    // speech. Only catches an exact repeat of the immediately preceding
    // segment, not fuzzy/partial overlap - cheap and safe, not a full fix
    // for whatever upstream timing produces the duplicate in the first
    // place.
    private var lastFlushedSegmentText = ""

    private(set) var isRunning = false
    var onKeywordDetected: ((String) -> Void)?

    // Visible, persistent status for the recording screen - a silent
    // failure here (model download stalling/failing, the transcriber
    // never actually starting) previously looked identical to "working
    // but nothing said yet," with no way to tell them apart short of a
    // transient alert that's easy to miss. This stays on screen instead.
    @Published private(set) var statusMessage: String?

    // Split so the UI can render the settled part at full brightness and
    // the still-revisable tail dimmer/italic, the way captions/dictation
    // UIs usually distinguish "done" from "still deciding" - see
    // LiveTranscriptBuffer's confirmedText()/tailText(). Read by the
    // recording screen; `livePreviewText` below (their concatenation) is
    // what's pushed verbatim to the web viewer's live_preview
    // (ContentView's startLivePreviewLoop), so it shows the same overall
    // text even without the confirmed/tail visual split.
    @Published private(set) var livePreviewConfirmedText = ""
    @Published private(set) var livePreviewTailText = ""

    var livePreviewText: String {
        [livePreviewConfirmedText, livePreviewTailText].filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func requestAuthorizationIfNeeded() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .undetermined:
            return await AVAudioApplication.requestRecordPermission()
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    func start(keywords: [String]) async throws {
        guard !isRunning else { return }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw LiveAssistError.notAuthorized
        }
        self.keywords = keywords
        sessionStartDate = Date()
        buffer.reset()
        livePreviewBuffer.reset()
        livePreviewConfirmedText = ""
        livePreviewTailText = ""
        flushedConfirmedCount = 0
        lastFlushedSegmentText = ""
        alreadyFiredForUtterance = false

        let alreadyLoaded = whisperKit != nil
        statusMessage = alreadyLoaded ? "Starting…" : "Downloading on-device transcription model…"
        let kit: WhisperKit
        do {
            kit = try await loadedWhisperKit()
        } catch {
            statusMessage = "Model load failed: \(error.localizedDescription)"
            throw LiveAssistError.modelUnavailable(error.localizedDescription)
        }
        guard let tokenizer = kit.tokenizer else {
            statusMessage = "Model load failed: tokenizer unavailable"
            throw LiveAssistError.modelUnavailable("tokenizer unavailable")
        }

        let transcriber = AudioStreamTranscriber(
            audioEncoder: kit.audioEncoder,
            featureExtractor: kit.featureExtractor,
            segmentSeeker: kit.segmentSeeker,
            textDecoder: kit.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: kit.audioProcessor,
            // skipSpecialTokens defaults to false in DecodingOptions -
            // without it, decoded text literally includes Whisper's own
            // control tokens (<|startoftranscript|><|en|>...<|endoftext|>
            // etc.), which is exactly what showed up on screen. The CLI
            // this was verified against sets this explicitly too.
            decodingOptions: DecodingOptions(task: .transcribe, temperatureFallbackCount: 0, skipSpecialTokens: true)
        ) { [weak self] _, newState in
            Task { @MainActor in
                self?.handleTranscriberState(newState)
            }
        }
        audioStreamTranscriber = transcriber

        // `startStreamTranscription()` does NOT return once transcription
        // actually starts — internally it awaits its own `while
        // state.isRecording` loop directly, so it only returns after
        // `stopStreamTranscription()` ends that loop. Awaiting it inline
        // here (the first version of this code) meant `isRunning = true`
        // below was unreachable until the recording *stopped* — so
        // `isRunning` stayed false for the entire recording, `stop()`'s
        // own `guard isRunning else { return }` made Stop a no-op against
        // it (leaking a still-running transcriber into the next
        // recording), and nothing distinguished "quietly working" from
        // "silently never started." Reported by the user as: no live
        // text at all, "listening" the whole time, then transcript/notes
        // only appearing once the server-side pipeline finished — a
        // second, independent path from the live preview, which explains
        // why it "worked" while this was completely dark.
        isRunning = true
        statusMessage = "Listening…"
        Task { [weak self] in
            do {
                try await transcriber.startStreamTranscription()
            } catch {
                await MainActor.run {
                    guard self?.audioStreamTranscriber === transcriber else { return }
                    self?.statusMessage = "Live Assist stopped: \(error.localizedDescription)"
                    self?.isRunning = false
                }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        let transcriber = audioStreamTranscriber
        audioStreamTranscriber = nil
        Task { await transcriber?.stopStreamTranscription() }
        isRunning = false
        statusMessage = nil
        livePreviewConfirmedText = ""
        livePreviewTailText = ""
    }

    func updateKeywords(_ keywords: [String]) {
        self.keywords = keywords
    }

    func recentTranscript(seconds: TimeInterval) -> String {
        guard let sessionStartDate else { return "" }
        let elapsed = Date().timeIntervalSince(sessionStartDate)
        return buffer.recentText(seconds: seconds, currentOffset: elapsed)
    }

    // Called once a chunk's real, Whisper-accurate transcript has landed
    // server-side (ContentView's performChunkUpload, on a successful
    // upload only — never on a failed one, so this on-device text keeps
    // showing until a retry actually succeeds). `offsetSeconds` is in
    // this same engine's own elapsed-since-start clock, matching what
    // handleTranscriberState below timestamps every entry with - the
    // caller is responsible for converting from AudioRecorder's
    // session-absolute chunk offsets (which, unlike this engine's clock,
    // keep counting across a Resume) back to this recording segment's
    // own local time; see ContentView's own comment at the call site.
    func markMaterialized(upToSessionOffset offsetSeconds: TimeInterval) {
        livePreviewBuffer.trimMaterialized(upTo: offsetSeconds)
        livePreviewConfirmedText = livePreviewBuffer.confirmedText()
        livePreviewTailText = livePreviewBuffer.tailText()
    }

    // Loaded once and cached for the lifetime of the app (not per
    // recording) - model download/compile only needs to happen the
    // first time this ever runs, same spirit as WhisperKit's own
    // on-disk model cache backing this up across launches too.
    private func loadedWhisperKit() async throws -> WhisperKit {
        if let whisperKit { return whisperKit }
        // `load: true` is NOT the default here — WhisperKitConfig only
        // auto-loads (which is what actually populates `tokenizer`) when
        // `load` is passed explicitly or a local `modelFolder` was given
        // (see WhisperKit.init: `config.load ?? (config.modelFolder !=
        // nil)`). Passing just `model:` downloads the model but silently
        // skips loadModels() otherwise, which is exactly what produced
        // "tokenizer unavailable" on a real device — the CLI this was
        // verified against on macOS passes `load: true` itself
        // (TranscribeCLIUtils), which is what made that test pass while
        // this same model/download path failed here.
        let kit = try await WhisperKit(WhisperKitConfig(model: Self.modelName, load: true))
        whisperKit = kit
        return kit
    }

    private func handleTranscriberState(_ state: AudioStreamTranscriber.State) {
        guard isRunning || audioStreamTranscriber != nil else { return }

        // Seal off every newly confirmed segment as its own entry, using
        // that segment's own start time rather than "now" - this is what
        // keeps Articulate's rolling time-window (recentTranscript(seconds:))
        // correct instead of collapsing the whole session into one
        // always-in-range entry.
        if state.confirmedSegments.count > flushedConfirmedCount {
            for segment in state.confirmedSegments[flushedConfirmedCount...] {
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, text != lastFlushedSegmentText else { continue }
                lastFlushedSegmentText = text
                let offset = TimeInterval(segment.start)
                buffer.updateCurrentUtterance(text: text, offsetSeconds: offset)
                buffer.finishUtterance()
                livePreviewBuffer.updateCurrentUtterance(text: text, offsetSeconds: offset)
                livePreviewBuffer.finishUtterance()
            }
            flushedConfirmedCount = state.confirmedSegments.count
            // A segment confirming is this model's equivalent of
            // SFSpeechRecognizer's `isFinal` - lets the same keyword
            // fire again on a later mention instead of only ever once
            // per recording.
            alreadyFiredForUtterance = false
        }

        // The still-unconfirmed tail - re-decoded (and potentially
        // revised) on every pass until enough newer audio arrives to
        // confirm it, which is the actual "corrects the previous word as
        // I keep talking" behavior. Kept as one open, overwritable entry
        // (LiveTranscriptBuffer's existing shrink-guard already protects
        // against a revision that gets shorter losing text outright).
        //
        // `currentText` (not `unconfirmedSegments`) is checked FIRST -
        // it's the live, token-by-token progress of whichever decode
        // pass is in flight right now; `unconfirmedSegments` is only the
        // *previous* completed pass's leftover result, reassigned once
        // when that pass finishes and otherwise stale. Checking
        // unconfirmedSegments first (the original version of this code)
        // meant nothing new showed until an entire pass finished - the
        // real cause of "it stays silent, then a chunk of text appears
        // all at once" rather than appearing as you speak.
        var tailText: String
        let tailOffset: TimeInterval
        if !state.currentText.isEmpty, state.currentText != "Waiting for speech..." {
            tailText = state.currentText
            tailOffset = TimeInterval(state.lastConfirmedSegmentEndSeconds)
        } else if let firstUnconfirmed = state.unconfirmedSegments.first {
            tailText = state.unconfirmedSegments.map(\.text).joined(separator: " ")
            tailOffset = TimeInterval(firstUnconfirmed.start)
        } else {
            tailText = ""
            tailOffset = 0
        }

        // Each decode pass re-transcribes from state.lastConfirmedSegmentEndSeconds
        // onward, but in practice (seen on a real device) can still restate
        // the segment that was JUST confirmed as the start of its own
        // output, rather than picking up cleanly after it - what showed on
        // screen as the same sentence appearing once solid, then again
        // ghosted below it. Strips that overlap word-by-word rather than
        // trusting the library's clipping to be exact.
        tailText = Self.stripLeadingOverlap(from: tailText, alreadyConfirmed: lastFlushedSegmentText)

        if !tailText.isEmpty {
            buffer.updateCurrentUtterance(text: tailText, offsetSeconds: tailOffset)
            livePreviewBuffer.updateCurrentUtterance(text: tailText, offsetSeconds: tailOffset)
            checkKeywords(in: tailText)
        }

        livePreviewConfirmedText = livePreviewBuffer.confirmedText()
        livePreviewTailText = livePreviewBuffer.tailText()
    }

    // Word-by-word, case/punctuation-insensitive prefix match - drops
    // however much of `tailText`'s start exactly restates
    // `alreadyConfirmed` (e.g. "context." vs "context and…" still counts
    // as the word "context" matching), leaving only the genuinely new
    // remainder. Leaves tailText untouched the moment a word doesn't
    // match, rather than trying to align them at other offsets.
    private static func stripLeadingOverlap(from tailText: String, alreadyConfirmed: String) -> String {
        guard !alreadyConfirmed.isEmpty, !tailText.isEmpty else { return tailText }
        func normalized(_ word: Substring) -> String {
            word.lowercased().trimmingCharacters(in: .punctuationCharacters)
        }
        let confirmedWords = alreadyConfirmed.split(separator: " ")
        let tailWords = tailText.split(separator: " ")
        var matchCount = 0
        while matchCount < confirmedWords.count, matchCount < tailWords.count,
              normalized(confirmedWords[matchCount]) == normalized(tailWords[matchCount]) {
            matchCount += 1
        }
        guard matchCount > 0 else { return tailText }
        return tailWords[matchCount...].joined(separator: " ")
    }

    private func checkKeywords(in text: String) {
        guard !alreadyFiredForUtterance, !keywords.isEmpty else { return }
        let lowerText = text.lowercased()
        for keyword in keywords {
            let trimmed = keyword.trimmingCharacters(in: .whitespaces).lowercased()
            guard !trimmed.isEmpty, lowerText.contains(trimmed) else { continue }
            alreadyFiredForUtterance = true
            onKeywordDetected?(keyword)
            break
        }
    }
}
