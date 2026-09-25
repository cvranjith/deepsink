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

// Runs on-device, real Whisper-quality transcription in parallel with the
// main recording, for the same two phase-2 features as before: the
// attention/keyword alert, and giving Articulate something recent to work
// from — now ALSO the primary source of the live preview text itself,
// replacing Apple's SFSpeechRecognizer entirely (see the 2026-09-24
// conversation: once this is genuinely Whisper-quality and on-device,
// there's no reason to keep the rougher Apple recognizer around as a
// separate "hot preview" source). No audio or recognized text ever leaves
// the phone through this path — only the short excerpt Articulate
// explicitly sends when tapped, and (opt-in) the same live text already
// pushed to the web viewer's live_preview.
//
// Deliberately NOT WhisperKit's own AudioStreamTranscriber, despite that
// being the obvious "streaming" API - four different attempts to use it
// here (see this file's git history) all produced the same real-device
// failure mode in the end: the same stretch of speech restated, sometimes
// repeatedly and each time a little longer, rather than a decode pass
// reliably picking up only where the last one left off. Whatever the exact
// cause upstream, its "confirmed segment" and "currentText" signals both
// turned out unreliable enough here that patching around them symptom by
// symptom wasn't converging.
//
// Instead, this owns the audio capture loop directly: WhisperKit's own
// AudioProcessor (via `kit.audioProcessor`) does the mic tap and buffering
// exactly like AudioStreamTranscriber would have (same "independent
// AVAudioEngine, separate from AudioRecorder's own" pattern, proven safe
// on a real device already), but instead of letting the library re-decode
// the same growing buffer forever, this polls it on a short interval,
// transcribes whatever's accumulated with one plain `WhisperKit.transcribe
// (audioArray:)` call, and then PURGES that audio
// (`audioProcessor.purgeAudioSamples(keepingLast: 0)`) — so the next poll
// can only ever see genuinely new audio. Structurally, not just by
// tuning, this can't re-show the same words twice: there's no shared
// buffer left for a later pass to re-read. The trade-off is coarser
// granularity (new text arrives every couple of seconds in short
// sentence-sized pieces, not token-by-token) rather than the fancier
// live-revising-as-you-speak behavior AudioStreamTranscriber promised but
// didn't reliably deliver here.
@MainActor
final class LiveAssistEngine: ObservableObject {
    // Picked as the accuracy/speed middle ground for real-time
    // transcription on a phone's Neural Engine - "tiny" is explicitly
    // flagged upstream as debug-only/low-accuracy, "large-v3" (600MB+)
    // is built for offline batch accuracy, not a buffer transcribed
    // every couple of seconds. Worth revisiting with real usage.
    private static let modelName = "base"

    // How long to let audio accumulate before transcribing it - a floor
    // (below this, a poll tick just waits for more) rather than a fixed
    // cadence, so a short utterance still shows up promptly once this
    // much has landed, and a poll tick that fires mid-word just waits for
    // the next one rather than transcribing a fragment.
    private static let minChunkSeconds: Double = 2.5
    // Hard cap regardless of what's been said - keeps worst-case latency
    // bounded even through one long continuous sentence with no pause.
    private static let maxChunkSeconds: Double = 6.0
    private static let pollInterval: Duration = .milliseconds(500)

    private var whisperKit: WhisperKit?
    private var audioProcessor: (any AudioProcessing)?
    private var pollTask: Task<Void, Never>?

    // `buffer` is what Articulate reads (recentTranscript(seconds:)), a
    // genuine rolling time-window that's supposed to forget old content;
    // `livePreviewBuffer` backs `livePreviewText` (the recording screen
    // and web viewer's live line) and is scoped to "since the last chunk
    // actually materialized" instead - cleared only in
    // markMaterialized(upTo:) below, once a chunk's real Whisper
    // transcript has landed, never on a timer.
    private let buffer = LiveTranscriptBuffer()
    private let livePreviewBuffer = LiveTranscriptBuffer()

    private var sessionStartDate: Date?
    private var keywords: [String] = []
    private var alreadyFiredForUtterance = false

    private(set) var isRunning = false
    var onKeywordDetected: ((String) -> Void)?

    // Visible, persistent status for the recording screen - a silent
    // failure here (model download stalling/failing, transcription never
    // actually starting) previously looked identical to "working but
    // nothing said yet," with no way to tell them apart short of a
    // transient alert that's easy to miss. This stays on screen instead.
    @Published private(set) var statusMessage: String?

    // Every chunk here is already a complete, one-shot transcription
    // result - nothing left to revise once it's in. So unlike the
    // streaming design this replaced, everything lands in
    // `livePreviewConfirmedText` (full brightness); `livePreviewTailText`
    // only ever holds a brief "Transcribing…" placeholder while a chunk
    // is being processed, not real partial text.
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

