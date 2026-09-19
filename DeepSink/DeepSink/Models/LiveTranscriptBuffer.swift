//
//  LiveTranscriptBuffer.swift
//  DeepSink
//

import Foundation

// A small rolling buffer of on-device-recognized text, timestamped
// relative to a session's start — feeds both the attention/keyword
// check and Articulate's "last few minutes" context (see
// LiveAssistEngine). Deliberately separate from Session.transcriptBlocks
// (the real, Whisper-accurate transcript written after upload) — this is
// a rougher, on-device-only stream that never gets persisted or shown as
// the session's actual transcript, only matched against and excerpted.
final class LiveTranscriptBuffer {
    private struct Entry {
        var offsetSeconds: TimeInterval
        var text: String
    }

    private var entries: [Entry] = []
    // On-device recognition delivers incremental *partial* results for
    // the same utterance (each a longer prefix of the last), not one-shot
    // final segments — while `isUtteranceOpen`, an update overwrites the
    // last entry instead of appending a new one.
    private var isUtteranceOpen = false

    // Kept a bit longer than any configured Articulate window so a read
    // right at the boundary never comes up short.
    private let retentionSeconds: TimeInterval = 600

    func updateCurrentUtterance(text: String, offsetSeconds: TimeInterval) {
        if isUtteranceOpen, !entries.isEmpty {
            entries[entries.count - 1].text = text
        } else {
            entries.append(Entry(offsetSeconds: offsetSeconds, text: text))
            isUtteranceOpen = true
        }
        trim(before: offsetSeconds - retentionSeconds)
    }

    // Called when a recognition result finalizes, or the task is being
    // restarted — the next update should start a new entry rather than
    // keep overwriting the just-finished one.
    func finishUtterance() {
        isUtteranceOpen = false
    }

    private func trim(before cutoff: TimeInterval) {
        guard cutoff > 0 else { return }
        entries.removeAll { $0.offsetSeconds < cutoff }
    }

    func recentText(seconds: TimeInterval, currentOffset: TimeInterval) -> String {
        let cutoff = currentOffset - seconds
        return entries
            .filter { $0.offsetSeconds >= cutoff && !$0.text.isEmpty }
            .map(\.text)
            .joined(separator: " ")
    }

    // Everything currently held, with no time filtering — for a buffer
    // that's already scoped to "since the last chunk materialized"
    // (see LiveAssistEngine's separate livePreviewBuffer), that scoping
    // itself is the only window that should apply; a second, fixed-time
    // window on top of it is what made the live preview look like it
    // kept erasing older-but-still-unmaterialized speech.
    func allText() -> String {
        entries
            .filter { !$0.text.isEmpty }
            .map(\.text)
            .joined(separator: " ")
    }

    // Drops everything at or before `offsetSeconds` — for when a chunk's
    // real, Whisper-accurate transcript has actually landed and this
    // buffer's rough version of that same stretch of time should stop
    // being shown. Anything after `offsetSeconds` (already-in-progress
    // speech for the next, not-yet-uploaded chunk) is left untouched.
    func trimMaterialized(upTo offsetSeconds: TimeInterval) {
        entries.removeAll { $0.offsetSeconds < offsetSeconds }
    }

    func reset() {
        entries.removeAll()
        isUtteranceOpen = false
    }
}
