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
    // client-visible steps. NOT a reliable "is someone still recording
    // this" signal on its own — stage can cycle through uploading/ready
    // multiple times *during* one ongoing recording now that notes
    // regenerate after every chunk, not just at the end (see
    // isRecording below, which is what actually tracks that).
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
    // True while a background notes/action-items regeneration is
    // running server-side (see ai-gateway's _generate_notes) - lets the
    // Notes tab show a real "generating" indicator instead of just
    // looking empty/stuck while one's in flight, whether it was
    // triggered by this device's own chunk upload, /finish, or anything
    // else (background auto-regen fires after every chunk, not just at
    // the end).
    var isGeneratingNotes: Bool
    // True from session creation (or a Resume Recording PATCH) until
    // /finish actually runs — the real "is this session still being
    // recorded" signal, independent of stage's own cycling (see that
    // field's own comment). What the web viewer's live-stream
    // subscription keys off; SessionDetailView's own polling loop uses
    // it too, alongside isGeneratingNotes/isDiarizing.
    var isRecording: Bool
    // When false, a landing chunk still transcribes and stores as usual,
    // but the server skips auto-regenerating notes/action-items for it -
    // "record now, polish once at the end" instead of the default
    // progressive regen-after-every-chunk behavior (see
    // deepsink_sessions.py's upload_chunk). Settable at creation
    // (RouterClient.createSession) and PATCH-able mid-recording
    // (SessionDetailView's own toggle), independent of AppSettings'
    // liveNotesEnabled, which is just the default a new recording starts
    // with.
    var liveNotesEnabled: Bool
    // Set by POST .../notes/cancel while a generation is in flight; the
    // server discards that generation's result instead of saving it once
    // it finishes. Mirrored here mainly so the UI can tell "generating"
    // from "generating, but about to be discarded" if it ever needs to -
    // day to day, isGeneratingNotes flipping back to false is what
    // actually matters to a viewer.
    var notesGenerationCancelled: Bool
    // One of "meeting" | "todo" | "voice_note", chosen on the recording
    // setup sheet - passed through to deepsink_notes.handle() server-side,
    // which uses it to shift the notes-generation prompt's emphasis (see
    // INSTRUCTIONS_BY_CATEGORY in deepsink_notes.py). Not a fixed Swift
    // enum on purpose: an unrecognized value just falls back to "meeting"
    // behavior server-side, so this stays forward-compatible with a
    // category added there before this app knows about it.
    var category: String
    // When false, speaker detection never runs for this session (see
    // isDiarizing's own gating server-side) and each chunk's audio is
    // deleted right after it transcribes rather than kept until /finish -
    // diarization is the only reason the server needs to hold onto raw
    // audio at all.
    var diarizationEnabled: Bool
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

// One row of GET /deepsink/action_items - the cross-session "outstanding
// action items" rollup (see that route's own comment in
// deepsink_sessions.py). Deliberately a separate type from
// ServerActionItem rather than reusing it plus a tacked-on session_id:
// this is what the dashboard actually renders, and every mutation
// (toggle, edit owner/due) round-trips through the same per-item PATCH
// endpoint the session detail view's Actions tab already uses.
struct OutstandingActionItem: Codable, Identifiable, Equatable {
    var id: String
    var text: String
    var owner: String?
    var due: String?
    var isChecked: Bool
    var sortOrder: Int
    var sessionId: String
    var sessionTitle: String
    var sessionStartedAt: Date?
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
// Renaming (RouterClient.renameSpeaker, `PATCH .../speakers/<id>`) is
// also the roster-enrollment step server-side (speaker_roster.py) — a
// recognized regular gets their real name auto-applied on a later
// diarization instead of a fresh "Person N".
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
