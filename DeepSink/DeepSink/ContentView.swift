//
//  ContentView.swift
//  DeepSink
//

import SwiftUI
import SwiftData
import AVFoundation
import UIKit

// The root screen IS the record screen — FR-1 asks for "a big,
// unambiguous record/stop control... I will be tapping this at the
// start of a meeting while distracted," so nothing is allowed to sit in
// front of it. Everything else (sessions, settings, and — tucked further
// still — the update mechanism) lives one tap away via the toolbar.
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

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()
                statusText
                recordButton
                if audioRecorder.isRecording {
                    levelMeter
                    markMomentButton
                    if settings.liveAssistEnabled {
                        articulateButton
                    }
                }
                Spacer()
            }
            .padding()
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
            .sheet(isPresented: $showMarkerSheet) {
                if let pendingMarker {
                    MarkerDetailSheet(marker: pendingMarker)
                }
            }
            .sheet(isPresented: $showArticulateSheet) {
                ArticulateSheet()
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

    private var statusText: some View {
        Group {
            if audioRecorder.isRecording {
                Text(formattedElapsed(audioRecorder.elapsedSeconds))
                    .font(.system(size: 56, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            } else {
                Text("Ready to record")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var recordButton: some View {
        Button(action: toggleRecording) {
            Image(systemName: audioRecorder.isRecording ? "stop.circle.fill" : "record.circle.fill")
                .resizable()
                .frame(width: 120, height: 120)
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
        .padding(.horizontal, 40)
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
            try? modelContext.save()
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
