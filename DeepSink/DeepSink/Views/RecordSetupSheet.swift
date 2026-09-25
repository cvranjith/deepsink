//
//  RecordSetupSheet.swift
//  DeepSink
//

import SwiftUI

// Shown when tapping Record, before anything actually starts - lets you
// set the handful of things that are awkward or impossible to change once
// a session already exists (the title before it's ever been auto-refined,
// live notes/diarization for the whole recording) in one place, rather
// than hunting through the recording screen's own tabs afterward. Only
// applies to a brand-new recording; Resume Recording continues an
// existing session's own settings unchanged.
struct RecordSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    // Tracks whether `title` has been changed from the auto-generated
    // default it started as - this (not "the field is non-empty," which
    // is true even for the untouched default) is what tells the caller
    // whether to follow up with a manual-title PATCH after creating the
    // session. See title_is_manual's own comment in session_store.py: a
    // title the user never touched should keep refining itself as Codex
    // sees more of the transcript; one they typed here should never be
    // touched again.
    @State private var titleEdited = false
    @State private var category: String
    @State private var liveNotesEnabled: Bool
    @State private var diarizationEnabled: Bool

    let onStart: (
        _ title: String, _ titleIsManual: Bool, _ category: String,
        _ liveNotesEnabled: Bool, _ diarizationEnabled: Bool
    ) -> Void

    init(settings: AppSettings, onStart: @escaping (String, Bool, String, Bool, Bool) -> Void) {
        _title = State(initialValue: DeepSinkSession.defaultTitle(for: Date()))
        _category = State(initialValue: "meeting")
        _liveNotesEnabled = State(initialValue: settings.liveNotesEnabled)
        _diarizationEnabled = State(initialValue: settings.diarizationEnabled)
        self.onStart = onStart
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                        .onChange(of: title) { _, _ in titleEdited = true }
                } footer: {
                    Text("Left as-is, the title keeps refining itself from what's actually said. Edit it now and it's locked in for good.")
                }

                Section {
                    Picker("Category", selection: $category) {
                        Text("Meeting").tag("meeting")
                        Text("To-Do").tag("todo")
                        Text("Voice Note").tag("voice_note")
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(categoryFooter)
                }

                Section {
                    Toggle("Live notes", isOn: $liveNotesEnabled)
                } footer: {
                    Text(liveNotesEnabled
                        ? "Notes regenerate automatically after every chunk."
                        : "Nothing generates until you ask, or you stop recording — you can still flip this once you're recording.")
                }

                Section {
                    Toggle("Detect speakers", isOn: $diarizationEnabled)
                } footer: {
                    Text(diarizationEnabled
                        ? "Audio is kept until the recording finishes, then processed once to label who spoke."
                        : "No speaker detection — each chunk's audio is deleted as soon as it's transcribed, instead of kept around.")
                }
            }
            .navigationTitle("New Recording")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        let finalTitle = trimmed.isEmpty ? DeepSinkSession.defaultTitle(for: Date()) : trimmed
                        onStart(finalTitle, titleEdited && !trimmed.isEmpty, category, liveNotesEnabled, diarizationEnabled)
                        dismiss()
                    }
                }
            }
        }
    }

    private var categoryFooter: String {
        switch category {
        case "todo":
            return "Notes focus on turning what you say into a checklist, not a meeting summary."
        case "voice_note":
            return "A light, free-form summary — not forced into meeting structure."
        default:
            return "Full notes: summary, key points, decisions, and action items."
        }
    }
}

#Preview {
    RecordSetupSheet(settings: AppSettings()) { _, _, _, _, _ in }
}
