//
//  ContentView.swift
//  DeepSink
//

import SwiftUI
import SwiftData
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
    @EnvironmentObject var sessionProcessor: SessionProcessor
    @StateObject private var networkMonitor = NetworkMonitor()
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Session.startedAt, order: .reverse) private var sessions: [Session]

    @State private var activeSession: Session?
    @State private var showReminderBanner = false
    @State private var showMarkerSheet = false
    @State private var pendingMarker: Marker?
    @State private var navigateToSessionID: UUID?
    @State private var recordError: String?
    @State private var attentionKeyword: String?
    @State private var showArticulateSheet = false

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
                if let session = sessions.first(where: { $0.id == id }) {
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
                if let pendingMarker {
                    MarkerDetailSheet(marker: pendingMarker)
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
        }
        .onAppear {
            sessionProcessor.resumeAll(sessions: sessions, settings: settings, modelContext: modelContext)
            sessionProcessor.purgeExpiredAudio(sessions: sessions, settings: settings)
            networkMonitor.start {
                sessionProcessor.resumeAll(sessions: sessions, settings: settings, modelContext: modelContext)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                sessionProcessor.resumeAll(sessions: sessions, settings: settings, modelContext: modelContext)
                sessionProcessor.purgeExpiredAudio(sessions: sessions, settings: settings)
            }
        }
    }

    // MARK: - Home (not recording)

    private var homeContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if sessions.isEmpty {
                    emptyState
                } else {
                    Text("Recent")
                        .font(.title3.bold())
                        .padding(.horizontal)
                        .padding(.top, 8)
                    ForEach(sessions.prefix(Self.recentSessionLimit)) { session in
                        NavigationLink {
                            SessionDetailView(session: session)
                        } label: {
                            SessionCard(session: session)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal)
                    }
                    if sessions.count > Self.recentSessionLimit {
                        NavigationLink {
                            SessionListView()
                        } label: {
                            Text("See all \(sessions.count) sessions")
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
                    // once this session finishes processing after Stop.
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

            let session = Session(title: Session.defaultTitle(for: Date()), startedAt: Date())
            modelContext.insert(session)
            do {
                try modelContext.save()
            } catch {
                // Surfaced rather than swallowed (`try?`) on purpose: a
                // failure here means the session that's about to record
                // was never actually persisted — silently starting the
                // recorder anyway is exactly how a real recording once
                // ended up with a saved audio file and no Session to show
                // for it (see Session.swift's own comment on the
                // migration bug this traces back to). Better to refuse to
                // start than to record into the void again.
                recordError = "Couldn't save the new session: \(error.localizedDescription)"
                modelContext.delete(session)
                return
            }
            activeSession = session

            audioRecorder.targetChunkSeconds = TimeInterval(settings.chunkTargetSeconds)
            audioRecorder.maxChunkSeconds = TimeInterval(settings.chunkTargetSeconds + 30)

            do {
                try audioRecorder.start(sessionID: session.id) { chunk in
                    var chunks = session.chunks
                    chunks.append(chunk)
                    session.chunks = chunks
                    try? modelContext.save()
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
                modelContext.delete(session)
                try? modelContext.save()
                activeSession = nil
            }
        }
    }

    // Live Assist failing to start (permission denied, recognizer
    // unavailable) never blocks or interrupts the actual recording — it's
    // an opt-in augmentation, not core functionality, per the original
    // "if I'm not attending with full attention" framing. It just quietly
    // doesn't run; the record/stop control and everything phase-1 already
    // does are unaffected either way.
    private func startLiveAssistIfPossible() async {
        let authorized = await LiveAssistEngine.requestAuthorizationIfNeeded()
        guard authorized else { return }
        liveAssistEngine.onKeywordDetected = { keyword in
            Task { @MainActor in
                showAttentionAlert(for: keyword)
            }
        }
        try? liveAssistEngine.start(keywords: settings.attentionKeywords)
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

    private func stopRecording() {
        guard let session = activeSession else { return }
        audioRecorder.stop()
        liveAssistEngine.stop()
        attentionKeyword = nil
        session.durationSeconds = audioRecorder.elapsedSeconds
        session.recordingIncomplete = audioRecorder.recordingIncomplete
        session.state = ProcessingState(stage: .uploading, chunksDone: 0, chunksTotal: session.chunks.count, failureReason: nil)
        try? modelContext.save()
        sessionProcessor.process(session: session, settings: settings, modelContext: modelContext)
        activeSession = nil
        navigateToSessionID = session.id
    }

    private func markMoment() {
        guard let session = activeSession else { return }
        let marker = Marker(offsetSeconds: audioRecorder.elapsedSeconds)
        modelContext.insert(marker)
        marker.session = session
        session.markers.append(marker)
        try? modelContext.save()
        pendingMarker = marker
        showMarkerSheet = true
    }

    private func formattedElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

#Preview {
    ContentView()
        .environmentObject(AppSettings())
        .environmentObject(AudioRecorder())
        .environmentObject(LiveAssistEngine())
        .environmentObject(RouterClient())
        .environmentObject(SessionProcessor(routerClient: RouterClient()))
        .modelContainer(for: [Session.self, ActionItem.self, Marker.self], inMemory: true)
}
