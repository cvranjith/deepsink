//
//  SessionProcessor.swift
//  DeepSink
//

import Foundation
import SwiftData
import Combine

// Drives a session through `uploading -> summarising -> ready` (or
// `failed`) after Stop, and is also what "resume after being killed
// mid-upload" means in this app — there is no separate resume code
// path: `process(session:)` is called again from app launch/foreground
// (see ContentView) for any non-terminal session, and it only re-sends
// chunks where `SessionChunk.isTranscribed` is still false, because that
// flag is persisted on the Session itself (FR-3).
@MainActor
final class SessionProcessor: ObservableObject {
    private let routerClient: RouterClient
    private var inFlightSessionIDs: Set<UUID> = []

    init(routerClient: RouterClient) {
        self.routerClient = routerClient
    }

    func process(session: Session, settings: AppSettings, modelContext: ModelContext) {
        guard !inFlightSessionIDs.contains(session.id) else { return }
        guard !session.state.isTerminal else { return }
        inFlightSessionIDs.insert(session.id)
        Task {
            await run(session: session, settings: settings, modelContext: modelContext)
            inFlightSessionIDs.remove(session.id)
        }
    }

    // Called on launch and on returning to the foreground (including
    // right after connectivity comes back — see NetworkMonitor) for
    // every session that isn't done and isn't still actively recording.
    func resumeAll(sessions: [Session], settings: AppSettings, modelContext: ModelContext) {
        for session in sessions where !session.state.isTerminal && session.state.stage != .recording {
            process(session: session, settings: settings, modelContext: modelContext)
        }
    }

    func retryNotes(session: Session, settings: AppSettings, modelContext: ModelContext) {
        guard !inFlightSessionIDs.contains(session.id) else { return }
        inFlightSessionIDs.insert(session.id)
        Task {
            await generateNotes(session: session, settings: settings, modelContext: modelContext)
            inFlightSessionIDs.remove(session.id)
        }
    }

    // "Detect Speakers" — manual only, never part of `process`/`resumeAll`.
    // Reuses `inFlightSessionIDs` with the rest of this class so it can't
    // run concurrently with a notes regeneration on the same session
    // (both mutate the session's blobs), even though it tracks its own
    // progress on `isDiarizing`/`diarizationError` rather than `state`.
    func diarize(session: Session, settings: AppSettings, modelContext: ModelContext) {
        guard !inFlightSessionIDs.contains(session.id) else { return }
        guard !session.audioDeleted, session.state.stage == .ready else { return }
        inFlightSessionIDs.insert(session.id)
        session.isDiarizing = true
        session.diarizationError = nil
        try? modelContext.save()
        Task {
            await runDiarization(session: session, settings: settings, modelContext: modelContext)
            inFlightSessionIDs.remove(session.id)
        }
    }

    private func runDiarization(session: Session, settings: AppSettings, modelContext: ModelContext) async {
        let chunkInputs: [DiarizationChunkInput] = session.chunks.compactMap { chunk in
            let url = AudioRecorder.audioDirectory.appendingPathComponent(chunk.fileName)
            guard let data = try? Data(contentsOf: url) else { return nil }
            return DiarizationChunkInput(data: data, startOffsetSeconds: chunk.startOffsetSeconds)
        }
        guard !chunkInputs.isEmpty else {
            session.isDiarizing = false
            session.diarizationError = "Audio files are missing — can't detect speakers."
            try? modelContext.save()
            return
        }

        let result = await routerClient.diarize(chunks: chunkInputs, settings: settings)
        switch result {
        case .success(let segments):
            session.applyDiarization(segments: segments)
            session.isDiarizing = false
        case .failure(let error):
            session.isDiarizing = false
            session.diarizationError = error.message
        }
        try? modelContext.save()
    }

