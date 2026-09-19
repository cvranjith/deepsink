//
//  LiveAssistEngine.swift
//  DeepSink
//

import Foundation
import AVFoundation
import Speech
import Combine

enum LiveAssistError: Error {
    case notAuthorized

    var message: String {
        switch self {
        case .notAuthorized:
            return "Speech Recognition access is off — enable it in iPhone Settings > Privacy > Speech Recognition to use Live Assist."
        }
    }
}

// Runs on-device (`requiresOnDeviceRecognition`) speech recognition in
// parallel with the main recording, for two phase-2 features: the
// attention/keyword alert, and giving Articulate something recent to
// work from. No audio or recognized text ever leaves the phone through
// this path — only the short excerpt Articulate explicitly sends when
// tapped.
//
// Deliberately a SEPARATE AVAudioEngine + input tap from AudioRecorder's
// own AVAudioRecorder-based file writing, rather than one unified engine
// feeding both. Phase-1 recording is already verified working end to end
// on a real meeting; keeping this fully isolated means Live Assist
// (opt-in, best-effort — "if I'm not attending with full attention," per
// the original ask) can never regress the one thing this app absolutely
// cannot get wrong. Running two independent consumers of the mic input
// at once is a supported pattern on iOS (distinct from exclusive-access
// hardware), but hasn't been verified on a real device in this session —
// worth confirming recording stays glitch-free with Live Assist on
// before relying on both together in a real meeting.
@MainActor
final class LiveAssistEngine: ObservableObject {
    private let engine = AVAudioEngine()
    private var speechRecognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var restartTimer: Timer?
    // Two separate buffers, same underlying class, different lifetimes -
    // conflating them was the actual bug behind "the live preview keeps
    // erasing what I already said": `buffer` is what Articulate reads
    // (recentTranscript(seconds:)), a genuine rolling time-window that's
    // supposed to forget old content; `livePreviewBuffer` backs
    // `livePreviewText` (the recording screen and web viewer's live
    // line) and is scoped to "since the last chunk actually
    // materialized" instead - cleared only in markMaterialized(upTo:)
    // below, once a chunk's real Whisper transcript has landed, never on
    // a timer. A fixed rolling window doesn't have a "the real
    // transcript caught up" concept to align itself with, which is
    // exactly why using one for this was wrong.
    private let buffer = LiveTranscriptBuffer()
    private let livePreviewBuffer = LiveTranscriptBuffer()

    private var sessionStartDate: Date?
    private var keywords: [String] = []
    private var alreadyFiredForUtterance = false

    private(set) var isRunning = false
    var onKeywordDetected: ((String) -> Void)?

    // Everything on-device-recognized since the last chunk actually
    // materialized (see markMaterialized(upTo:)) - not a rolling time
    // window. Read by the recording screen and pushed verbatim to the
    // web viewer's live_preview (ContentView's startLivePreviewLoop),
    // so both show exactly the same text. Deliberately labelled as
    // rough/on-device in the UI: this is Apple's live recognizer, not
    // the Whisper transcript that eventually replaces it once a chunk
    // uploads.
    @Published private(set) var livePreviewText = ""

    // Not because on-device recognition tasks are documented to have a
    // hard duration cap (that limit was specifically for server-based
    // recognition) — a periodic restart is cheap insurance against any
    // long-running-task degradation over a 2-hour meeting. This buffer is
    // never shown to the user directly, just matched against and
    // excerpted, so a restart's brief gap costs nothing that matters.
    private static let restartInterval: TimeInterval = 240

    static func requestAuthorizationIfNeeded() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    func start(keywords: [String]) throws {
        guard !isRunning else { return }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw LiveAssistError.notAuthorized
        }
        self.keywords = keywords
        sessionStartDate = Date()
        buffer.reset()
        livePreviewBuffer.reset()
        livePreviewText = ""

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        // `request.append` from inside a real-time audio tap is the
        // documented pattern for feeding SFSpeechAudioBufferRecognitionRequest
        // (see Apple's own Speech framework sample code) — this class is
        // @MainActor, but the tap callback itself runs on a background
        // audio thread, so `request` is read here as a plain optional
        // rather than hopping to the main actor per-buffer, which would
        // add unnecessary dispatch overhead on a real-time path.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] pcmBuffer, _ in
            self?.request?.append(pcmBuffer)
        }
        engine.prepare()
        try engine.start()

        startRecognitionTask()
        restartTimer = Timer.scheduledTimer(withTimeInterval: Self.restartInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.restartRecognitionTask() }
        }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        restartTimer?.invalidate()
        restartTimer = nil
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        livePreviewText = ""
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
    // upload only — never on a failed one, so the rough text keeps
    // showing until a retry actually succeeds). `offsetSeconds` is in
    // this same engine's own elapsed-since-start clock, matching what
    // `handle` below timestamps every entry with - the caller is
    // responsible for converting from AudioRecorder's session-absolute
    // chunk offsets (which, unlike this engine's clock, keep counting
    // across a Resume) back to this recording segment's own local time;
    // see ContentView's own comment at the call site.
    func markMaterialized(upToSessionOffset offsetSeconds: TimeInterval) {
        livePreviewBuffer.trimMaterialized(upTo: offsetSeconds)
        livePreviewText = livePreviewBuffer.allText()
    }

    private func startRecognitionTask() {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { return }
        speechRecognizer = recognizer
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request = req
        alreadyFiredForUtterance = false

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                self?.handle(result: result, error: error)
            }
        }
    }

    private func restartRecognitionTask() {
        guard isRunning else { return }
        task?.cancel()
        request?.endAudio()
        startRecognitionTask()
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        guard let sessionStartDate else { return }
        if let result {
            let text = result.bestTranscription.formattedString
            let elapsed = Date().timeIntervalSince(sessionStartDate)
            buffer.updateCurrentUtterance(text: text, offsetSeconds: elapsed)
            livePreviewBuffer.updateCurrentUtterance(text: text, offsetSeconds: elapsed)
            livePreviewText = livePreviewBuffer.allText()
            checkKeywords(in: text)
            if result.isFinal {
                buffer.finishUtterance()
                livePreviewBuffer.finishUtterance()
                alreadyFiredForUtterance = false
            }
        }
        if error != nil {
            // Common/benign at the tail end of a restart, or if the
            // recognizer briefly has nothing to say — pick recognition
            // back up rather than silently going dark for the rest of
            // the meeting.
            buffer.finishUtterance()
            livePreviewBuffer.finishUtterance()
            alreadyFiredForUtterance = false
            restartRecognitionTask()
        }
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
