//
//  DictationEngine.swift
//  DeepSink
//

import Foundation
import AVFoundation
import Speech
import Combine

// A short, one-shot on-device dictation session for a single text field —
// tap to start, tap to stop (or it stops itself when the recognizer
// finalizes). Deliberately separate from LiveAssistEngine: that one is a
// long-running, continuous listener started once per recording session;
// this is a small, independent engine instantiated fresh per text field
// (see DictationButton) and torn down as soon as dictation stops, with no
// keyword matching or rolling buffer to maintain.
//
// Same on-device-only guarantee as LiveAssistEngine — no audio or text
// leaves the phone through this path, only whatever ends up typed into
// the field it's attached to.
//
// Known risk, not yet verified on a real device: if this runs while
// AudioRecorder is also recording (background notes and marker comments
// can both be edited mid-meeting, not just afterward) — and doubly so if
// LiveAssistEngine is also active — that's up to three independent
// AVAudioEngine instances consuming the mic input at once. Each handles
// its own start failure gracefully (surfaced as `errorMessage`, not a
// crash), but whether three-way concurrent recording is glitch-free
// hasn't been confirmed on hardware. Worth checking specifically if
// dictating into a marker comment mid-recording ever sounds off.
@MainActor
final class DictationEngine: ObservableObject {
    @Published private(set) var isListening = false
    @Published var errorMessage: String?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var baseText = ""
    private var onUpdate: ((String) -> Void)?

    func start(appendingTo currentText: String, onUpdate: @escaping (String) -> Void) {
        guard !isListening else { return }
        Task {
            let authorized = await LiveAssistEngine.requestAuthorizationIfNeeded()
            guard authorized else {
                errorMessage = LiveAssistError.notAuthorized.message
                return
            }
            beginListening(baseText: currentText, onUpdate: onUpdate)
        }
    }

    func stop() {
        guard isListening else { return }
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isListening = false
    }

    private func beginListening(baseText: String, onUpdate: @escaping (String) -> Void) {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            errorMessage = "Speech recognition isn't available right now."
            return
        }

        self.baseText = baseText
        self.onUpdate = onUpdate

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request = req

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] pcmBuffer, _ in
            self?.request?.append(pcmBuffer)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            errorMessage = "Couldn't start the microphone: \(error.localizedDescription)"
            return
        }

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                self?.handle(result: result, error: error)
            }
        }
        errorMessage = nil
        isListening = true
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let spoken = result.bestTranscription.formattedString
            let combined = baseText.isEmpty ? spoken : "\(baseText) \(spoken)"
            onUpdate?(combined)
            if result.isFinal {
                stop()
            }
        }
        if error != nil {
            stop()
        }
    }
}
