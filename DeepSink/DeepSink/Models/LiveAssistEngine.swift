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

    private(set) var isRunning = false
    var onKeywordDetected: ((String) -> Void)?

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
        alreadyFiredForUtterance = false

        let kit: WhisperKit
        do {
            kit = try await loadedWhisperKit()
        } catch {
            throw LiveAssistError.modelUnavailable(error.localizedDescription)
        }
        guard let tokenizer = kit.tokenizer else {
            throw LiveAssistError.modelUnavailable("tokenizer unavailable")
        }

        let transcriber = AudioStreamTranscriber(
            audioEncoder: kit.audioEncoder,
            featureExtractor: kit.featureExtractor,
            segmentSeeker: kit.segmentSeeker,
            textDecoder: kit.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: kit.audioProcessor,
            decodingOptions: DecodingOptions(task: .transcribe, temperatureFallbackCount: 0)
        ) { [weak self] _, newState in
            Task { @MainActor in
                self?.handleTranscriberState(newState)
            }
        }
        audioStreamTranscriber = transcriber
        try await transcriber.startStreamTranscription()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        let transcriber = audioStreamTranscriber
        audioStreamTranscriber = nil
        Task { await transcriber?.stopStreamTranscription() }
        isRunning = false
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
        let kit = try await WhisperKit(WhisperKitConfig(model: Self.modelName))
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
                let offset = TimeInterval(segment.start)
                buffer.updateCurrentUtterance(text: segment.text, offsetSeconds: offset)
                buffer.finishUtterance()
                livePreviewBuffer.updateCurrentUtterance(text: segment.text, offsetSeconds: offset)
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
        let tailText: String
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

        if !tailText.isEmpty {
            buffer.updateCurrentUtterance(text: tailText, offsetSeconds: tailOffset)
            livePreviewBuffer.updateCurrentUtterance(text: tailText, offsetSeconds: tailOffset)
            checkKeywords(in: tailText)
        }

        livePreviewConfirmedText = livePreviewBuffer.confirmedText()
        livePreviewTailText = livePreviewBuffer.tailText()
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
