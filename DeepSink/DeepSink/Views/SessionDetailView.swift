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
    @EnvironmentObject var audioRecorder: AudioRecorder
    @EnvironmentObject var liveAssistEngine: LiveAssistEngine
    @Environment(\.dismiss) private var dismiss

    @State private var isEditingTitle = false
    @State private var isSharing = false
    @State private var shareText = ""
    @State private var isDeleting = false
    @State private var selectedTab: SessionTab
    @State private var isRegeneratingNotes = false
    @State private var actionErrorMessage: String?
    @State private var diarizationErrorMessage: String?
    @State private var notesSaveTask: Task<Void, Never>?
    @State private var renamingSpeaker: SessionSpeaker?
    @State private var renameText = ""
    @State private var editingActionItem: ServerActionItem?
    @State private var editOwnerText = ""
    @State private var editDueText = ""
    @State private var showMarkerSheet = false
    @State private var pendingMarkerOffset: Double?
    @State private var showArticulateSheet = false

    init(session: DeepSinkSession, startOnTranscriptTab: Bool = false) {
        _session = State(initialValue: session)
        _selectedTab = State(initialValue: startOnTranscriptTab ? .transcript : .notes)
    }

    // True only when THIS device is actively recording THIS exact
    // session right now (not just "server thinks it's live," which can
    // also mean "someone recorded it, walked away, and it's stuck" —
    // see the header's own stage label for that case instead). Drives
    // the recording control bar, the reminder/attention banners, and
    // the live-preview trailing line in the Transcript tab.
    private var isActiveRecording: Bool {
        sessionStore.activeRecordingSessionID == session.id && audioRecorder.isRecording
    }

    // Broader than isActiveRecording on purpose: also true right after
    // Stop (finish/diarize still processing server-side, possibly for
    // several seconds or minutes) and for a session someone else/another
    // device is actively feeding. Drives the polling loop below — the
    // point is "does this session still have server-side work that
    // could change what's on screen," not "is this device the one doing
    // it." session.isRecording, not !session.isTerminal (stage-based) —
    // stage alone stopped reliably meaning "still being recorded" once
    // notes started regenerating after every chunk, not just at the
    // end (same bug the web viewer's live-stream hit; see
    // session_store.py's own comment on is_recording).
    private var shouldPollLive: Bool {
        session.isRecording || session.isGeneratingNotes || session.isDiarizing
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
        .overlay(alignment: .top) {
            if isActiveRecording {
                if sessionStore.showReminderBanner {
                    reminderBanner
                } else if let keyword = sessionStore.attentionKeyword {
                    attentionBanner(for: keyword)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isActiveRecording {
                recordingControlBar
            }
        }
        .sheet(isPresented: $isSharing) {
            ActivityView(items: [shareText])
        }
        .sheet(isPresented: $showMarkerSheet) {
            if let pendingMarkerOffset {
                MarkerDetailSheet(sessionID: session.id, offsetSeconds: pendingMarkerOffset)
            }
        }
        .sheet(isPresented: $showArticulateSheet) {
            ArticulateSheet(session: session)
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
        .alert("Edit Action Item", isPresented: Binding(
            get: { editingActionItem != nil },
            set: { if !$0 { editingActionItem = nil } }
        )) {
            TextField("Owner", text: $editOwnerText)
            TextField("Due (e.g. 2026-10-05)", text: $editDueText)
            Button("Cancel", role: .cancel) { editingActionItem = nil }
            Button("Save") {
                if let item = editingActionItem { saveActionItemEdit(item) }
                editingActionItem = nil
            }
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
        // Chunk uploads land through ContentView's own upload loop while
        // THIS device is recording this session, which updates the
        // store directly — this is what surfaces that here immediately,
        // since this view's own `session` is a local copy that write
        // doesn't otherwise touch.
        .onChange(of: sessionStore.sessions) { _, _ in
            if let latest = sessionStore.session(id: session.id) {
                session = latest
            }
        }
        // Catches everything a same-device chunk upload doesn't: a
        // background notes regen or auto-diarize finishing (both run
        // async, after this device's own upload response already came
        // back), or this exact session being fed by another device
        // entirely. Self-stopping — restarts only when shouldPollLive's
        // value actually changes, so it stops on its own once the
        // session actually settles.
        .task(id: shouldPollLive) {
            guard shouldPollLive else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                if case .success(let latest) = await routerClient.getSession(id: session.id, settings: settings) {
                    session = latest
                    sessionStore.apply(latest)
                }
            }
        }
    }

    // MARK: - Recording controls (only while isActiveRecording)

    private var recordingControlBar: some View {
        VStack(spacing: 10) {
            recordingLevelMeter
            HStack(spacing: 12) {
                Text(formattedElapsed(sessionStore.activeRecordingBaseOffsetSeconds + audioRecorder.elapsedSeconds))
                    .font(.headline.monospacedDigit())
                Spacer()
                Button {
                    markMoment()
                } label: {
                    Image(systemName: "bookmark.fill")
                }
                .buttonStyle(.bordered)
                if settings.liveAssistEnabled {
                    Button {
                        showArticulateSheet = true
                    } label: {
                        Image(systemName: "sparkles")
                    }
                    .buttonStyle(.bordered)
                    .tint(.indigo)
                }
                Button {
                    sessionStore.stopRecordingRequest = true
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(.bar)
    }

    private var recordingLevelMeter: some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: 4)
                .fill(.secondary.opacity(0.2))
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.red)
                        .frame(width: proxy.size.width * CGFloat(audioRecorder.currentLevel))
                }
        }
        .frame(height: 8)
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

    // Tapping it goes straight to the Articulate sheet — the point of
    // the alert is "catch up fast," not just "you were notified."
    private func attentionBanner(for keyword: String) -> some View {
        Button {
            sessionStore.attentionKeyword = nil
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

    private func markMoment() {
        pendingMarkerOffset = sessionStore.activeRecordingBaseOffsetSeconds + audioRecorder.elapsedSeconds
        showMarkerSheet = true
    }

    private func formattedElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
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
            // Hidden while this device is already recording this exact
            // session — no stage check beyond that, since session.stage
            // just reflects recording/uploading/ready/failed on the
            // SERVER (e.g. a title-only session created ahead of time
            // starts at "recording" with zero chunks) and says nothing
            // about whether THIS device is the one doing it. The
            // double-recording guard itself lives centrally in
            // ContentView.resumeRecording, since it's the one place that
            // actually knows AudioRecorder's live state.
            if !isActiveRecording {
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
                            HStack(spacing: 4) {
                                Text(tab.rawValue)
                                    .font(.subheadline.weight(selectedTab == tab ? .semibold : .regular))
                                    .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                                // Visible from any tab, not just while
                                // looking at Notes itself - the whole
                                // point of putting it on the tab label.
                                if tab == .notes, session.isGeneratingNotes || isRegeneratingNotes {
                                    ProgressView()
                                        .controlSize(.mini)
                                }
                            }
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
            if isActiveRecording {
                Section {
                    Toggle("Live notes", isOn: Binding(
                        get: { session.liveNotesEnabled },
                        set: { setLiveNotesEnabled($0) }
                    ))
                } footer: {
                    Text(session.liveNotesEnabled
                        ? "Notes regenerate automatically after every chunk."
                        : "Nothing generates until you ask below, or you stop recording.")
                }
            }
            if session.isGeneratingNotes {
                Section {
                    HStack {
                        ProgressView()
                        Text("Generating notes…")
                        Spacer()
                        Button("Cancel", role: .destructive) { cancelNotesGeneration() }
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
            }
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
            if session.stageValue == .ready || isActiveRecording {
                Section {
                    Button {
                        regenerateNotes()
                    } label: {
                        if isRegeneratingNotes {
                            ProgressView()
                        } else {
                            // Same call either way (POST .../notes/regenerate,
                            // "whatever transcript exists right now") - the
                            // label just reflects what it means in context:
                            // a manual flush while nothing's automatic yet,
                            // vs. a plain re-run once recording's done.
                            Text(isActiveRecording ? "Generate Notes Now" : "Regenerate notes")
                        }
                    }
                    .disabled(isRegeneratingNotes || session.isGeneratingNotes)
                }
            }
        }
    }

    // MARK: - Transcript tab (also markers + speakers — both are transcript-contextual)

    private var transcriptTab: some View {
        ScrollViewReader { proxy in
            transcriptList
                .onChange(of: session.transcriptBlocks.count) { _, _ in scrollTranscriptToBottom(proxy) }
                .onChange(of: liveAssistEngine.livePreviewConfirmedText) { _, _ in scrollTranscriptToBottom(proxy) }
                .onChange(of: liveAssistEngine.livePreviewTailText) { _, _ in scrollTranscriptToBottom(proxy) }
                .onAppear { scrollTranscriptToBottom(proxy, animated: false) }
        }
    }

    private func scrollTranscriptToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation { proxy.scrollTo("transcript-bottom", anchor: .bottom) }
        } else {
            proxy.scrollTo("transcript-bottom", anchor: .bottom)
        }
    }

    private var transcriptList: some View {
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
            // The live line only ever shows while this device is the one
            // actively recording this exact session — on-device
            // WhisperKit transcription of whatever's currently being
            // said, not yet transcribed by the server. Disappears the
            // moment the chunk it's part of actually uploads and lands
            // as real transcriptBlocks below it (same relationship the
            // web viewer's live_preview has to its own transcript).
            //
            // Split into confirmed (settled, won't change again — full
            // brightness) and tail (still being revised as more audio
            // arrives — dim/italic), matching LiveAssistEngine's own
            // confirmed/tail split.
            let confirmedLive = isActiveRecording ? liveAssistEngine.livePreviewConfirmedText : ""
            let tailLive = isActiveRecording ? liveAssistEngine.livePreviewTailText : ""
            if session.transcriptBlocks.isEmpty && confirmedLive.isEmpty && tailLive.isEmpty {
                Section {
                    Text(isActiveRecording ? (liveAssistEngine.statusMessage ?? "Listening…") : "No transcript yet.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Transcript") {
                    TranscriptBlocksList(session: session)
                    if !confirmedLive.isEmpty || !tailLive.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            if !confirmedLive.isEmpty {
                                Text(confirmedLive)
                                    .foregroundStyle(.primary)
                            }
                            if !tailLive.isEmpty {
                                Text(tailLive)
                                    .italic()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("transcript-bottom")
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
                        } onEdit: {
                            editingActionItem = item
                            editOwnerText = item.owner ?? ""
                            editDueText = item.due ?? ""
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

    private func saveActionItemEdit(_ item: ServerActionItem) {
        Task {
            let result = await routerClient.updateActionItem(
                sessionID: session.id,
                itemID: item.id,
                owner: editOwnerText.trimmingCharacters(in: .whitespacesAndNewlines),
                due: editDueText.trimmingCharacters(in: .whitespacesAndNewlines),
                settings: settings
            )
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

    // A soft cancel - the Codex call already running server-side for a
    // prior regenerateNotes finishes on its own regardless; this just
    // tells the server not to save whatever it comes back with. The
    // spinner (session.isGeneratingNotes) clears immediately from this
    // call's own response, well before that background work actually
    // finishes - see cancel_notes_generation's own comment server-side.
    private func cancelNotesGeneration() {
        Task {
            let result = await routerClient.cancelNotesGeneration(id: session.id, settings: settings)
            switch result {
            case .success(let updated):
                session = updated
                sessionStore.apply(updated)
            case .failure(let error):
                actionErrorMessage = error.message
            }
        }
    }

    private func setLiveNotesEnabled(_ enabled: Bool) {
        session.liveNotesEnabled = enabled
        Task {
            let result = await routerClient.updateSession(
                id: session.id, fields: ["live_notes_enabled": enabled], settings: settings
            )
            switch result {
            case .success(let updated):
                session = updated
                sessionStore.apply(updated)
            case .failure(let error):
                // Revert the optimistic flip above rather than leaving
                // the toggle showing a state the server never actually
                // accepted.
                session.liveNotesEnabled = !enabled
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
    var onEdit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                onToggle()
            } label: {
                Image(systemName: item.isChecked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(item.isChecked ? .green : .secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.text)
                    .strikethrough(item.isChecked)
                    .foregroundStyle(item.isChecked ? .secondary : .primary)
                // Owner/due are fillable, not just displayed - a
                // missing one still shows a placeholder so there's
                // always something to tap (see onEdit below), rather
                // than the row silently having nowhere to add them.
                HStack(spacing: 6) {
                    Text(item.owner?.isEmpty == false ? item.owner! : "Owner?")
                    Text("·")
                    Text(item.due?.isEmpty == false ? item.due! : "Due?")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                onEdit()
            } label: {
                Image(systemName: "pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .onTapGesture { onEdit() }
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
