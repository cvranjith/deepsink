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
// AudioStreamTranscriber continuously re-transcribes a growing rolling
// buffer in repeated passes rather than delivering one-shot partials
// like SFSpeechRecognizer did - this is what gives real word-level
// self-correction as you keep talking. It also exposes a
// confirmed/unconfirmed segment split meant to progressively "lock in"
// earlier parts of an utterance, but that turned out unreliable in
// practice (a "confirmed" segment could still get restated, sometimes
// repeatedly, in a later pass - see handleTranscriberState's own
// comment for the full story). This class instead just takes
// `currentText` - the model's current best transcript for the whole
// still-open utterance, as one string - and treats a real pause in
// speech (the library's own "Waiting for speech..." signal) as the only
// utterance boundary, mapped onto LiveTranscriptBuffer's "one open
// entry, sealed by finishUtterance()" model.
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

    // WhisperKit's own default download location (HubApi's default,
    // unchanged here) - Documents/huggingface, inside this app's own
    // sandboxed container. That's a genuinely persistent location for
    // ordinary use (survives the app being backgrounded, relaunched, or
    // updated in place) - it's only wiped when iOS treats an install as
    // a brand new app rather than an update to the existing one, which
    // is what happens on this project's free/personal-team signing
    // every time install_to_deepsink_device.sh mints a fresh
    // provisioning profile (needed to dodge the 7-day free-tier expiry,
    // but was doing that unconditionally on every single run - see that
    // script's own comment for the fix). Exposed here (not just as an
    // implementation detail) so Settings can show whether a model is
    // cached and offer to clear it by hand.
    private static var modelCacheDirectory: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("huggingface")
    }

    static func isModelDownloaded() -> Bool {
        guard let dir = modelCacheDirectory else { return false }
        return FileManager.default.fileExists(atPath: dir.path)
    }

    static func modelCacheSizeBytes() -> Int64 {
        guard let dir = modelCacheDirectory,
              let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    // Deletes the on-disk cached model and drops the in-memory
    // WhisperKit instance, so the next recording re-downloads from
    // scratch - manual "free up storage" / "force a clean re-download"
    // control. Not needed for normal use, since the cache is otherwise
    // reused indefinitely once downloaded.
    func clearDownloadedModel() {
        stop()
        whisperKit = nil
        if let dir = Self.modelCacheDirectory {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func handleTranscriberState(_ state: AudioStreamTranscriber.State) {
        guard isRunning || audioStreamTranscriber != nil else { return }

        // AudioStreamTranscriber's confirmedSegments/unconfirmedSegments
        // turned out unreliable on a real device across three separate
        // attempts to use them here (see this file's git history): a
        // "confirmed" segment could still get restated - sometimes many
        // times over, growing a little longer each time - in later
        // passes instead of the clip boundary reliably advancing past
        // it. Simpler and robust instead: `currentText` is the model's
        // own current best transcript for the whole still-open utterance
        // as of THIS pass, in one string, always fully replacing (never
        // appending to) whatever was shown before - so there's no
        // separate "confirmed segment" bookkeeping left that can go
        // stale or double up.
        //
        // A pass ending resets currentText to "" before the next pass's
        // own progress starts refilling it - that's a transient gap
        // (still mid-utterance, nothing reliable to show yet), not a
        // pause in speech, so it's simply skipped rather than falling
        // back to the same unreliable segments arrays. The library's own
        // "Waiting for speech..." placeholder is what actually signals a
        // real gap - that's the one moment this treats the utterance as
        // finished and seals it, so the NEXT thing said starts as its
        // own fresh entry (keeping Articulate's rolling time-window
        // meaningful, and letting the same keyword fire again on a later
        // mention).
        if state.currentText == "Waiting for speech..." {
            buffer.finishUtterance()
            livePreviewBuffer.finishUtterance()
            alreadyFiredForUtterance = false
        } else if !state.currentText.isEmpty {
            let elapsed = sessionStartDate.map { Date().timeIntervalSince($0) } ?? 0
            buffer.updateCurrentUtterance(text: state.currentText, offsetSeconds: elapsed)
            livePreviewBuffer.updateCurrentUtterance(text: state.currentText, offsetSeconds: elapsed)
            checkKeywords(in: state.currentText)
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
