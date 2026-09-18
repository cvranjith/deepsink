//
//  TranscriptBlock.swift
//  DeepSink
//

import Foundation

// A timestamped slice of transcript (FR-9) — rendered as a browsable
// list rather than one wall of text, and tapping one plays the audio
// chunk that covers it (see TranscriptView).
struct TranscriptBlock: Codable, Identifiable, Hashable {
    // Client-side only — the server's own JSON has no "id" field for a
    // block (see DeepSinkSession's decoder), so this is deliberately
    // excluded from CodingKeys below; Swift's synthesized Decodable then
    // just uses this declaration-site default on every decode, giving
    // each block a fresh local identity for SwiftUI's `ForEach`.
    var id: UUID = UUID()
    var startSeconds: Double
    var endSeconds: Double
    var text: String
    // Raw diarization speaker ID (e.g. "SPEAKER_00"), not a display name
    // — resolve through DeepSinkSession.displayName(forSpeakerID:) so a
    // rename shows up everywhere this block appears without touching the
    // block itself. Nil until "Detect Speakers" has been run for the session.
    var speakerID: String?

    enum CodingKeys: String, CodingKey {
        case startSeconds = "start"
        case endSeconds = "end"
        case text
        case speakerID = "speaker_id"
    }
}
