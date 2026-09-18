//
//  ContentView.swift
//  DeepSink
//

import SwiftUI
import AVFoundation
import UIKit

// Home screen: recent sessions as cards up top, a compact record control
// pinned to the bottom via `.safeAreaInset` so it's always reachable
// regardless of scroll position or which state (browsing vs. recording)
// is showing above it. Originally just one big centered record button on
// an otherwise empty screen — redesigned after seeing how comparable
// apps (Voicenotes, Otter-style tools) lay this out: recent items are
// the useful thing to land on, not an empty circle.
struct ContentView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var audioRecorder: AudioRecorder
    @EnvironmentObject var liveAssistEngine: LiveAssistEngine
    @EnvironmentObject var routerClient: RouterClient
    @EnvironmentObject var sessionStore: DeepSinkSessionStore
    @StateObject private var networkMonitor = NetworkMonitor()
    @Environment(\.scenePhase) private var scenePhase

    @State private var activeSession: DeepSinkSession?
    @State private var showReminderBanner = false
    @State private var showMarkerSheet = false
    @State private var pendingMarkerOffset: Double?
    @State private var navigateToSessionID: String?
    @State private var recordError: String?
    @State private var liveAssistError: String?
    @State private var attentionKeyword: String?
    @State private var showArticulateSheet = false

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

    // Capped rather than a true infinite-scroll page — this is a
    // personal app holding dozens of sessions, not thousands; "recent N
    // plus a link to the full list" gets the "don't clutter home with
    // everything" ask without building real pagination for a list this
    // size.
    private static let recentSessionLimit = 5

    var body: some View {
        NavigationStack {
            Group {
                if audioRecorder.isRecording {
                    recordingPanel
                } else {
                    homeContent
                }
            }
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
                    SessionDetailView(session: session)
                }
            }
            .overlay(alignment: .top) {
                if showReminderBanner {
                    reminderBanner
                } else if let attentionKeyword {
                    attentionBanner(for: attentionKeyword)
                }
            }
            .safeAreaInset(edge: .bottom) {
                recordButtonBar
            }
            .sheet(isPresented: $showMarkerSheet) {
                if let activeSession, let pendingMarkerOffset {
                    MarkerDetailSheet(sessionID: activeSession.id, offsetSeconds: pendingMarkerOffset)
                }
            }
            .sheet(isPresented: $showArticulateSheet) {
                ArticulateSheet(session: activeSession)
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

    // MARK: - Recording

    private var recordingPanel: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text(formattedElapsed(audioRecorder.elapsedSeconds))
                    .font(.system(size: 48, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .padding(.top, 12)
                levelMeter
                livePreviewSection
                HStack(spacing: 12) {
                    markMomentButton
                    if settings.liveAssistEnabled {
                        articulateButton
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 100)
        }
    }

    private var livePreviewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Live preview", systemImage: "waveform.badge.mic")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Group {
                if !settings.liveAssistEnabled {
                    Text("Turn on Live Assist in Settings for a live, on-device preview of what's being said.")
                        .foregroundStyle(.secondary)
                } else if liveAssistEngine.livePreviewText.isEmpty {
                    Text("Listening…")
                        .foregroundStyle(.secondary)
                } else {
                    // Rough on-device recognition, not the final transcript
                    // — replaced by the accurate Whisper-transcribed text
                    // as chunks upload and the server transcribes each one.
                    Text(liveAssistEngine.livePreviewText)
                }
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
        Button(action: toggleRecording) {
            Image(systemName: audioRecorder.isRecording ? "stop.circle.fill" : "record.circle.fill")
                .resizable()
                .frame(width: 72, height: 72)
                .foregroundStyle(audioRecorder.isRecording ? Color.red : Color.red.opacity(0.85))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(audioRecorder.isRecording ? "Stop recording" : "Start recording")
    }

    private var levelMeter: some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: 4)
                .fill(.secondary.opacity(0.2))
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.red)
                        .frame(width: proxy.size.width * CGFloat(audioRecorder.currentLevel))
                }
        }
        .frame(height: 10)
        .padding(.horizontal, 20)
    }

    private var markMomentButton: some View {
        Button {
            markMoment()
        } label: {
            Label("Mark this moment", systemImage: "bookmark.fill")
                .font(.headline)
        }
        .buttonStyle(.bordered)
    }

    private var reminderBanner: some View {
        Text("🔴 Recording — let the room know")
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.red.opacity(0.15), in: Capsule())
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var articulateButton: some View {
        Button {
            showArticulateSheet = true
        } label: {
            Label("Articulate", systemImage: "sparkles")
                .font(.headline)
        }
        .buttonStyle(.bordered)
        .tint(.indigo)
    }

    // Tapping it goes straight to the same Articulate sheet the standing
    // button opens — the point of the alert is "catch up fast," not just
    // "you were notified."
    private func attentionBanner(for keyword: String) -> some View {
        Button {
            attentionKeyword = nil
            showArticulateSheet = true
        } label: {
            Label("\"\(keyword)\" mentioned — tap to Articulate", systemImage: "bell.badge.fill")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.orange.opacity(0.2), in: Capsule())
        }
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func toggleRecording() {
        if audioRecorder.isRecording {
            stopRecording()
        } else {
            startRecording()
        }
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
            activeSession = session
            uploadTasks = []
            pendingChunkUploads = []

            audioRecorder.targetChunkSeconds = TimeInterval(settings.chunkTargetSeconds)
            audioRecorder.maxChunkSeconds = TimeInterval(settings.chunkTargetSeconds + 30)

            do {
                // AudioRecorder's own sessionID is only ever used locally
                // to name chunk files — it doesn't need to (and, since
                // it's typed as UUID while server session ids are plain
                // strings, can't) match the server session's id.
                try audioRecorder.start(sessionID: UUID()) { [sessionID = session.id] chunk in
                    uploadChunk(chunk, sessionID: sessionID)
                }
                if settings.announceRecordingReminder {
                    withAnimation { showReminderBanner = true }
                    Task {
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        withAnimation { showReminderBanner = false }
                    }
                }
                if settings.liveAssistEnabled {
                    await startLiveAssistIfPossible()
                }
            } catch {
                recordError = "Couldn't start recording: \(error.localizedDescription)"
                activeSession = nil
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

    private func showAttentionAlert(for keyword: String) {
        withAnimation { attentionKeyword = keyword }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if attentionKeyword == keyword {
                withAnimation { attentionKeyword = nil }
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
        attentionKeyword = nil
        let sessionID = session.id
        let duration = audioRecorder.elapsedSeconds
        let incomplete = audioRecorder.recordingIncomplete
        activeSession = nil
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

    private func markMoment() {
        guard activeSession != nil else { return }
        pendingMarkerOffset = audioRecorder.elapsedSeconds
        showMarkerSheet = true
    }

    private func formattedElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
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
