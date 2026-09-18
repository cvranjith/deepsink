//
//  DictationButton.swift
//  DeepSink
//

import SwiftUI

// A small, explicit dictation affordance for a text field — attached
// next to background notes and marker comments (see SessionDetailView,
// MarkerDetailSheet). Deliberately a visible button rather than relying
// on the system keyboard's own dictation key: that one works too, but
// it's easy to miss and some people have it turned off system-wide —
// same "make the obvious thing obvious" reasoning as the always-visible
// recording indicator elsewhere in this app.
//
// Owns its own `DictationEngine` instance per button (via `@StateObject`)
// rather than sharing one — each text field's dictation session is
// independent and short-lived, so there's no reason for two fields on
// screen at once to contend over a single engine.
struct DictationButton: View {
    @Binding var text: String
    @StateObject private var engine = DictationEngine()

    var body: some View {
        Button {
            toggle()
        } label: {
            Image(systemName: engine.isListening ? "mic.fill" : "mic")
                .foregroundStyle(engine.isListening ? .red : .secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(engine.isListening ? "Stop dictation" : "Start dictation")
        .alert("Dictation", isPresented: Binding(
            get: { engine.errorMessage != nil },
            set: { if !$0 { engine.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(engine.errorMessage ?? "")
        }
        .onDisappear { engine.stop() }
    }

    private func toggle() {
        if engine.isListening {
            engine.stop()
        } else {
            engine.start(appendingTo: text) { updated in
                text = updated
            }
        }
    }
}
