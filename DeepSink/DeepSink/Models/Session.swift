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

    // Free-text context the user adds about the meeting — who's in the
    // room, the agenda, acronyms, prior history — sent alongside the
    // transcript to both deepsink.notes and deepsink.articulate so
    // generated notes/answers can use it, without it ever being treated
    // as meeting content itself. Plain stored property (not a computed
    // JSON-blob one like `notes`/`speakers`) since it's simple text a
    // user edits directly, not a structured payload from the router.
    //
    // `= ""` here, not just in `init` below: SwiftData's automatic
    // lightweight migration reads a non-optional property's *declaration-
    // site* default to know what value to backfill into existing rows
    // when this column didn't exist yet — an init-only assignment is
    // invisible to it. Confirmed the hard way: shipping this without a
    // declaration default broke migration on a real device with
    // pre-existing sessions, silently failing every new Session insert
    // (`try?` swallowed the error) while the app otherwise looked fine.
    var backgroundNotes: String = ""

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

    // Chunk metadata, transcript blocks, the raw notes payload, and
    // speaker labels all travel as JSON blobs rather than further
    // SwiftData models/relationships — none of them need independent
    // identity or querying on their own, just to move with the session
    // as a unit.
    var chunksData: Data?
    var transcriptBlocksData: Data?
    var notesData: Data?
    var speakersData: Data?

    // "Detect Speakers" progress — deliberately separate scalars from
    // `state`/`ProcessingState`, not folded into that 5-stage enum:
    // diarization is an optional, on-demand, post-ready enhancement, not
    // part of the recording->ready pipeline every session goes through.
    // Persisted (not local view state) so it survives the app being
    // backgrounded or relaunched mid-run, same reasoning as `state` itself.
    //
    // `= false` at declaration, same migration reasoning as
    // `backgroundNotes` above — this one shipped with the same bug.
    var isDiarizing: Bool = false
    var diarizationError: String?

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
        self.backgroundNotes = ""
        self.recordingIncomplete = false
        self.stageRaw = ProcessingStage.recording.rawValue
        self.chunksDone = 0
        self.chunksTotal = 0
        self.failureReason = nil
        self.chunksData = nil
        self.transcriptBlocksData = nil
        self.notesData = nil
        self.speakersData = nil
        self.isDiarizing = false
        self.diarizationError = nil
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

    var speakers: [SessionSpeaker] {
        get {
            guard let speakersData else { return [] }
            return (try? JSONDecoder().decode([SessionSpeaker].self, from: speakersData)) ?? []
        }
        set { speakersData = try? JSONEncoder().encode(newValue) }
    }

    var isDiarized: Bool { !speakers.isEmpty }

    func displayName(forSpeakerID id: String?) -> String? {
        guard let id else { return nil }
        return speakers.first(where: { $0.id == id })?.displayName
    }

    // Applies a fresh deepsink.diarize result: reassigns every block's
    // speakerID, then rebuilds the default "Person N" labels — but keeps
    // whatever name the user already gave a speaker ID that's still
    // present, so re-running detection doesn't wipe a rename any more
    // than regenerating notes wipes a checked action item (same
    // principle as SessionProcessor.generateNotes).
    func applyDiarization(segments: [DiarizationSegment]) {
        let updatedBlocks = SpeakerDiarization.assign(segments: segments, to: transcriptBlocks)
        transcriptBlocks = updatedBlocks
        let previousNames = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.displayName) })
        let defaults = SpeakerDiarization.defaultSpeakers(for: updatedBlocks)
        speakers = defaults.map { SessionSpeaker(id: $0.id, displayName: previousNames[$0.id] ?? $0.displayName) }
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
