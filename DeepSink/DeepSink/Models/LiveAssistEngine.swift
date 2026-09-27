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
// work from — also the live preview shown while recording. No audio or
// recognized text ever leaves the phone through this path — only the
// short excerpt Articulate explicitly sends when tapped, and (opt-in)
// the same live text already pushed to the web viewer's live_preview.
//
// Reverted here (2026-09-27) from a WhisperKit-based spike — see this
// file's git history for the full attempt. That path only ever powered
// this SAME rough live preview: the real, Whisper-quality transcript
// this app keeps has always come from the server (deepsink_transcribe.py),
// which is what notes generation and diarization actually use, not
// this — so replacing Apple's recognizer bought a nicer-looking
// "in progress" line, at the cost of a ~150MB model download, real
// battery/thermal cost from continuous on-device inference every few
// seconds for the length of a recording, and four rounds of real bugs
// before it worked cleanly. Apple's own recognizer needs no download
// and, as a system service with the same OS-level scheduling/power
// privileges as Siri/dictation, should cost meaningfully less battery
// for the same job — worth revisiting only if there's a real plan to
// make transcription (and ideally diarization) fully on-device, which
// this narrow live-preview use never actually was.
//
// Deliberately a SEPARATE AVAudioEngine + input tap from AudioRecorder's
// own AVAudioRecorder-based file writing, rather than one unified engine
// feeding both — proven safe running two independent mic consumers at
// once on a real device across a full session's testing (both this
// version and the WhisperKit one that briefly replaced it used the
// same pattern).
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
    // supposed to forget old content; `livePreviewBuffer` backs the live
    // preview (the recording screen and web viewer's live line) and is
    // scoped to "since the last chunk actually materialized" instead -
    // cleared only in markMaterialized(upTo:) below, once a chunk's real
    // Whisper transcript has landed, never on a timer.
    private let buffer = LiveTranscriptBuffer()
    private let livePreviewBuffer = LiveTranscriptBuffer()

    private var sessionStartDate: Date?
    private var keywords: [String] = []
    private var alreadyFiredForUtterance = false

    private(set) var isRunning = false
    var onKeywordDetected: ((String) -> Void)?

    // Split so the UI can render the settled part at full brightness and
    // the still-revisable tail dimmer/italic, the way captions/dictation
    // UIs usually distinguish "done" from "still deciding" - see
    // LiveTranscriptBuffer's confirmedText()/tailText(). Sealed into
    // "confirmed" on result.isFinal below. Deliberately labelled as
    // rough/on-device in the UI: this is Apple's live recognizer, not
    // the Whisper transcript that eventually replaces it once a chunk
    // uploads.
    @Published private(set) var livePreviewConfirmedText = ""
    @Published private(set) var livePreviewTailText = ""

    var livePreviewText: String {
        [livePreviewConfirmedText, livePreviewTailText].filter { !$0.isEmpty }.joined(separator: " ")
    }

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
        livePreviewConfirmedText = ""
        livePreviewTailText = ""

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
        livePreviewConfirmedText = livePreviewBuffer.confirmedText()
        livePreviewTailText = livePreviewBuffer.tailText()
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
            checkKeywords(in: text)
            if result.isFinal {
                buffer.finishUtterance()
                livePreviewBuffer.finishUtterance()
                alreadyFiredForUtterance = false
            }
            livePreviewConfirmedText = livePreviewBuffer.confirmedText()
            livePreviewTailText = livePreviewBuffer.tailText()
        }
        if error != nil {
            // Common/benign at the tail end of a restart, or if the
            // recognizer briefly has nothing to say — pick recognition
            // back up rather than silently going dark for the rest of
            // the meeting.
            buffer.finishUtterance()
            livePreviewBuffer.finishUtterance()
            alreadyFiredForUtterance = false
            livePreviewConfirmedText = livePreviewBuffer.confirmedText()
            livePreviewTailText = livePreviewBuffer.tailText()
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
