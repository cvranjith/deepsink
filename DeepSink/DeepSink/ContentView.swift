//
//  ContentView.swift
//  DeepSink
//

import SwiftUI
import AVFoundation
import UIKit

// Home screen: recent sessions as cards up top, a compact record control
// pinned to the bottom via `.safeAreaInset` so it's always reachable
// regardless of scroll position. Originally just one big centered record
// button on an otherwise empty screen — redesigned after seeing how
// comparable apps (Voicenotes, Otter-style tools) lay this out: recent
// items are the useful thing to land on, not an empty circle.
//
// Recording itself no longer has its own dedicated screen here — tapping
// Record navigates straight into the same SessionDetailView used to
// browse any other session (defaulting to its Transcript tab), so the
// previous transcript, notes-so-far, and everything else are reachable
// while recording, not hidden behind a separate view. This class still
// owns the whole recording lifecycle (chunk upload, the live-preview push
// loop, Stop's finish/cleanup sequence) — SessionDetailView reads/
// triggers pieces of it through DeepSinkSessionStore's shared state
// (`activeRecordingSessionID`, `stopRecordingRequest`, etc. — see that
// type's own comments), the same cross-view pattern `resumeRequest`
// already established.
struct ContentView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var audioRecorder: AudioRecorder
    @EnvironmentObject var liveAssistEngine: LiveAssistEngine
    @EnvironmentObject var routerClient: RouterClient
    @EnvironmentObject var sessionStore: DeepSinkSessionStore
    @StateObject private var networkMonitor = NetworkMonitor()
    @Environment(\.scenePhase) private var scenePhase

    @State private var activeSession: DeepSinkSession?
    @State private var navigateToSessionID: String?
    @State private var recordError: String?
    @State private var liveAssistError: String?

    // Chunks upload to the server as soon as AudioRecorder finishes
    // writing each one — not batched at Stop — so both of these track
    // that in-flight work rather than anything about the recording
    // itself: `uploadTasks` is awaited before Stop asks the server to
    // finish the session (so the last chunk can't race the finish
    // call), and `pendingChunkUploads` holds any chunk whose upload
    // failed outright, retried the moment NetworkMonitor sees the
    // connection come back.
    @State private var uploadTasks: [Task<Void, Never>] = []
    @State private var pendingChunkUploads: [(chunk: SessionChunk, sessionID: String)] = []

    // Resuming a finished session continues its chunk_index/offset
    // sequence rather than restarting both at 0 (see AudioRecorder.start)
    // — this is the "continue" baseline added back to this segment's own
    // elapsedSeconds when computing the total duration sent to the
    // server at Stop. Always 0 for a brand-new session. Mirrored onto
    // sessionStore.activeRecordingBaseOffsetSeconds too, since
    // SessionDetailView's own Mark Moment needs the same baseline and
    // this state is private here.
    @State private var resumeBaseOffsetSeconds: TimeInterval = 0

    // Pushes LiveAssistEngine's rolling text to the server on a slow
    // poll-for-demand / fast-push-while-watched cadence — see
    // startLivePreviewLoop and live_preview.py's own doc comment for why
    // this is demand-driven rather than always-on while recording.
    @State private var livePreviewTask: Task<Void, Never>?

    // Capped rather than a true infinite-scroll page — this is a
    // personal app holding dozens of sessions, not thousands; "recent N
    // plus a link to the full list" gets the "don't clutter home with
    // everything" ask without building real pagination for a list this
    // size.
    private static let recentSessionLimit = 5

    var body: some View {
        NavigationStack {
            homeContent
                .navigationTitle("DeepSink")
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        NavigationLink {
                            SessionListView()
                        } label: {
                            Image(systemName: "list.bullet")
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        NavigationLink {
                            SettingsView()
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
                .navigationDestination(item: $navigateToSessionID) { id in
                    if let session = sessionStore.session(id: id) {
                        SessionDetailView(session: session, startOnTranscriptTab: audioRecorder.isRecording)
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if !audioRecorder.isRecording {
                        recordButtonBar
                    }
                }
                .alert("Recording", isPresented: Binding(get: { recordError != nil }, set: { if !$0 { recordError = nil } })) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(recordError ?? "")
                }
                .alert("Live Assist", isPresented: Binding(get: { liveAssistError != nil }, set: { if !$0 { liveAssistError = nil } })) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(liveAssistError ?? "")
                }
        }
        .onAppear {
            Task { await sessionStore.refresh(settings: settings) }
            networkMonitor.start {
                retryPendingChunkUploads()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await sessionStore.refresh(settings: settings) }
                retryPendingChunkUploads()
            }
        }
        .onChange(of: sessionStore.resumeRequest) { _, session in
            guard let session else { return }
            sessionStore.resumeRequest = nil
            resumeRecording(session: session)
        }
        .onChange(of: sessionStore.stopRecordingRequest) { _, requested in
            guard requested, audioRecorder.isRecording else { return }
            sessionStore.stopRecordingRequest = false
            stopRecording()
        }
    }

    // MARK: - Home (not recording)

    private var homeContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if sessionStore.sessions.isEmpty {
                    emptyState
                } else {
                    Text("Recent")
                        .font(.title3.bold())
                        .padding(.horizontal)
                        .padding(.top, 8)
                    ForEach(sessionStore.sessions.prefix(Self.recentSessionLimit)) { session in
                        NavigationLink {
                            SessionDetailView(session: session)
                        } label: {
                            SessionCard(session: session)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal)
                    }
                    if sessionStore.sessions.count > Self.recentSessionLimit {
                        NavigationLink {
                            SessionListView()
                        } label: {
                            Text("See all \(sessionStore.sessions.count) sessions")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.bordered)
                        .padding(.horizontal)
                    }
                }
            }
            .padding(.bottom, 100)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "Ready to record",
            systemImage: "waveform",
            description: Text("Tap the record button below to capture your first meeting.")
        )
        .padding(.top, 60)
    }

    // MARK: - Shared controls

    private var recordButtonBar: some View {
        HStack {
            Spacer()
            recordButton
            Spacer()
        }
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var recordButton: some View {
        Button(action: startRecording) {
            Image(systemName: "record.circle.fill")
                .resizable()
                .frame(width: 72, height: 72)
                .foregroundStyle(Color.red.opacity(0.85))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start recording")
    }

    private func startRecording() {
        Task {
            let granted = await AVAudioApplication.requestRecordPermission()
            guard granted else {
                recordError = "Microphone access is off for DeepSink — enable it in iPhone Settings > Privacy > Microphone."
                return
            }

            let title = DeepSinkSession.defaultTitle(for: Date())
            let created = await routerClient.createSession(title: title, settings: settings)
            let session: DeepSinkSession
            switch created {
            case .success(let value):
                session = value
            case .failure(let error):
                recordError = "Couldn't start a session on the server: \(error.message)"
                return
            }
            sessionStore.apply(session)
            await beginRecording(session: session, startingChunkIndex: 0, baseOffsetSeconds: 0, deleteSessionOnFailure: true)
        }
    }

    // Continues an existing (previously stopped, possibly already
    // "ready") session's recording instead of creating a new one — the
    // server side already supports this for free (append_chunk doesn't
    // care what stage a session is currently in; it just flips back to
    // "uploading" and the next background notes regen covers the whole,
    // combined transcript). What this needs on the phone is just picking
    // up the chunk_index/offset sequence where it left off — see
    // AudioRecorder.start's own comment.
    private func resumeRecording(session: DeepSinkSession) {
        guard !audioRecorder.isRecording else {
            recordError = "Already recording — stop the current recording before resuming a different session."
            return
        }
        Task {
            let granted = await AVAudioApplication.requestRecordPermission()
            guard granted else {
                recordError = "Microphone access is off for DeepSink — enable it in iPhone Settings > Privacy > Microphone."
                return
            }
            // The server otherwise has no way to know recording has
            // resumed until the first new chunk actually lands -
            // live_preview's viewer-facing gating and the web viewer's
            // progressive polling both key off stage being "recording"/
            // "uploading" (see deepsink_sessions.py's patch_session), so
            // this session would silently look finished/non-live for
            // however long that first chunk takes otherwise. Best-effort:
            // proceeds with recording either way if this call fails, just
            // without that immediate live-facing update.
            var resumedSession = session
            if case .success(let updated) = await routerClient.updateSession(id: session.id, fields: ["stage": "recording"], settings: settings) {
                resumedSession = updated
                sessionStore.apply(updated)
            }
            let nextChunkIndex = (resumedSession.chunks.map(\.index).max() ?? -1) + 1
            let baseOffset = resumedSession.chunks.map { $0.startOffsetSeconds + $0.durationSeconds }.max() ?? resumedSession.durationSeconds
            await beginRecording(session: resumedSession, startingChunkIndex: nextChunkIndex, baseOffsetSeconds: baseOffset, deleteSessionOnFailure: false)
        }
    }

    // Shared by both flows above — `deleteSessionOnFailure` is the one
    // real difference: a session just created for a fresh recording
    // should be cleaned up if the mic/recorder fails to actually start,
    // but a resumed session already has real prior content and must
    // never be deleted just because this particular resume attempt
    // failed locally.
    private func beginRecording(session: DeepSinkSession, startingChunkIndex: Int, baseOffsetSeconds: TimeInterval, deleteSessionOnFailure: Bool) async {
        activeSession = session
        uploadTasks = []
        pendingChunkUploads = []
        resumeBaseOffsetSeconds = baseOffsetSeconds
        sessionStore.activeRecordingBaseOffsetSeconds = baseOffsetSeconds

        audioRecorder.targetChunkSeconds = TimeInterval(settings.chunkTargetSeconds)
        audioRecorder.maxChunkSeconds = TimeInterval(settings.chunkTargetSeconds + 30)

        do {
            // AudioRecorder's own sessionID is only ever used locally to
            // name chunk files — it doesn't need to (and, since it's
            // typed as UUID while server session ids are plain strings,
            // can't) match the server session's id.
            try audioRecorder.start(sessionID: UUID(), startingChunkIndex: startingChunkIndex, baseOffsetSeconds: baseOffsetSeconds) { [sessionID = session.id] chunk in
                uploadChunk(chunk, sessionID: sessionID)
            }
            sessionStore.activeRecordingSessionID = session.id
            navigateToSessionID = session.id
            if settings.announceRecordingReminder {
                withAnimation { sessionStore.showReminderBanner = true }
                Task {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    withAnimation { sessionStore.showReminderBanner = false }
                }
            }
            if settings.liveAssistEnabled {
                await startLiveAssistIfPossible()
            }
            startLivePreviewLoop(sessionID: session.id)
        } catch {
            recordError = "Couldn't start recording: \(error.localizedDescription)"
            activeSession = nil
            resumeBaseOffsetSeconds = 0
            sessionStore.activeRecordingSessionID = nil
            if deleteSessionOnFailure {
                sessionStore.remove(id: session.id)
                Task { _ = await routerClient.deleteSession(id: session.id, settings: settings) }
            }
        }
    }

    // Live Assist failing to start (permission denied, recognizer
    // unavailable, or the second AVAudioEngine failing to start while
    // AudioRecorder already has the mic — the flagged-but-unverified risk
    // from when this was built) never blocks or interrupts the actual
    // recording — it's an opt-in augmentation, not core functionality,
    // per the original "if I'm not attending with full attention"
    // framing. But a silent failure here previously meant the live
    // preview just stayed empty with zero indication why — `liveAssistError`
    // surfaces it as an informational alert instead, while still leaving
    // the recording itself completely unaffected either way.
    private func startLiveAssistIfPossible() async {
        let authorized = await LiveAssistEngine.requestAuthorizationIfNeeded()
        guard authorized else {
            liveAssistError = LiveAssistError.notAuthorized.message
            return
        }
        liveAssistEngine.onKeywordDetected = { keyword in
            Task { @MainActor in
                showAttentionAlert(for: keyword)
            }
        }
        do {
            try liveAssistEngine.start(keywords: settings.attentionKeywords)
        } catch {
            liveAssistError = "Live Assist couldn't start, so the live preview and attention keywords won't work for this recording: \(error.localizedDescription)"
        }
    }

    // Demand-driven, not always-on: polls whether anyone's actually
    // watching this session's Transcript tab on the web viewer right now
    // (cheap, slow cadence) and only pushes LiveAssistEngine's rolling
    // text (a real network call every ~1.5s) while that's true — see
    // live_preview.py's own doc comment for the full reasoning. Requires
    // Live Assist to be on (it's the only source of on-device text this
    // pulls from); does nothing at all otherwise.
    private func startLivePreviewLoop(sessionID: String) {
        livePreviewTask?.cancel()
        guard settings.liveAssistEnabled else { return }
        livePreviewTask = Task {
            var lastPushedText: String?
            while !Task.isCancelled {
                guard liveAssistEngine.isRunning else {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    continue
                }
                let viewers = await routerClient.liveViewerCount(sessionID: sessionID, settings: settings)
                guard !Task.isCancelled else { return }
                if viewers > 0 {
                    // The exact same text the recording screen itself
                    // shows (livePreviewText — everything since the last
                    // chunk materialized, not a fixed window), so the
                    // web viewer never shows something different from,
                    // or less complete than, what's on the phone.
                    let text = liveAssistEngine.livePreviewText
                    if text != lastPushedText {
                        await routerClient.postLivePreview(sessionID: sessionID, text: text, settings: settings)
                        lastPushedText = text
                    }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                } else {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        }
    }

    private func stopLivePreviewLoop() {
        livePreviewTask?.cancel()
        livePreviewTask = nil
    }

    private func showAttentionAlert(for keyword: String) {
        withAnimation { sessionStore.attentionKeyword = keyword }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if sessionStore.attentionKeyword == keyword {
                withAnimation { sessionStore.attentionKeyword = nil }
            }
        }
    }

    // Uploads a just-finished chunk immediately rather than batching it
    // for later — every write endpoint returns the full, current
    // session, so applying that response as each chunk lands is what
    // makes the "transcript fills in live" behavior work, on the phone
    // and on any other client (e.g. the Mac mini itself) watching the
    // same session.
    private func uploadChunk(_ chunk: SessionChunk, sessionID: String) {
        let task = Task {
            await performChunkUpload(chunk, sessionID: sessionID)
        }
        uploadTasks.append(task)
    }

    private func performChunkUpload(_ chunk: SessionChunk, sessionID: String) async {
        let url = AudioRecorder.audioDirectory.appendingPathComponent(chunk.fileName)
        guard let data = try? Data(contentsOf: url) else {
            // Nothing to retry — the file itself is gone.
            return
        }
        let result = await routerClient.uploadChunk(
            sessionID: sessionID,
            chunkIndex: chunk.index,
            startOffsetSeconds: chunk.startOffsetSeconds,
            durationSeconds: chunk.durationSeconds,
            audioData: data,
            settings: settings
        )
        switch result {
        case .success(let session):
            sessionStore.apply(session)
            if activeSession?.id == session.id {
                activeSession = session
            }
            // The real, Whisper-accurate transcript for this stretch of
            // time just landed - the rough on-device version of the same
            // stretch should stop showing now, not before (a failed
            // upload never reaches here, so it keeps showing until a
            // retry actually succeeds - see the .failure case below).
            // `chunk.startOffsetSeconds` is session-absolute (keeps
            // counting across a Resume), but LiveAssistEngine's own
            // clock always restarts at 0 for each recording/resume
            // segment - subtracting resumeBaseOffsetSeconds converts
            // back to that same local basis.
            let localEnd = chunk.startOffsetSeconds - resumeBaseOffsetSeconds + chunk.durationSeconds
            liveAssistEngine.markMaterialized(upToSessionOffset: localEnd)
            try? FileManager.default.removeItem(at: url)
        case .failure:
            pendingChunkUploads.append((chunk, sessionID))
        }
    }

    private func retryPendingChunkUploads() {
        guard !pendingChunkUploads.isEmpty else { return }
        let pending = pendingChunkUploads
        pendingChunkUploads = []
        for (chunk, sessionID) in pending {
            uploadChunk(chunk, sessionID: sessionID)
        }
    }

    private func stopRecording() {
        guard let session = activeSession else { return }
        audioRecorder.stop()
        liveAssistEngine.stop()
        stopLivePreviewLoop()
        sessionStore.attentionKeyword = nil
        sessionStore.activeRecordingSessionID = nil
        let sessionID = session.id
        // Cumulative across a resume, not just this segment — see
        // resumeBaseOffsetSeconds' own comment.
        let duration = resumeBaseOffsetSeconds + audioRecorder.elapsedSeconds
        let incomplete = audioRecorder.recordingIncomplete
        activeSession = nil
        resumeBaseOffsetSeconds = 0
        navigateToSessionID = sessionID

        Task {
            // Let every chunk still uploading land before asking the
            // server to finish — the last chunk is finalized
            // synchronously by audioRecorder.stop() above, but uploaded
            // via a fire-and-forget Task, so without this a `finish`
            // call could race ahead of it and generate notes from a
            // transcript still missing that tail.
            for task in uploadTasks { await task.value }
            uploadTasks = []

            if case .success(let updated) = await routerClient.updateSession(
                id: sessionID,
                fields: ["duration_seconds": duration, "recording_incomplete": incomplete],
                settings: settings
            ) {
                sessionStore.apply(updated)
            }

            let result = await routerClient.finishSession(id: sessionID, settings: settings)
            switch result {
            case .success(let finished):
                sessionStore.apply(finished)
            case .failure(let error):
                recordError = "Couldn't finish processing: \(error.message)"
                await sessionStore.refresh(settings: settings)
            }
        }
    }
}

#Preview {
    let router = RouterClient()
    return ContentView()
        .environmentObject(AppSettings())
        .environmentObject(AudioRecorder())
        .environmentObject(LiveAssistEngine())
        .environmentObject(router)
        .environmentObject(DeepSinkSessionStore(routerClient: router))
}
