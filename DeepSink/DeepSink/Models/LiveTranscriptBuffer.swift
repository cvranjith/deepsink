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
        // Overwrite in place only when the new text is at least as long
        // as what's already there for this open utterance - the normal
        // case, since partials are documented to each be a longer
        // prefix of the last. Guards against a real, observed failure
        // mode otherwise: on-device recognition isn't reliably stable
        // over a long continuous utterance and can silently shrink its
        // own `bestTranscription` (an internal context-window reset)
        // while still reporting a non-final partial - overwriting in
        // that case would silently discard everything already
        // recognized, which is exactly what a user reported seeing
        // ("only the last few words show, everything before that
        // disappeared"). Starting a new entry instead keeps it - worst
        // case this occasionally splits one utterance into two adjacent
        // entries when the recognizer genuinely revises a phrase
        // shorter (rare), which just reads as mild, harmless repetition
        // in what's already labelled a rough preview, never data loss.
        if isUtteranceOpen, !entries.isEmpty, text.count >= entries[entries.count - 1].text.count {
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

    // Everything except the still-open entry (if any) — the part of the
    // live preview that's settled and won't be revised again, for a UI
    // that wants to visually distinguish it (e.g. full brightness) from
    // the still-in-progress tail below.
    func confirmedText() -> String {
        let settled = isUtteranceOpen ? entries.dropLast() : entries[...]
        return settled
            .filter { !$0.text.isEmpty }
            .map(\.text)
            .joined(separator: " ")
    }

    // Just the still-open entry's text (empty if there isn't one right
    // now) — the part that can still change as more audio arrives.
    func tailText() -> String {
        guard isUtteranceOpen, let last = entries.last else { return "" }
        return last.text
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
