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

    // A cross-screen trigger, not session data: SessionDetailView sets
    // this and dismisses itself; ContentView (the only place that owns
    // AudioRecorder/LiveAssistEngine and knows how to actually start a
    // recording) observes it via `.onChange` and starts one continuing
    // this session rather than creating a new one. Using the shared
    // store for this (instead of, say, a NavigationPath binding) means
    // it works regardless of how deep SessionDetailView was pushed.
    @Published var resumeRequest: DeepSinkSession?

    // The rest of this block is the same idea, extended: recording now
    // happens inside the same SessionDetailView used for browsing any
    // other session (not a separate dedicated screen), so whichever
    // recording-related state used to live only in ContentView's own
    // @State needs to be readable from wherever that view actually is —
    // ContentView still owns starting/stopping and all the upload/
    // finish bookkeeping, this is just what other views need to know or
    // trigger.
    //
    // `activeRecordingSessionID`/`activeRecordingBaseOffsetSeconds` let
    // any SessionDetailView answer "is this me?" and compute a marker's
    // session-absolute offset correctly even mid-resume (see
    // AudioRecorder.start's own comment on why a resumed recording's
    // elapsedSeconds alone isn't the session's cumulative time).
    @Published var activeRecordingSessionID: String?
    @Published var activeRecordingBaseOffsetSeconds: TimeInterval = 0

    // SessionDetailView's Stop button sets this; ContentView observes it
    // the same way it observes `resumeRequest`, and runs its own
    // stopRecording() (awaiting in-flight uploads, PATCHing final
    // duration, calling /finish, tearing down Live Assist/the live-
    // preview loop) - logic that stays private to ContentView since it
    // closes over @State only it has.
    @Published var stopRecordingRequest = false

    // The reminder banner and attention-keyword alert used to be plain
    // @State overlays on ContentView's own root view - which stopped
    // working the moment recording moved into a *pushed* SessionDetailView,
    // since an overlay on a view sitting underneath a navigation push
    // isn't part of what's actually drawn. Moved here so whichever view
    // is currently showing the active recording can render them.
    @Published var showReminderBanner = false
    @Published var attentionKeyword: String?

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
