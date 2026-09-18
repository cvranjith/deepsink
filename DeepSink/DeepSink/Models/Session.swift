//
//  Session.swift
//  DeepSink
//

import Foundation
import SwiftData

@Model
final class Session {
    @Attribute(.unique) var id: UUID
    var title: String
    var startedAt: Date
    var durationSeconds: Double

    // Set the moment an interruption (call, Siri, another app) steals
    // the mic mid-recording — see AudioRecorder's interruption handling.
    // FR-1 requires recording that fact rather than silently dropping
    // the gap, so this surfaces as a banner in SessionDetailView.
    var recordingIncomplete: Bool

    // Processing state, decomposed — see ProcessingState.
    var stageRaw: String
    var chunksDone: Int
    var chunksTotal: Int
    var failureReason: String?

    // Chunk metadata, transcript blocks, and the raw notes payload all
    // travel as JSON blobs rather than further SwiftData models/
    // relationships — none of them need independent identity or
    // querying on their own, just to move with the session as a unit.
    var chunksData: Data?
    var transcriptBlocksData: Data?
    var notesData: Data?

    // Audio retention (FR-7): kept until `deleteAudioAfterDays` after
    // `readyAt`, then purged — see SessionProcessor.purgeExpiredAudio.
    var audioDeleted: Bool
    var readyAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \ActionItem.session)
    var actionItems: [ActionItem] = []

    @Relationship(deleteRule: .cascade, inverse: \Marker.session)
    var markers: [Marker] = []

    var createdAt: Date

    init(id: UUID = UUID(), title: String, startedAt: Date) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.durationSeconds = 0
        self.recordingIncomplete = false
        self.stageRaw = ProcessingStage.recording.rawValue
        self.chunksDone = 0
        self.chunksTotal = 0
        self.failureReason = nil
        self.chunksData = nil
        self.transcriptBlocksData = nil
        self.notesData = nil
        self.audioDeleted = false
        self.readyAt = nil
        self.createdAt = Date()
    }

    var state: ProcessingState {
        get {
            ProcessingState(
                stage: ProcessingStage(rawValue: stageRaw) ?? .failed,
                chunksDone: chunksDone,
                chunksTotal: chunksTotal,
                failureReason: failureReason
            )
        }
        set {
            stageRaw = newValue.stage.rawValue
            chunksDone = newValue.chunksDone
            chunksTotal = newValue.chunksTotal
            failureReason = newValue.failureReason
        }
    }

    var chunks: [SessionChunk] {
        get {
            guard let chunksData else { return [] }
            return (try? JSONDecoder().decode([SessionChunk].self, from: chunksData)) ?? []
        }
        set { chunksData = try? JSONEncoder().encode(newValue) }
    }

    var transcriptBlocks: [TranscriptBlock] {
        get {
            guard let transcriptBlocksData else { return [] }
            return (try? JSONDecoder().decode([TranscriptBlock].self, from: transcriptBlocksData)) ?? []
        }
        set { transcriptBlocksData = try? JSONEncoder().encode(newValue) }
    }

    var fullTranscript: String {
        transcriptBlocks.sorted { $0.startSeconds < $1.startSeconds }.map(\.text).joined(separator: " ")
    }

    var notes: SessionNotesPayload? {
        get {
            guard let notesData else { return nil }
            return try? JSONDecoder().decode(SessionNotesPayload.self, from: notesData)
        }
        set { notesData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    var openActionItemCount: Int {
        actionItems.filter { !$0.isChecked }.count
    }

    static func defaultTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM, h:mm a"
        return formatter.string(from: date)
    }
}
