//
//  SessionDetailView.swift
//  DeepSink
//

import SwiftUI
import SwiftData
import AVFoundation

private enum SessionTab: String, CaseIterable, Identifiable {
    case notes = "Notes"
    case transcript = "Transcript"
    case actions = "Actions"
    case background = "Background"
    var id: String { rawValue }
}

// Tabbed rather than one long vertical scroll — the original layout
// stacked summary, key points, decisions, action items, markers,
// speakers, and background notes into a single List, which got
// cluttered fast. Split along the same lines comparable apps use
// (Summary/Transcript/Chat-style tab bars): generated notes, transcript
// (with markers and speaker renaming folded in, since both are
// transcript-contextual), action items, and the user's own background
// notes each get their own tab. Title, processing state, and
// share/delete stay in the header/toolbar since they apply regardless
// of which tab is showing.
struct SessionDetailView: View {
    @Bindable var session: Session
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var sessionProcessor: SessionProcessor
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var isEditingTitle = false
    @State private var isSharing = false
    @State private var shareText = ""
    @State private var isDeleting = false
    @State private var selectedTab: SessionTab = .notes

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            tabContent
        }
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        shareText = MarkdownExporter.markdown(for: session)
                        isSharing = true
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .disabled(session.state.stage != .ready)

                    Button(role: .destructive) {
                        isDeleting = true
                    } label: {
                        Label("Delete Session", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $isSharing) {
            ActivityView(items: [shareText])
        }
        .confirmationDialog("Delete this session?", isPresented: $isDeleting, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteSession() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This also deletes its audio, if any is still kept.")
        }
        .alert("Speaker Detection", isPresented: Binding(
            get: { session.diarizationError != nil },
            set: { if !$0 { session.diarizationError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.diarizationError ?? "")
        }
    }

    // MARK: - Header (always visible)

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isEditingTitle {
                TextField("Title", text: $session.title, onCommit: {
                    isEditingTitle = false
                    try? modelContext.save()
                })
                .font(.title3.bold())
            } else {
                Button {
                    isEditingTitle = true
                } label: {
                    Text(session.title)
                        .font(.title3.bold())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            }
            HStack {
                Label(session.state.label, systemImage: stateIcon)
                    .font(.footnote)
                    .foregroundStyle(stateColor)
                Spacer()
                if session.state.stage == .failed {
                    Button("Retry") { retry() }
                        .font(.footnote)
                }
            }
            if session.recordingIncomplete {
                Label("A segment may be missing — recording was interrupted.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if session.audioDeleted {
                Label("Audio auto-deleted after \(settings.deleteAudioAfterDays) days.", systemImage: "trash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(SessionTab.allCases) { tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { selectedTab = tab }
                    } label: {
                        VStack(spacing: 6) {
                            Text(tab.rawValue)
                                .font(.subheadline.weight(selectedTab == tab ? .semibold : .regular))
                                .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                            Rectangle()
                                .fill(selectedTab == tab ? Color.accentColor : .clear)
                                .frame(height: 2)
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 4)
            Divider()
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .notes: notesTab
        case .transcript: transcriptTab
        case .actions: actionsTab
        case .background: backgroundTab
        }
    }

    // MARK: - Notes tab

    private var notesTab: some View {
        List {
            if let summary = session.notes?.summary, !summary.isEmpty {
                Section("Summary") { Text(summary) }
            }
            if let keyPoints = session.notes?.keyPoints, !keyPoints.isEmpty {
                Section("Key points") {
                    ForEach(keyPoints, id: \.self) { Text("• \($0)") }
                }
            }
            if let decisions = session.notes?.decisions, !decisions.isEmpty {
                Section("Decisions") {
                    ForEach(decisions, id: \.self) { Text("• \($0)") }
                }
            }
            if let openQuestions = session.notes?.openQuestions, !openQuestions.isEmpty {
                Section("Open questions") {
                    ForEach(openQuestions, id: \.self) { Text("• \($0)") }
                }
            }
            if session.notes == nil {
                Section {
                    Text(session.state.stage == .failed ? "Notes failed to generate — retry from the header above." : "Notes aren't ready yet.")
                        .foregroundStyle(.secondary)
                }
            }
            if session.state.stage == .ready {
                Section {
                    Button("Regenerate notes") { retry(regenerateOnly: true) }
                }
            }
        }
    }

    // MARK: - Transcript tab (also markers + speakers — both are transcript-contextual)

    private var transcriptTab: some View {
        List {
            if session.state.stage == .ready {
                Section {
                    speakerDetectionRow
                } footer: {
                    if session.audioDeleted {
                        Text("Detect Speakers needs the session's audio, which has already been auto-deleted.")
                    }
                }
            }
            if session.isDiarized {
                Section("Speakers") {
                    ForEach(session.speakers) { speaker in
                        SpeakerRenameRow(session: session, speaker: speaker) {
                            try? modelContext.save()
                        }
                    }
                }
            }
            if !session.markers.isEmpty {
                Section("Markers") {
                    ForEach(session.markers.sorted(by: { $0.offsetSeconds < $1.offsetSeconds })) { marker in
                        Text(formattedOffset(marker.offsetSeconds) + (marker.comment.map { $0.isEmpty ? "" : " — \($0)" } ?? ""))
                    }
                }
            }
            if session.transcriptBlocks.isEmpty {
                Section {
                    Text("No transcript yet.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Transcript") {
                    TranscriptBlocksList(session: session)
                }
            }
        }
    }

    @ViewBuilder
    private var speakerDetectionRow: some View {
        if session.isDiarizing {
            HStack { ProgressView(); Text("Detecting speakers…") }
        } else if !session.audioDeleted {
            Button(session.isDiarized ? "Re-detect Speakers" : "Detect Speakers") {
                sessionProcessor.diarize(session: session, settings: settings, modelContext: modelContext)
            }
        }
    }

    // MARK: - Actions tab

    private var actionsTab: some View {
        List {
            if session.actionItems.isEmpty {
                Section {
                    Text("No action items yet.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(session.actionItems.sorted { $0.sortOrder < $1.sortOrder }) { item in
                        ActionItemRow(item: item, onToggle: { try? modelContext.save() })
                    }
                } footer: {
                    Text("\(session.openActionItemCount) open of \(session.actionItems.count).")
                }
            }
        }
    }

    // MARK: - Background tab

    private var backgroundTab: some View {
        List {
            Section {
                TextEditor(text: $session.backgroundNotes)
                    .frame(minHeight: 200)
                    // Saved on every change rather than gated behind
                    // losing focus: dictation (DictationButton) writes to
                    // this same binding without the TextEditor itself
                    // ever gaining focus, so a focus-only save would miss
                    // dictated text entirely.
                    .onChange(of: session.backgroundNotes) { _, _ in
                        try? modelContext.save()
                    }
            } header: {
                HStack {
                    Text("Background info")
                    Spacer()
                    DictationButton(text: $session.backgroundNotes)
                }
            } footer: {
                Text("Who's in the room, the agenda, acronyms, prior context. Sent along with the transcript when generating notes or an Articulate answer, but never treated as something that was said.")
            }
        }
    }

    private var stateIcon: String {
        switch session.state.stage {
        case .recording: return "mic.fill"
        case .uploading, .transcribing: return "arrow.up.circle"
        case .summarising: return "sparkles"
        case .ready: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var stateColor: Color {
        switch session.state.stage {
        case .ready: return .green
        case .failed: return .red
        default: return .secondary
        }
    }

    private func retry(regenerateOnly: Bool = false) {
        if regenerateOnly {
            sessionProcessor.retryNotes(session: session, settings: settings, modelContext: modelContext)
        } else {
            sessionProcessor.process(session: session, settings: settings, modelContext: modelContext)
        }
    }

    private func deleteSession() {
        for chunk in session.chunks {
            try? FileManager.default.removeItem(at: AudioRecorder.audioDirectory.appendingPathComponent(chunk.fileName))
        }
        modelContext.delete(session)
        try? modelContext.save()
        dismiss()
    }

    private func formattedOffset(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// A plain text field per speaker, committed on submit — `session.speakers`
// is a computed property over a JSON blob (see Session.swift), not a
// stored SwiftData property, so this reads/writes it wholesale rather
// than trying to bind through it directly.
private struct SpeakerRenameRow: View {
    @Bindable var session: Session
    let speaker: SessionSpeaker
    var onSave: () -> Void

    @State private var name: String = ""

    var body: some View {
        TextField("Speaker name", text: $name)
            .onAppear { name = speaker.displayName }
            .onSubmit { rename() }
    }

    private func rename() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != speaker.displayName else {
            name = speaker.displayName
            return
        }
        var updated = session.speakers
        guard let idx = updated.firstIndex(where: { $0.id == speaker.id }) else { return }
        updated[idx].displayName = trimmed
        session.speakers = updated
        onSave()
    }
}

private struct ActionItemRow: View {
    @Bindable var item: ActionItem
    var onToggle: () -> Void

    var body: some View {
        Button {
            item.isChecked.toggle()
            onToggle()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.isChecked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(item.isChecked ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.text)
                        .strikethrough(item.isChecked)
                        .foregroundStyle(item.isChecked ? .secondary : .primary)
                    if (item.owner != nil && !(item.owner ?? "").isEmpty) || (item.due != nil && !(item.due ?? "").isEmpty) {
                        HStack(spacing: 6) {
                            if let owner = item.owner, !owner.isEmpty { Text(owner) }
                            if let due = item.due, !due.isEmpty { Text("· \(due)") }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// The transcript-block list + playback, factored out of the old
// standalone TranscriptView so it can sit inline inside the Transcript
// tab's List rather than behind a NavigationLink push — same content,
// same playback behavior, just embedded instead of a separate screen.
private struct TranscriptBlocksList: View {
    let session: Session
    @State private var player: AVAudioPlayer?
    @State private var playingBlockID: UUID?
    @State private var playbackError: String?

    var body: some View {
        Group {
            if session.audioDeleted {
                Text("Audio has been deleted — transcript text is still available, but blocks can't be played back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(session.transcriptBlocks.sorted(by: { $0.startSeconds < $1.startSeconds })) { block in
                Button {
                    play(block: block)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Text(formattedOffset(block.startSeconds))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            if let speakerName = session.displayName(forSpeakerID: block.speakerID) {
                                Text(speakerName)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.indigo)
                            }
                            Text(block.text)
                                .foregroundStyle(.primary)
                        }
                        Spacer()
                        if playingBlockID == block.id {
                            Image(systemName: "speaker.wave.2.fill").foregroundStyle(.blue)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(session.audioDeleted)
            }
        }
        .alert("Playback", isPresented: Binding(get: { playbackError != nil }, set: { if !$0 { playbackError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(playbackError ?? "")
        }
        .onDisappear { player?.stop() }
    }

    private func play(block: TranscriptBlock) {
        guard let chunk = session.chunks.first(where: {
            block.startSeconds >= $0.startOffsetSeconds && block.startSeconds < $0.startOffsetSeconds + $0.durationSeconds
        }) else {
            playbackError = "Couldn't find the audio for this moment."
            return
        }
        let url = AudioRecorder.audioDirectory.appendingPathComponent(chunk.fileName)
        do {
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            newPlayer.currentTime = max(0, block.startSeconds - chunk.startOffsetSeconds)
            newPlayer.play()
            player = newPlayer
            playingBlockID = block.id
        } catch {
            playbackError = "Couldn't play this chunk: \(error.localizedDescription)"
        }
    }

    private func formattedOffset(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
