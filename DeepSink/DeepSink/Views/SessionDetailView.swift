//
//  SessionDetailView.swift
//  DeepSink
//

import SwiftUI

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
// (with markers and speakers folded in, since both are
// transcript-contextual), action items, and the user's own background
// notes each get their own tab. Title, processing state, and
// share/delete stay in the header/toolbar since they apply regardless
// of which tab is showing.
//
// `session` is seeded once from whatever the caller had (list row, home
// card, or a just-finished recording) and then only ever moves forward
// via a full-session response from RouterClient — never a local mutation
// that isn't also sent to the server. There is exactly one writer (the
// server); this view just renders its latest answer and immediately
// forwards every write's response to DeepSinkSessionStore so other
// screens see it too.
struct SessionDetailView: View {
    @State private var session: DeepSinkSession
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var routerClient: RouterClient
    @EnvironmentObject var sessionStore: DeepSinkSessionStore
    @Environment(\.dismiss) private var dismiss

    @State private var isEditingTitle = false
    @State private var isSharing = false
    @State private var shareText = ""
    @State private var isDeleting = false
    @State private var selectedTab: SessionTab = .notes
    @State private var isRegeneratingNotes = false
    @State private var actionErrorMessage: String?
    @State private var diarizationErrorMessage: String?
    @State private var notesSaveTask: Task<Void, Never>?
    @State private var renamingSpeaker: SessionSpeaker?
    @State private var renameText = ""

