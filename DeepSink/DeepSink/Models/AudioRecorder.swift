//
//  AudioRecorder.swift
//  DeepSink
//

import Foundation
import AVFoundation
import ActivityKit
import Combine

// Records into a rotating sequence of AAC files rather than one long
// file — FR-3 needs the audio chunked for upload anyway, and recording
// directly into chunks means there's never a multi-hour file to split
// after the fact.
//
// Format: 16kHz mono AAC-LC, ~32kbps. This is a speech-transcription
// feed, not a music recording — content above ~8kHz (which a 16kHz
// sample rate already captures up to, per Nyquist) adds negligible
// intelligibility for a Whisper-class model but multiplies file size.
// At 32kbps a 2-hour meeting is roughly 32,000 bits/s ÷ 8 × 7,200s ≈
// 28.8MB total — comfortably small to chunk and upload over a phone's
// connection (see README for the fuller math).
//
// Chunking: rotates to a new file once a chunk has run at least
// `targetChunkSeconds`, at the next moment the level meter reads below
// a quiet threshold (so cuts land on pauses in conversation rather than
// mid-word), or unconditionally at `maxChunkSeconds` if no quiet moment
// shows up. This is a live-metering approximation of "cut on silence,"
// not real VAD — good enough for phase 1, cheap enough to run inline.
@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var currentLevel: Float = 0 // 0...1, for the level meter
    @Published private(set) var recordingIncomplete = false

    var targetChunkSeconds: TimeInterval = 180
    var maxChunkSeconds: TimeInterval = 210
    private let silenceThresholdDB: Float = -35

    private var recorder: AVAudioRecorder?
    private var levelTimer: Timer?
    private var sessionStartDate: Date?
    private var sessionID: UUID?
    private var currentChunkStartOffset: TimeInterval = 0
    private var currentChunkIndex = 0
    private var onChunkFinished: ((SessionChunk) -> Void)?
    private var liveActivity: Activity<DeepSinkActivityAttributes>?
    private var lastActivitySecond = -1

    static let audioDirectory: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // `startingChunkIndex`/`baseOffsetSeconds` are for resuming a
    // previously-finished session's recording (see ContentView's
    // resumeRecording): continuing the chunk_index/offset sequence
    // rather than restarting both at 0 is what keeps new chunk files
    // from overwriting old ones with the same name, and keeps the new
    // transcript blocks' timestamps after the existing ones instead of
    // overlapping them. `elapsedSeconds` itself still starts fresh at 0
    // either way — it's this recording segment's own on-screen timer,
    // not the session's cumulative duration (the caller adds
    // `baseOffsetSeconds` back in when it computes that for the server).
    func start(sessionID: UUID, startingChunkIndex: Int = 0, baseOffsetSeconds: TimeInterval = 0, onChunkFinished: @escaping (SessionChunk) -> Void) throws {
        try configureSession()
        self.sessionID = sessionID
        self.onChunkFinished = onChunkFinished
        currentChunkIndex = startingChunkIndex
        currentChunkStartOffset = baseOffsetSeconds
        sessionStartDate = Date()
        elapsedSeconds = 0
        recordingIncomplete = false
        lastActivitySecond = -1
        NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        try startChunkRecorder()
        startLiveActivity()
        startLevelTimer()
        isRecording = true
    }

    @discardableResult
    func stop() -> [SessionChunk] {
        finishCurrentChunk()
        levelTimer?.invalidate()
        levelTimer = nil
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        endLiveActivity()
        isRecording = false
        var finished: [SessionChunk] = []
        return finished // populated via onChunkFinished as each chunk lands; kept for call-site symmetry
    }

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker])
        try session.setActive(true)
    }

    private func startChunkRecorder() throws {
        guard let sessionID else { return }
        let fileName = "\(sessionID.uuidString)-\(currentChunkIndex).m4a"
        let url = Self.audioDirectory.appendingPathComponent(fileName)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            AVEncoderBitRateKey: 32000,
        ]
        let newRecorder = try AVAudioRecorder(url: url, settings: settings)
        newRecorder.delegate = self
        newRecorder.isMeteringEnabled = true
        newRecorder.record()
        recorder = newRecorder
    }

    private func finishCurrentChunk() {
        guard let recorder else { return }
        let duration = recorder.currentTime
        recorder.stop()
        guard duration > 0 else { self.recorder = nil; return }
        let chunk = SessionChunk(
            index: currentChunkIndex,
            fileName: recorder.url.lastPathComponent,
            startOffsetSeconds: currentChunkStartOffset,
            durationSeconds: duration
        )
        onChunkFinished?(chunk)
        currentChunkStartOffset += duration
        currentChunkIndex += 1
        self.recorder = nil
    }

    private func rotateChunk() {
        finishCurrentChunk()
        try? startChunkRecorder()
    }

    private func startLevelTimer() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let recorder, let sessionStartDate else { return }
        recorder.updateMeters()
        let db = recorder.averagePower(forChannel: 0)
        // Rough -60dB...0dB -> 0...1 map — this is a "is it hearing the
        // room at all" indicator, not a calibrated VU meter.
        currentLevel = max(0, min(1, (db + 60) / 60))
        elapsedSeconds = Date().timeIntervalSince(sessionStartDate)
        updateLiveActivityIfNeeded()

        let chunkElapsed = recorder.currentTime
        guard chunkElapsed >= targetChunkSeconds else { return }
        if chunkElapsed >= maxChunkSeconds || db < silenceThresholdDB {
            rotateChunk()
        }
    }

    // MARK: - Interruptions (FR-1: calls, Siri, another audio app)

    @objc nonisolated private func handleInterruption(_ notification: Notification) {
        Task { @MainActor in self.processInterruption(notification) }
    }

    private func processInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            guard isRecording else { return }
            // The system has already stopped audio input — finalize
            // whatever was captured in this chunk rather than losing it,
            // and flag the gap so the UI can say a segment might be
            // missing instead of presenting a silent hole as normal.
            finishCurrentChunk()
            recordingIncomplete = true
        case .ended:
            guard isRecording else { return }
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            guard AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume) else { return }
            do {
                try configureSession()
                try startChunkRecorder()
            } catch {
                // Stays flagged incomplete; whatever was captured before
                // the interruption is still safe and will still process.
            }
        @unknown default:
            break
        }
    }

    // MARK: - Live Activity (lock screen / Dynamic Island indicator)

    private func startLiveActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = DeepSinkActivityAttributes(startedAt: sessionStartDate ?? Date())
        let state = DeepSinkActivityAttributes.ContentState(elapsedSeconds: 0, isRecording: true)
        liveActivity = try? Activity.request(attributes: attributes, content: .init(state: state, staleDate: nil))
    }

    private func updateLiveActivityIfNeeded() {
        let second = Int(elapsedSeconds)
        guard second != lastActivitySecond else { return }
        lastActivitySecond = second
        guard let liveActivity else { return }
        Task {
            await liveActivity.update(.init(state: .init(elapsedSeconds: second, isRecording: true), staleDate: nil))
        }
    }

    private func endLiveActivity() {
        guard let liveActivity else { return }
        let second = Int(elapsedSeconds)
        Task {
            await liveActivity.end(.init(state: .init(elapsedSeconds: second, isRecording: false), staleDate: nil), dismissalPolicy: .immediate)
        }
        self.liveActivity = nil
    }
}

extension AudioRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in self.recordingIncomplete = true }
    }
}
