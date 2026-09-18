//
//  DeepSinkSessionStore.swift
//  DeepSink
//

import Foundation
import Combine

// The one place the in-memory session list lives — a cache of the
// server's list endpoint, not a database. Every write anywhere in the
// app (recording a chunk, toggling an action item, editing notes) goes
// straight to RouterClient and comes back with a full session, which
// then gets handed to `apply(_:)` here so every screen showing that
// session (list, detail, card) sees the same, single, always-fresh copy
// instead of drifting local state that needs reconciling.
@MainActor
final class DeepSinkSessionStore: ObservableObject {
    @Published private(set) var sessions: [DeepSinkSession] = []
    @Published var lastError: String?

    private let routerClient: RouterClient

    init(routerClient: RouterClient) {
        self.routerClient = routerClient
    }

    func refresh(settings: AppSettings) async {
        switch await routerClient.listSessions(settings: settings) {
        case .success(let sessions):
            self.sessions = sessions.sorted { $0.startedAt > $1.startedAt }
            self.lastError = nil
        case .failure(let error):
            self.lastError = error.message
        }
    }

    // Replaces whatever this session's id currently holds, or inserts it
    // at the front if it's new — the only "merge" logic in the app, and
    // it's a full replace, never a field-by-field patch, matching the
    // server's own "every write returns the full session" contract.
    func apply(_ session: DeepSinkSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
        }
    }

    func session(id: String) -> DeepSinkSession? {
        sessions.first(where: { $0.id == id })
    }

    func remove(id: String) {
        sessions.removeAll { $0.id == id }
    }
}
