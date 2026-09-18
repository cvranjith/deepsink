//
//  DeepSinkSession.swift
//  DeepSink
//

import Foundation
import SwiftUI

// The server-persisted session shape — see ai-gateway's session_store.py
// / deepsink_sessions.py for the authoritative contract. This app holds
// no local copy of session data beyond whatever's currently on screen
// (a plain `@State`, not a database): every mutation is a live API call
// (RouterClient), and every write endpoint returns the full, current
// session, so the only "merge" operation anywhere is DeepSinkSessionStore
// replacing what's in memory with the latest response. There's exactly
// one writer (the server), so there's nothing to reconcile.
struct DeepSinkSession: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var startedAt: Date
    var durationSeconds: Double
    var backgroundNotes: String
    // Only 4 real values server-side: "recording" | "uploading" |
    // "failed" | "ready" — the old 5-stage local enum (which also had a
    // "transcribing"/"summarising" split) doesn't exist server-side,
    // since transcription and note generation now happen inside the
    // gateway's own request handlers rather than as separate
    // client-visible steps.
    var stage: String
    var chunksDone: Int
    var chunksTotal: Int
    var failureReason: String?
    var recordingIncomplete: Bool
    var audioDeleted: Bool
    var readyAt: Date?
    var createdAt: Date
    var chunks: [ServerChunk]
    var transcriptBlocks: [TranscriptBlock]
    var notes: SessionNotesPayload?
    var actionItems: [ServerActionItem]
    var markers: [ServerMarker]
    var speakers: [SessionSpeaker]
    var isDiarizing: Bool
    var diarizationError: String?
}

struct ServerChunk: Codable, Identifiable, Equatable {
    var id: Int { index }
    var index: Int
    var fileName: String
    var startOffsetSeconds: Double
    var durationSeconds: Double
    var isTranscribed: Bool
}

struct ServerActionItem: Codable, Identifiable, Equatable {
    var id: String
    var text: String
    var owner: String?
    var due: String?
    var isChecked: Bool
    var sortOrder: Int
}

struct ServerMarker: Codable, Identifiable, Equatable {
    var id: String
    var offsetSeconds: Double
    var comment: String?
    var createdAt: Date
}

// A rename-able label for one raw speaker ID. `id` is pyannote's own
// "SPEAKER_00"-style label (meaningless to a person); `displayName`
// starts as "Person 1", "Person 2", ... in order of first appearance,
// assigned server-side (see deepsink_sessions.py's `_apply_diarization`
// — the alignment/labeling logic that used to live in this app's own
// SpeakerDiarization.swift now runs exactly once, on the server, since
// the server is what actually produces the diarization result).
//
// NOTE: there is currently no server endpoint to rename a speaker after
// the fact (`PATCH /deepsink/sessions/<id>` only accepts title/
// background_notes/duration_seconds/recording_incomplete) — renaming is
// not wired up in this pass; see SessionDetailView's Speakers section,
// shown read-only with a comment explaining why.
struct SessionSpeaker: Codable, Identifiable, Hashable {
    var id: String
    var displayName: String
}

enum DeepSinkSessionStage: String {
    case recording, uploading, failed, ready
}

extension DeepSinkSession {
    var stageValue: DeepSinkSessionStage {
        DeepSinkSessionStage(rawValue: stage) ?? .failed
    }

    var stageLabel: String {
        switch stageValue {
        case .recording: return "Recording"
        case .uploading: return chunksTotal > 0 ? "Uploading \(chunksDone)/\(chunksTotal)" : "Uploading"
        case .failed: return failureReason.map { "Failed — \($0)" } ?? "Failed"
        case .ready: return "Ready"
        }
    }

    var stageIcon: String {
        switch stageValue {
        case .recording: return "mic.fill"
        case .uploading: return "arrow.up.circle"
        case .failed: return "exclamationmark.triangle.fill"
        case .ready: return "checkmark.circle.fill"
        }
    }

    var stageColor: Color {
        switch stageValue {
        case .ready: return .green
        case .failed: return .red
        default: return .secondary
        }
    }

    var isTerminal: Bool { stageValue == .ready || stageValue == .failed }

    var isDiarized: Bool { !speakers.isEmpty }

    var openActionItemCount: Int {
        actionItems.filter { !$0.isChecked }.count
    }

    var fullTranscript: String {
        transcriptBlocks.sorted { $0.startSeconds < $1.startSeconds }.map(\.text).joined(separator: " ")
    }

    func displayName(forSpeakerID id: String?) -> String? {
        guard let id else { return nil }
        return speakers.first(where: { $0.id == id })?.displayName
    }

    static func defaultTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM, h:mm a"
        return formatter.string(from: date)
    }
}
