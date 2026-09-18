//
//  MarkerDetailSheet.swift
//  DeepSink
//

import SwiftUI

// Shown right after "Mark this moment" is tapped. Unlike the old
// SwiftData version, there's no local Marker created up front to attach
// a comment to afterward — the server's marker endpoint creates and
// comments in one call, so nothing is persisted until "Done" here. That
// means dismissing the app before tapping Done loses the marker
// entirely, a real (if narrow) behavior change from "saved the instant
// you tap the bookmark," accepted since there's no separate create-then-
// patch pair to call instead. Photo attachment is dropped too: the
// server has no marker-photo upload endpoint.
struct MarkerDetailSheet: View {
    let sessionID: String
    let offsetSeconds: Double

    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var routerClient: RouterClient
    @EnvironmentObject var sessionStore: DeepSinkSessionStore
    @Environment(\.dismiss) private var dismiss

    @State private var comment: String = ""
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Comment (optional)") {
                    HStack(alignment: .top) {
                        TextField("What's happening right now?", text: $comment, axis: .vertical)
                        DictationButton(text: $comment)
                    }
                }
            }
            .navigationTitle("Moment Marked")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving { ProgressView() } else { Text("Done") }
                    }
                    .disabled(isSaving)
                }
            }
        }
    }

    private func save() async {
        isSaving = true
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = await routerClient.addMarker(
            sessionID: sessionID,
            offsetSeconds: offsetSeconds,
            comment: trimmed.isEmpty ? nil : trimmed,
            settings: settings
        )
        if case .success(let session) = result {
            sessionStore.apply(session)
        }
        isSaving = false
        dismiss()
    }
}