    // Days-based audio purge (FR-7) — call on launch/foreground, same as
    // resumeAll. Only ever removes audio files; transcript and notes,
    // already stored as JSON on the Session, are untouched.
    func purgeExpiredAudio(sessions: [Session], settings: AppSettings) {
        guard settings.deleteAudioAfterDays > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(settings.deleteAudioAfterDays) * 86400)
        for session in sessions {
            guard !session.audioDeleted, let readyAt = session.readyAt, readyAt < cutoff else { continue }
            deleteAudioFiles(for: session)
            session.audioDeleted = true
        }
    }

    private func run(session: Session, settings: AppSettings, modelContext: ModelContext) async {
        let allChunks = session.chunks
        guard !allChunks.isEmpty else {
            session.state = ProcessingState(stage: .failed, chunksDone: 0, chunksTotal: 0, failureReason: "No audio was recorded.")
            try? modelContext.save()
            return
        }

        let total = allChunks.count
        let pending = allChunks.filter { !$0.isTranscribed }.sorted { $0.index < $1.index }
        session.state = ProcessingState(stage: .uploading, chunksDone: total - pending.count, chunksTotal: total, failureReason: nil)
        try? modelContext.save()

        for chunk in pending {
            let fileURL = AudioRecorder.audioDirectory.appendingPathComponent(chunk.fileName)
            guard let data = try? Data(contentsOf: fileURL) else {
                session.state = ProcessingState(stage: .failed, chunksDone: session.chunksDone, chunksTotal: total, failureReason: "Chunk \(chunk.index) audio file is missing.")
                try? modelContext.save()
                return
            }
            let result = await routerClient.transcribe(
                chunkData: data,
                chunkIndex: chunk.index,
                startOffsetSeconds: chunk.startOffsetSeconds,
                settings: settings
            )
            switch result {
            case .success(let blocks):
                var updatedChunks = session.chunks
                if let idx = updatedChunks.firstIndex(where: { $0.index == chunk.index }) {
                    updatedChunks[idx].isTranscribed = true
                }
                session.chunks = updatedChunks

                var allBlocks = session.transcriptBlocks
                allBlocks.append(contentsOf: blocks)
                session.transcriptBlocks = allBlocks

                let done = updatedChunks.filter(\.isTranscribed).count
                session.state = ProcessingState(stage: .uploading, chunksDone: done, chunksTotal: total, failureReason: nil)
                try? modelContext.save()
            case .failure(let error):
                // Already-transcribed chunks stay marked done — the next
                // Retry (or the next launch/foreground) only redoes what's
                // still pending instead of starting the session over.
                session.state = ProcessingState(stage: .failed, chunksDone: session.chunksDone, chunksTotal: total, failureReason: error.message)
                try? modelContext.save()
                return
            }
        }

        await generateNotes(session: session, settings: settings, modelContext: modelContext)
    }

    private func generateNotes(session: Session, settings: AppSettings, modelContext: ModelContext) async {
        session.state = ProcessingState(stage: .summarising, chunksDone: session.chunksTotal, chunksTotal: session.chunksTotal, failureReason: nil)
        try? modelContext.save()

        // Matched by exact text, since the router response has no stable
        // ID for an action item across regenerations — FR-4 requires
        // re-running notes not silently wipe checked state, so anything
        // whose wording is unchanged keeps its checkmark; anything whose
        // wording changed on regen is treated as new (unchecked) rather
        // than guessed at.
        let previouslyChecked = Set(session.actionItems.filter(\.isChecked).map(\.text))

        let result = await routerClient.generateNotes(transcript: session.fullTranscript, markers: session.markers, settings: settings)
        switch result {
        case .success(let payload):
            if let title = payload.title, !title.isEmpty {
                session.title = title
            }
            session.notes = payload

            for item in session.actionItems { modelContext.delete(item) }
            let newItems = (payload.actionItems ?? []).enumerated().map { index, item -> ActionItem in
                let model = ActionItem(text: item.text, owner: item.owner, due: item.due, sortOrder: index)
                model.isChecked = previouslyChecked.contains(item.text)
                return model
            }
            newItems.forEach { modelContext.insert($0); $0.session = session }
            session.actionItems = newItems

            session.readyAt = Date()
            session.state = ProcessingState(stage: .ready, chunksDone: session.chunksTotal, chunksTotal: session.chunksTotal, failureReason: nil)
        case .failure(let error):
            session.state = ProcessingState(stage: .failed, chunksDone: session.chunksTotal, chunksTotal: session.chunksTotal, failureReason: error.message)
        }
        try? modelContext.save()
    }

    private func deleteAudioFiles(for session: Session) {
        for chunk in session.chunks {
            try? FileManager.default.removeItem(at: AudioRecorder.audioDirectory.appendingPathComponent(chunk.fileName))
        }
    }
}
