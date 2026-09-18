//
//  SpeakerDiarization.swift
//  DeepSink
//

import Foundation

// One raw speaker turn from deepsink.diarize — session-absolute seconds,
// not merged with transcript text (see RouterClient.diarize).
struct DiarizationSegment: Codable {
    var start: Double
    var end: Double
    var speaker: String
}

// A rename-able label for one raw speaker ID. `id` is pyannote's own
// "SPEAKER_00"-style label (meaningless to a person); `displayName`
// starts as "Person 1", "Person 2", ... in order of first appearance and
// is whatever the user has renamed it to since — every transcript block
// referencing this `id` resolves through here, so a rename applies
// everywhere at once without touching a single block.
struct SessionSpeaker: Codable, Identifiable, Hashable {
    var id: String
    var displayName: String
}

enum SpeakerDiarization {
    // Assigns each block the speaker whose segment contains its start
    // time, falling back to the nearest segment by start-time distance
    // if none contains it exactly — pyannote's segment boundaries don't
    // always land exactly on Whisper's own segment boundaries, so an
    // exact-containment match won't always exist. A block that happens
    // to span an actual speaker change just gets whichever speaker was
    // talking when it started; good enough for a first cut, not worth
    // splitting a Whisper segment to fix.
    static func assign(segments: [DiarizationSegment], to blocks: [TranscriptBlock]) -> [TranscriptBlock] {
        guard !segments.isEmpty else { return blocks }
        return blocks.map { block in
            var updated = block
            updated.speakerID = nearestSpeaker(for: block.startSeconds, in: segments)
            return updated
        }
    }

    private static func nearestSpeaker(for time: Double, in segments: [DiarizationSegment]) -> String? {
        if let containing = segments.first(where: { time >= $0.start && time < $0.end }) {
            return containing.speaker
        }
        return segments.min(by: { abs($0.start - time) < abs($1.start - time) })?.speaker
    }

    // Default "Person 1", "Person 2", ... labels in order of each
    // speaker's first appearance across the (already-assigned) blocks —
    // stable and predictable regardless of pyannote's own internal
    // SPEAKER_00/01/... numbering, which carries no meaning for the user.
    static func defaultSpeakers(for blocks: [TranscriptBlock]) -> [SessionSpeaker] {
        var seenIDs: [String] = []
        for block in blocks.sorted(by: { $0.startSeconds < $1.startSeconds }) {
            guard let id = block.speakerID, !seenIDs.contains(id) else { continue }
            seenIDs.append(id)
        }
        return seenIDs.enumerated().map { index, id in
            SessionSpeaker(id: id, displayName: "Person \(index + 1)")
        }
    }
}