        let processor = kit.audioProcessor
        do {
            try processor.startRecordingLive(inputDeviceID: nil, callback: nil)
        } catch {
            statusMessage = "Microphone start failed: \(error.localizedDescription)"
            throw LiveAssistError.modelUnavailable(error.localizedDescription)
        }
        audioProcessor = processor
        isRunning = true
        statusMessage = "Listening…"
        pollTask = Task { [weak self] in
            await self?.pollLoop(kit: kit, processor: processor)
        }
    }

    func stop() {
        guard isRunning else { return }
        pollTask?.cancel()
        pollTask = nil
        audioProcessor?.stopRecording()
        audioProcessor = nil
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
    // the poll loop below timestamps every entry with - the caller is
    // responsible for converting from AudioRecorder's session-absolute
    // chunk offsets (which, unlike this engine's clock, keep counting
    // across a Resume) back to this recording segment's own local time;
    // see ContentView's own comment at the call site.
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
        // "tokenizer unavailable" on a real device.
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

    // The whole live-preview loop: wait for enough new audio, transcribe
    // it as a one-shot (not streaming) call, purge exactly what was just
    // transcribed, repeat. Purging is what makes repetition structurally
    // impossible here - each call only ever sees audio the previous call
    // never touched.
    private func pollLoop(kit: WhisperKit, processor: any AudioProcessing) async {
        let sampleRate = Double(WhisperKit.sampleRate)
        while !Task.isCancelled, isRunning {
            try? await Task.sleep(for: Self.pollInterval)
            guard !Task.isCancelled, isRunning else { return }

            let sampleCount = processor.audioSamples.count
            let seconds = Double(sampleCount) / sampleRate
            guard seconds >= Self.minChunkSeconds else { continue }

            // A natural pause (the same energy-based VAD AudioStreamTranscriber
            // itself uses) lets a short utterance flush promptly instead of
            // always waiting for the max cap - but doesn't block on it either,
            // so a long continuous sentence still flushes at the cap.
            let pausedRecently = AudioProcessor.isVoiceDetected(
                in: processor.relativeEnergy,
                nextBufferInSeconds: 1.0,
                silenceThreshold: 0.3
            ) == false
            guard pausedRecently || seconds >= Self.maxChunkSeconds else { continue }

            let samples = Array(processor.audioSamples)
            processor.purgeAudioSamples(keepingLast: 0)
            guard !samples.isEmpty else { continue }

            livePreviewTailText = "Transcribing…"
            do {
                let options = DecodingOptions(task: .transcribe, skipSpecialTokens: true)
                let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
                let text = Self.stripNonSpeechPlaceholders(
                    results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                )
                guard isRunning else { return }
                livePreviewTailText = ""
                if !text.isEmpty {
                    appendChunk(text)
                }
                statusMessage = "Listening…"
            } catch {
                guard isRunning else { return }
                livePreviewTailText = ""
                statusMessage = "Transcription error: \(error.localizedDescription)"
            }
        }
    }

    // Whisper's own placeholder for audio it decoded as silent/non-speech
    // (seen on a real device: "[BLANK_AUDIO]" showing up as its own
    // chunk) - these are a known artifact of the model itself, not
    // something skipSpecialTokens filters (those are the tokenizer's own
    // control tokens; this is literal generated text). Stripped as a
    // bracketed/parenthetical all-caps-or-lowercase-word tag anywhere in
    // the string, not just a whole-string match, since it can also show
    // up attached to real speech in the same chunk.
    private static func stripNonSpeechPlaceholders(_ text: String) -> String {
        let withoutTags = text.replacingOccurrences(
            of: #"\[[A-Za-z _]+\]|\([A-Za-z ]+\)"#,
            with: "",
            options: .regularExpression
        )
        return withoutTags.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Each poll chunk is a complete, already-final piece of text - sealed
    // immediately (finishUtterance right after), not left open for a
    // later revision the way a true streaming source would.
    private func appendChunk(_ text: String) {
        let elapsed = sessionStartDate.map { Date().timeIntervalSince($0) } ?? 0
        buffer.updateCurrentUtterance(text: text, offsetSeconds: elapsed)
        buffer.finishUtterance()
        livePreviewBuffer.updateCurrentUtterance(text: text, offsetSeconds: elapsed)
        livePreviewBuffer.finishUtterance()
        checkKeywords(in: text)
        alreadyFiredForUtterance = false
        livePreviewConfirmedText = livePreviewBuffer.confirmedText()
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
