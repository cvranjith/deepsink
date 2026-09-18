//
//  MarkerDetailSheet.swift
//  DeepSink
//

import SwiftUI
import PhotosUI
import SwiftData

// The marker itself is already saved the instant "Mark this moment" is
// tapped (see ContentView.markMoment) — this sheet only ever adds an
// optional comment/photo afterward, non-blocking, matching FR-8: "no
// typing" for the capture itself, since the user may be mid-conversation.
struct MarkerDetailSheet: View {
    @Bindable var marker: Marker
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var comment: String = ""
    @State private var photoItem: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            Form {
                Section("Comment (optional)") {
                    TextField("What's happening right now?", text: $comment, axis: .vertical)
                }
                Section("Photo (optional)") {
                    PhotosPicker("Attach a photo", selection: $photoItem, matching: .images)
                    if marker.photoFileName != nil {
                        Label("Photo attached", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Moment Marked")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save() }
                }
            }
            .onAppear { comment = marker.comment ?? "" }
            .onChange(of: photoItem) { _, newItem in
                Task { await attachPhoto(newItem) }
            }
        }
    }

    private func attachPhoto(_ item: PhotosPickerItem?) async {
        guard let item, let data = try? await item.loadTransferable(type: Data.self) else { return }
        let markersDirectory = AudioRecorder.audioDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Markers", isDirectory: true)
        try? FileManager.default.createDirectory(at: markersDirectory, withIntermediateDirectories: true)
        let fileName = "\(marker.id.uuidString).jpg"
        try? data.write(to: markersDirectory.appendingPathComponent(fileName))
        marker.photoFileName = fileName
    }

    private func save() {
        marker.comment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        try? modelContext.save()
        dismiss()
    }
}
