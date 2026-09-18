//
//  SessionListView.swift
//  DeepSink
//

import SwiftUI
import SwiftData

struct SessionListView: View {
    @Query(sort: \Session.startedAt, order: .reverse) private var sessions: [Session]
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        List {
            if sessions.isEmpty {
                ContentUnavailableView(
                    "No sessions yet",
                    systemImage: "waveform",
                    description: Text("Recordings you stop will show up here.")
                )
            }
            ForEach(sessions) { session in
                NavigationLink {
                    SessionDetailView(session: session)
                } label: {
                    row(for: session)
                }
            }
            .onDelete(perform: delete)
        }
        .navigationTitle("Sessions")
    }

    private func row(for session: Session) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.title).font(.headline)
            HStack(spacing: 6) {
                Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                Text("·")
                Text(formattedDuration(session.durationSeconds))
                Text("·")
                Text(session.state.label)
                if session.openActionItemCount > 0 {
                    Text("· \(session.openActionItemCount) open")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let session = sessions[index]
            for chunk in session.chunks {
                try? FileManager.default.removeItem(at: AudioRecorder.audioDirectory.appendingPathComponent(chunk.fileName))
            }
            modelContext.delete(session)
        }
        try? modelContext.save()
    }

    private func formattedDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

#Preview {
    NavigationStack {
        SessionListView()
    }
    .modelContainer(for: [Session.self, ActionItem.self, Marker.self], inMemory: true)
}
