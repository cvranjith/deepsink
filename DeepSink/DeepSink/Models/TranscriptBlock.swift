//
//  TranscriptBlock.swift
//  DeepSink
//

import Foundation

// A timestamped slice of transcript (FR-9) — rendered as a browsable
// list rather than one wall of text, and tapping one plays the audio
// chunk that covers it (see TranscriptView).
struct TranscriptBlock: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var startSeconds: Double
    var endSeconds: Double
    var text: String
}