    init(session: DeepSinkSession) {
        _session = State(initialValue: session)
    }

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
                    .disabled(session.stageValue != .ready)

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
            Text("This also deletes its audio and transcript on the server.")
        }
        .alert("Speaker Detection", isPresented: Binding(
            get: { diarizationErrorMessage != nil },
            set: { if !$0 { diarizationErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(diarizationErrorMessage ?? "")
        }
        .alert("Session", isPresented: Binding(
            get: { actionErrorMessage != nil },
            set: { if !$0 { actionErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionErrorMessage ?? "")
        }
        .alert("Rename Speaker", isPresented: Binding(
            get: { renamingSpeaker != nil },
            set: { if !$0 { renamingSpeaker = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingSpeaker = nil }
            Button("Save") {
                if let speaker = renamingSpeaker { renameSpeaker(speaker) }
                renamingSpeaker = nil
            }
        } message: {
            Text("Also teaches the server to recognize this voice automatically in future sessions.")
        }
        .task {
            // The list/card this view was pushed from may be showing a
            // slightly stale snapshot (e.g. a chunk uploaded a moment
            // after the caller last refreshed) — one fetch on appear
            // catches it up without waiting on a background poll.
            if case .success(let latest) = await routerClient.getSession(id: session.id, settings: settings) {
                session = latest
                sessionStore.apply(latest)
            }
        }
    }

    // MARK: - Header (always visible)

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isEditingTitle {
                TextField("Title", text: $session.title, onCommit: {
                    isEditingTitle = false
                    patchField(["title": session.title])
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
                Label(session.stageLabel, systemImage: session.stageIcon)
                    .font(.footnote)
                    .foregroundStyle(session.stageColor)
                Spacer()
                if session.stageValue == .failed {
                    Button("Retry") { regenerateNotes() }
                        .font(.footnote)
                }
            }
            if session.recordingIncomplete {
                Label("A segment may be missing — recording was interrupted.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if session.audioDeleted {
                Label("Audio has been deleted from the server.", systemImage: "trash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // No stage check here — session.stage just reflects
            // recording/uploading/ready/failed on the SERVER (e.g. a
            // title-only session created ahead of time starts at
            // "recording" with zero chunks), not whether THIS device is
            // actively recording something right now. That guard lives
            // centrally in ContentView.resumeRecording instead, since
            // it's the one place that actually knows AudioRecorder's
            // live state.
            Button {
                sessionStore.resumeRequest = session
                dismiss()
            } label: {
                Label("Resume Recording", systemImage: "record.circle")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .padding(.top, 2)
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
                    Text(session.stageValue == .failed ? "Notes failed to generate — retry from the header above." : "Notes aren't ready yet.")
                        .foregroundStyle(.secondary)
                }
            }
            if session.stageValue == .ready {
                Section {
                    Button {
                        regenerateNotes()
                    } label: {
                        if isRegeneratingNotes { ProgressView() } else { Text("Regenerate notes") }
                    }
                    .disabled(isRegeneratingNotes)
                }
            }
        }
    }

    // MARK: - Transcript tab (also markers + speakers — both are transcript-contextual)

    private var transcriptTab: some View {
        List {
            if session.stageValue == .ready {
                Section {
                    speakerDetectionRow
                } footer: {
                    if session.audioDeleted {
                        Text("Detect Speakers needs the session's audio, which has already been deleted.")
                    }
                }
            }
            if session.isDiarized {
                Section {
                    ForEach(session.speakers) { speaker in
                        Button {
                            renamingSpeaker = speaker
                            renameText = speaker.displayName
                        } label: {
                            HStack {
                                Text(speaker.displayName)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "pencil")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Speakers")
                } footer: {
                    Text("Tap a name to rename it — this also teaches the server to recognize that voice automatically in future sessions.")
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
                detectSpeakers()
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
                        ActionItemRow(item: item) {
                            toggleActionItem(item)
                        }
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
                    // Debounced rather than saved on every keystroke: this
                    // used to be "free" (a local SwiftData write), but now
                    // every save is a network PATCH, so a short pause
                    // after typing stops — not the very next character —
                    // is what triggers the request. Dictation
                    // (DictationButton) writes to this same binding
                    // without the TextEditor ever gaining focus, so a
                    // focus-only save would still miss dictated text; this
                    // still catches it since it fires on any change.
                    .onChange(of: session.backgroundNotes) { _, _ in
                        scheduleBackgroundNotesSave()
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

    private func patchField(_ fields: [String: Any]) {
        Task {
            let result = await routerClient.updateSession(id: session.id, fields: fields, settings: settings)
            switch result {
            case .success(let updated):
                session = updated
                sessionStore.apply(updated)
            case .failure(let error):
                actionErrorMessage = error.message
            }
        }
    }

    private func scheduleBackgroundNotesSave() {
        notesSaveTask?.cancel()
        let text = session.backgroundNotes
        notesSaveTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            let result = await routerClient.updateSession(id: session.id, fields: ["background_notes": text], settings: settings)
            if case .success(let updated) = result {
                session = updated
                sessionStore.apply(updated)
            }
        }
    }

    private func toggleActionItem(_ item: ServerActionItem) {
        guard let index = session.actionItems.firstIndex(where: { $0.id == item.id }) else { return }
        let newValue = !item.isChecked
        session.actionItems[index].isChecked = newValue
        Task {
            let result = await routerClient.toggleActionItem(sessionID: session.id, itemID: item.id, isChecked: newValue, settings: settings)
            switch result {
            case .success(let updated):
                session = updated
                sessionStore.apply(updated)
            case .failure(let error):
                if let index = session.actionItems.firstIndex(where: { $0.id == item.id }) {
                    session.actionItems[index].isChecked = !newValue
                }
                actionErrorMessage = error.message
            }
        }
    }

    private func renameSpeaker(_ speaker: SessionSpeaker) {
        let newName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != speaker.displayName else { return }
        Task {
            let result = await routerClient.renameSpeaker(sessionID: session.id, speakerID: speaker.id, displayName: newName, settings: settings)
            switch result {
            case .success(let updated):
                session = updated
                sessionStore.apply(updated)
            case .failure(let error):
                actionErrorMessage = error.message
            }
        }
    }

    private func detectSpeakers() {
        session.isDiarizing = true
        Task {
            let result = await routerClient.diarizeSession(id: session.id, settings: settings)
            switch result {
            case .success(let updated):
                session = updated
                sessionStore.apply(updated)
            case .failure(let error):
                session.isDiarizing = false
                diarizationErrorMessage = error.message
            }
        }
    }

    // No standalone "retry a failed chunk upload" anymore — the failed
    // chunk (if any) never made it to the server, so there's nothing
    // server-side to resume from this screen. What "Retry" can still
    // reliably do is re-run note generation over whatever transcript did
    // make it through.
    private func regenerateNotes() {
        isRegeneratingNotes = true
        Task {
            let result = await routerClient.regenerateNotes(id: session.id, settings: settings)
            isRegeneratingNotes = false
            switch result {
            case .success(let updated):
                session = updated
                sessionStore.apply(updated)
            case .failure(let error):
                actionErrorMessage = error.message
            }
        }
    }

    private func deleteSession() {
        Task {
            let result = await routerClient.deleteSession(id: session.id, settings: settings)
            if case .failure(let error) = result {
                actionErrorMessage = error.message
                return
            }
            sessionStore.remove(id: session.id)
            dismiss()
        }
    }

    private func formattedOffset(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private struct ActionItemRow: View {
    let item: ServerActionItem
    var onToggle: () -> Void

    var body: some View {
        Button {
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

// The transcript-block list, factored out of the old standalone
// TranscriptView so it can sit inline inside the Transcript tab's List
// rather than behind a NavigationLink push. No tap-to-play anymore: the
// server deletes a chunk's audio once it's been transcribed (see
// DeepSinkSession.audioDeleted), and there's no download endpoint to
// fetch it back — this now shows plain, non-interactive rows.
private struct TranscriptBlocksList: View {
    let session: DeepSinkSession

    var body: some View {
        ForEach(session.transcriptBlocks.sorted(by: { $0.startSeconds < $1.startSeconds })) { block in
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
            }
        }
    }

    private func formattedOffset(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
