//
//  ProcessingState.swift
//  DeepSink
//

import Foundation

// The five-stage lifecycle FR-2 requires be explicit and visible at all
// times. "uploading" doubles as "transcribing" for now, since this
// phase's router contract does both in one synchronous call per chunk
// (see RouterClient.transcribe) — the case stays separate as a seam for
// when the router splits into an async upload-then-poll shape.
enum ProcessingStage: String, Codable, CaseIterable {
    case recording
    case uploading
    case transcribing
    case summarising
    case ready
    case failed
}

// Stored on `Session` as plain scalars (stageRaw/chunksDone/chunksTotal/
// failureReason) rather than as one Codable enum with associated values —
// SwiftData's handling of associated-value enums is still fragile across
// schema changes, and scalars are boring and safe. This type is just the
// convenient view every call site actually works with.
struct ProcessingState: Equatable {
    var stage: ProcessingStage
    var chunksDone: Int
    var chunksTotal: Int
    var failureReason: String?

    var label: String {
        switch stage {
        case .recording: return "Recording"
        case .uploading: return chunksTotal > 0 ? "Uploading \(chunksDone)/\(chunksTotal)" : "Uploading"
        case .transcribing: return chunksTotal > 0 ? "Transcribing \(chunksDone)/\(chunksTotal)" : "Transcribing"
        case .summarising: return "Summarising"
        case .ready: return "Ready"
        case .failed: return failureReason.map { "Failed — \($0)" } ?? "Failed"
        }
    }

    var isTerminal: Bool { stage == .ready || stage == .failed }
}
