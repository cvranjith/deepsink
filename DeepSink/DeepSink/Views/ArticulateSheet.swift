//
//  ArticulateSheet.swift
//  DeepSink
//

import SwiftUI

// Tapped either from the attention banner or the standing "Articulate"
// button while recording. Takes whatever LiveAssistEngine has recognized
// in the last `articulateWindowSeconds`, sends just that short excerpt to
// deepsink.articulate, and shows both output modes at once — a
// quick-reference bullet list, and a short spoken-style draft meant to be
// read out loud (not spoken by the phone itself — reading it out loud in
// a live meeting is the point).
struct ArticulateSheet: View {
    // The in-progress session, so its background notes (see
    // SessionDetailView) can go along with the transcript excerpt — nil
    // only in the (currently unreachable in practice) case of no active
    // session, in which case background notes are simply omitted.
    let session: Session?

    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var routerClient: RouterClient
    @EnvironmentObject var liveAssistEngine: LiveAssistEngine
    @Environment(\.dismiss) private var dismiss

    @State private var isLoading = false
    @State private var response: ArticulateResponse?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Thinking…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let response {
                    List {
                        Section("Quick reference") {
                            ForEach(response.bullets, id: \.self) { bullet in
                                Text("• \(bullet)")
                            }
                        }
                        Section("Say it like this") {
                            Text(response.speech)
                                .textSelection(.enabled)
                        }
                    }
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Couldn't get an answer",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                }
            }
            .navigationTitle("Articulate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await generate() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
        }
        .task { await generate() }
    }

    private func generate() async {
        isLoading = true
        errorMessage = nil
        response = nil

        let transcript = liveAssistEngine.recentTranscript(seconds: TimeInterval(settings.articulateWindowSeconds))
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            isLoading = false
            errorMessage = "Nothing recognized in the last few minutes yet — Live Assist needs a moment of speech to work from."
            return
        }

        let result = await routerClient.articulate(recentTranscript: transcript, backgroundNotes: session?.backgroundNotes ?? "", settings: settings)
        isLoading = false
        switch result {
        case .success(let payload):
            response = payload
        case .failure(let error):
            errorMessage = error.message
        }
    }
}
