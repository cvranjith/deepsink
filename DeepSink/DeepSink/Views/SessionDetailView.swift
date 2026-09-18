//
//  SessionDetailView.swift
//  DeepSink
//

import SwiftUI
import SwiftData

struct SessionDetailView: View {
    @Bindable var session: Session
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var sessionProcessor: SessionProcessor
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var isEditingTitle = false
    @State private var isSharing = false
    @State private var shareText = ""

    var body: some View {
        List {
            Section {
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
                    }
                }
                HStack {
                    Label(session.state.label, systemImage: stateIcon)
                        .foregroundStyle(stateColor)
                    Spacer()
                    if session.state.stage == .failed {
                        Button("Retry") { retry() }
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
            if !session.actionItems.isEmpty {
                Section("Action items") {
                    ForEach(session.actionItems.sorted { $0.sortOrder < $1.sortOrder }) { item in
                        ActionItemRow(item: item, onToggle: { try? modelContext.save() })
                    }
                }
            }
            if let openQuestions = session.notes?.openQuestions, !openQuestions.isEmpty {
                Section("Open questions") {
                    ForEach(openQuestions, id: \.self) { Text("• \($0)") }
                }
            }
            if !session.markers.isEmpty {
                Section("Markers") {
                    ForEach(session.markers.sorted(by: { $0.offsetSeconds < $1.offsetSeconds })) { marker in
                        Text(formattedOffset(marker.offsetSeconds) + (marker.comment.map { $0.isEmpty ? "" : " — \($0)" } ?? ""))
                    }
                }
            }
            if !session.transcriptBlocks.isEmpty {
                Section {
                    NavigationLink("View full transcript") {
                        TranscriptView(session: session)
                    }
                }
            }
            if session.state.stage == .ready {
                Section {
                    Button("Regenerate notes") { retry(regenerateOnly: true) }
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
            Section {
                Button("Delete Session", role: .destructive) { deleteSession() }
            }
        }
        .navigationTitle("Session")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    shareText = MarkdownExporter.markdown(for: session)
                    isSharing = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(session.state.stage != .ready)
            }
        }
        .sheet(isPresented: $isSharing) {
            ActivityView(items: [shareText])
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
